//
//  VTFrameProcessorCoordinator.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import Foundation
@preconcurrency import VideoToolbox
import CoreMedia
@preconcurrency import CoreVideo

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)

/// Ordered pipeline stages for frame processing.
public enum PipelineStage: Int, Comparable, CaseIterable {
    case denoise    // Temporal noise filter (VTTemporalNoiseFilter)
    case spatial    // Super resolution (LL SR or Quality SR)
    case temporal   // Frame interpolation or frame rate conversion
    case motionBlur // Motion blur post-process (VTMotionBlur)

    public static func < (lhs: PipelineStage, rhs: PipelineStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A live processor instance at a specific pipeline stage.
nonisolated struct StageInstance {
    let stage: PipelineStage
    let processor: VTFrameProcessor
    let pixelBufferPool: CVPixelBufferPool?
    let outputWidth: Int
    let outputHeight: Int
}

/// A coordinator actor that manages the VideoToolbox processing pipeline.
public actor VTFrameProcessorCoordinator {

    // MARK: - Static Support Checks

    public static func isSuperResolutionSupported() -> Bool {
        VTLowLatencySuperResolutionScalerConfiguration.isSupported
    }

    public static func supportedSuperResolutionScaleFactors(width: Int, height: Int) -> [Float] {
        VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height)
    }

    public static func isFrameInterpolationSupported(width: Int, height: Int) -> Bool {
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
              VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                numberOfInterpolatedFrames: 1
              ) != nil else {
            return false
        }
        if #available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, *) {
            let maximumDimension = VTLowLatencyFrameInterpolationConfiguration
                .maximumDimension(forSpatialScaleFactor: 1)
            let maximumPixelCount = VTLowLatencyFrameInterpolationConfiguration
                .maximumPixelCount(forSpatialScaleFactor: 1)
            return maximumDimension > 0 && maximumPixelCount > 0 &&
                width <= maximumDimension && height <= maximumDimension &&
                Int64(width) * Int64(height) <= Int64(maximumPixelCount)
        }
        return true
    }

    /// Tests the exact LL SR session used by the pipeline. The advertised
    /// scale-factor list is useful diagnostics, but on some OS/device
    /// combinations it does not agree with whether a concrete processor
    /// session can actually be started for the requested dimensions.
    public static func isLowLatencySuperResolutionSupported(width: Int, height: Int, scale: Float) -> Bool {
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: width,
            frameHeight: height,
            scaleFactor: scale
        )
        guard !configuration.sourcePixelBufferAttributes.isEmpty,
              !configuration.destinationPixelBufferAttributes.isEmpty else {
            return false
        }
        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
            processor.endSession()
            return true
        } catch {
            processor.endSession()
            return false
        }
    }

    /// Validates the complete LL SR pipeline rather than only VideoToolbox's
    /// bare processor session. Capability lists and a successful bare session
    /// can still disagree with the pixel-buffer pools and presentation
    /// conversion required by real playback on macOS.
    public static func canStartLowLatencyPipeline(width: Int, height: Int, scale: Float) async -> Bool {
        let coordinator = VTFrameProcessorCoordinator(superResolutionLevel: scale)
        do {
            try await coordinator.startSession(width: width, height: height)
            await coordinator.endSession()
            return true
        } catch {
            await coordinator.endSession()
            return false
        }
    }

    /// Validates Quality SR at the same boundary that playback uses. The
    /// configuration initializer can succeed even when a processor session
    /// cannot be created for a particular resolution/scale on this machine.
    public static func isQualitySuperResolutionSupported(width: Int, height: Int, scale: Int) -> Bool {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
              VTSuperResolutionScalerConfiguration.isSupported,
              let configuration = VTSuperResolutionScalerConfiguration(
                  frameWidth: width,
                  frameHeight: height,
                  scaleFactor: scale,
                  inputType: .video,
                  usePrecomputedFlow: false,
                  qualityPrioritization: .normal,
                  revision: .revision1
              ) else {
            return false
        }

        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
            processor.endSession()
            return true
        } catch {
            processor.endSession()
            return false
        }
    }

    // MARK: - Configuration

    // Existing
    public let superResolutionLevel: Float     // 0, 1.5, 2, 4 (LL SR)
    public let frameInterpolationLevel: Int    // 0, 2, 4 (LL FI)
    public let useHighQualityDownsampling: Bool
    public let useRealTimePriority: Bool
    /// Uses the separate temporal-then-spatial implementation only after the
    /// combined LL2 SR/FI processor rejects this device or resolution.
    public let preferSequentialSRFI: Bool

    // New: Quality SR (alternative to LL SR)
    public let qualitySuperResolutionScaleFactor: Int  // 0=off, 2, 4

    // New: Motion blur
    public let motionBlurStrength: Int         // 0=off, 1-100

    // New: Temporal denoise
    public let denoiseStrength: Double         // 0.0=off, 0.0-1.0

    // New: Quality prioritization
    public let qualityPrioritization: Int      // 0=normal, 1=quality

    // MARK: - Pipeline State

    var stages: [PipelineStage: StageInstance] = [:]
    var isSessionActive = false
    var activeProcessCount = 0
    var endRequested = false
    var endWaiters: [CheckedContinuation<Void, Never>] = []

    // Source dimensions for the pipeline
    var sourceWidth = 0
    var sourceHeight = 0
    var targetWidth = 0
    var targetHeight = 0
    var sourceExtendedPixelsRight = 0
    var sourceExtendedPixelsBottom = 0

    // Reference frame ring buffer (newest first)
    var frameHistory: [VTFrameProcessorFrame] = []
    var outputHistory: [VTFrameProcessorFrame] = []
    var upscaledFrameHistory: [VTFrameProcessorFrame] = []
    let maxHistoryLength = 8

    // Fallback transfer session (for unsupported 2nd stage SR scaler)
    var fallbackTransferSession: VTPixelTransferSession?

    #if os(macOS)
    // Convert processed Y'CbCr output before handing it to Core Image/Metal.
    var rendererTransferSession: VTPixelTransferSession?
    var rendererPixelBufferPool: CVPixelBufferPool?
    #endif

    // FI must run at source resolution when it is paired with LL SR. Running
    // the temporal processor after 4x SR makes it operate on sixteen times
    // as many pixels and cannot sustain the generated-frame cadence.
    var temporalFirstForSRInterpolation = false

    // Bicubic upscale for interpolated frames in temporal-first mode.
    // LL SR is trained on real video and produces softer output on
    // synthetically interpolated frames.
    var interpolatedTransferSession: VTPixelTransferSession?
    var interpolatedTransferPool: CVPixelBufferPool?

    // Second spatial stage for 4x LL SR cascading (2x → 2x)
    var secondSpatialProcessor: VTFrameProcessor?
    var secondSpatialPool: CVPixelBufferPool?

    // MARK: - Init

    public init(
        superResolutionLevel: Float = 0,
        frameInterpolationLevel: Int = 0,
        useHighQualityDownsampling: Bool = true,
        useRealTimePriority: Bool = true,
        preferSequentialSRFI: Bool = false,
        qualitySuperResolutionScaleFactor: Int = 0,
        motionBlurStrength: Int = 0,
        denoiseStrength: Double = 0.0,
        qualityPrioritization: Int = 1
    ) {
        self.superResolutionLevel = superResolutionLevel
        self.frameInterpolationLevel = frameInterpolationLevel
        self.useHighQualityDownsampling = useHighQualityDownsampling
        self.useRealTimePriority = useRealTimePriority
        self.preferSequentialSRFI = preferSequentialSRFI
        self.qualitySuperResolutionScaleFactor = qualitySuperResolutionScaleFactor
        self.motionBlurStrength = motionBlurStrength
        self.denoiseStrength = denoiseStrength
        self.qualityPrioritization = qualityPrioritization
    }

    // MARK: - Pool Helper

    func makePool(width: Int, height: Int, from attributes: [AnyHashable: Any]?) -> CVPixelBufferPool? {
        var dict: [AnyHashable: Any] = attributes ?? [:]
        dict[kCVPixelBufferWidthKey] = width
        dict[kCVPixelBufferHeightKey] = height
        if dict[kCVPixelBufferPixelFormatTypeKey] == nil {
            dict[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        if dict[kCVPixelBufferIOSurfacePropertiesKey] == nil {
            dict[kCVPixelBufferIOSurfacePropertiesKey] = [:] as [String: Any]
        }
        var pool: CVPixelBufferPool?
        // Processing is sequential. Six buffers cover 4x FI's four output
        // destinations plus in-flight renderer/processor ownership without
        // retaining fifteen large surfaces per pipeline stage.
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, dict as CFDictionary, &pool)
        return status == kCVReturnSuccess ? pool : nil
    }

    func propagateColorAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        if !CFEqual(source, destination) {
            CVBufferPropagateAttachments(source, destination)
        }

        let colorKeys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferGammaLevelKey
        ]
        for key in colorKeys {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(destination, key, value, .shouldPropagate)
            } else {
                // VideoToolbox may attach its own transfer function or matrix
                // to FI destinations. Do not let that metadata survive when
                // the source has no corresponding attachment.
                CVBufferRemoveAttachment(destination, key)
            }
        }

        let defaults: [(CFString, CFTypeRef)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        ]
        for (key, value) in defaults where CVBufferCopyAttachment(destination, key, nil) == nil {
            CVBufferSetAttachment(destination, key, value, .shouldPropagate)
        }
    }

    #if os(macOS)
    func isNativeHDR(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let transferFunction = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            nil
        ) else {
            return false
        }
        return CFEqual(transferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
            CFEqual(transferFunction, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
    }

    func configureRendererTransferSession(_ session: VTPixelTransferSession) {
        configureTransferSession(session)
        // Do not force BT.709 here. The source track's primaries and transfer
        // function are propagated onto each decoded frame, and VideoToolbox
        // must use those values when converting processed output. A global
        // BT.709 destination changes chroma for non-709 SDR and HDR sources.
    }
    #endif

    // MARK: - Start Session

    public func startSession(width: Int, height: Int) throws {
        guard !isSessionActive else { return }

        self.sourceWidth = width
        self.sourceHeight = height
        self.endRequested = false
        self.activeProcessCount = 0
        self.endWaiters.removeAll()
        self.frameHistory.removeAll()
        self.outputHistory.removeAll()
        self.upscaledFrameHistory.removeAll()
        self.stages.removeAll()
        self.temporalFirstForSRInterpolation = false
        self.sourceExtendedPixelsRight = 0
        self.sourceExtendedPixelsBottom = 0

        var currentWidth = width
        var currentHeight = height
        // A configuration can be accepted by VideoToolbox and still fail
        // when a later stage session is started. Keep partial resources
        // reclaimable so a failed restart cannot poison the next pipeline.
        defer {
            if !isSessionActive {
                completeEndSession()
            }
        }

        // Helper to build a stage
        func addStage(_ stage: PipelineStage, processor: VTFrameProcessor, pool: CVPixelBufferPool?, outW: Int, outH: Int) {
            stages[stage] = StageInstance(
                stage: stage,
                processor: processor,
                pixelBufferPool: pool,
                outputWidth: outW,
                outputHeight: outH
            )
        }

        // ── 1. Denoise Stage ──────────────────────────────────────────
        if denoiseStrength > 0 {
            if #available(macOS 26.0, iOS 26.0, *),
               VTTemporalNoiseFilterConfiguration.isSupported,
               let config = VTTemporalNoiseFilterConfiguration(
                   frameWidth: currentWidth,
                   frameHeight: currentHeight,
                   sourcePixelFormat: OSType(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
               ) {
                let proc = VTFrameProcessor()
                try proc.startSession(configuration: config)
                let pool = makePool(width: currentWidth, height: currentHeight, from: config.destinationPixelBufferAttributes)
                addStage(.denoise, processor: proc, pool: pool, outW: currentWidth, outH: currentHeight)
            }
        }

        // ── 2. Spatial Stage ──────────────────────────────────────────
        let hasQualitySR = qualitySuperResolutionScaleFactor > 0
        let hasLLSR = superResolutionLevel > 0
        #if os(macOS)
        let inCombinedMode = superResolutionLevel == 2 && frameInterpolationLevel == 2 && !preferSequentialSRFI
        #else
        // iOS uses the stable sequential spatial-then-temporal path. The
        // combined spatial FI processor is the branch that rejects SR2+FI2
        // while the equivalent SR4+FI2 path remains operational.
        let inCombinedMode = false
        #endif
        // The combined SR2 + FI2 processor handles its own spatial stage.
        // Every other LL SR + FI mode runs temporal processing at source
        // resolution and applies LL SR to each output frame. In particular,
        // FI4 must not interpolate already-upscaled 2x surfaces.
        #if os(macOS)
        let useTemporalFirstForSRInterpolation = superResolutionLevel > 0 &&
            frameInterpolationLevel > 0 && !inCombinedMode
        #else
        let useTemporalFirstForSRInterpolation = false
        #endif
        self.temporalFirstForSRInterpolation = useTemporalFirstForSRInterpolation

        let needsSpatial = hasQualitySR || (hasLLSR && (!inCombinedMode || useTemporalFirstForSRInterpolation))

        func configureSpatialStages() throws {
            guard needsSpatial else { return }

            if hasQualitySR {
                // Quality SR — single stage at requested scale
                let scale = qualitySuperResolutionScaleFactor
                guard #available(macOS 26.0, iOS 26.0, *),
                      let config = VTSuperResolutionScalerConfiguration(
                    frameWidth: currentWidth,
                    frameHeight: currentHeight,
                    scaleFactor: scale,
                    inputType: .video,
                    usePrecomputedFlow: false,
                    qualityPrioritization: .normal,
                    revision: .revision1
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create Quality SR config"])
                }
                let proc = VTFrameProcessor()
                try proc.startSession(configuration: config)
                sourceExtendedPixelsRight = (config.sourcePixelBufferAttributes[
                    kCVPixelBufferExtendedPixelsRightKey as String
                ] as? NSNumber)?.intValue ?? 0
                sourceExtendedPixelsBottom = (config.sourcePixelBufferAttributes[
                    kCVPixelBufferExtendedPixelsBottomKey as String
                ] as? NSNumber)?.intValue ?? 0
                let pool = makePool(width: currentWidth * scale, height: currentHeight * scale, from: config.destinationPixelBufferAttributes)
                guard pool != nil else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create Quality SR pool"])
                }
                addStage(.spatial, processor: proc, pool: pool, outW: currentWidth * scale, outH: currentHeight * scale)
                currentWidth *= scale
                currentHeight *= scale
            } else {
                // LL SR — 4x cascades two 2x stages; other supported scales
                // use their native VideoToolbox factor directly.
                let firstStageScale: Float = superResolutionLevel == 4 ? 2 : superResolutionLevel
                guard Self.isLowLatencySuperResolutionSupported(
                    width: currentWidth, height: currentHeight, scale: firstStageScale
                ) else {
                    throw NSError(
                        domain: "VTFrameProcessorCoordinator",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Low Latency SR does not support \(currentWidth)x\(currentHeight) at \(firstStageScale)x on this device"]
                    )
                }
                let config1 = VTLowLatencySuperResolutionScalerConfiguration(
                    frameWidth: currentWidth,
                    frameHeight: currentHeight,
                    scaleFactor: firstStageScale
                )
                guard !config1.sourcePixelBufferAttributes.isEmpty,
                      !config1.destinationPixelBufferAttributes.isEmpty else {
                    throw NSError(
                        domain: "VTFrameProcessorCoordinator",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Low Latency SR returned no pixel buffer requirements"]
                    )
                }
                let proc1 = VTFrameProcessor()
                try proc1.startSession(configuration: config1)
                let firstOutputWidth = Int((Float(currentWidth) * firstStageScale).rounded())
                let firstOutputHeight = Int((Float(currentHeight) * firstStageScale).rounded())
                let pool1 = makePool(width: firstOutputWidth, height: firstOutputHeight, from: config1.destinationPixelBufferAttributes)
                guard pool1 != nil else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create SR pool 1"])
                }
                addStage(.spatial, processor: proc1, pool: pool1, outW: firstOutputWidth, outH: firstOutputHeight)
                currentWidth = firstOutputWidth
                currentHeight = firstOutputHeight

                // Second stage for 4x LL SR
                if superResolutionLevel == 4 {
                    let secondStageSupported = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: currentWidth, frameHeight: currentHeight).contains(2.0)
                    if secondStageSupported {
                        let config2 = VTLowLatencySuperResolutionScalerConfiguration(
                            frameWidth: currentWidth,
                            frameHeight: currentHeight,
                            scaleFactor: 2.0
                        )
                        let proc2 = VTFrameProcessor()
                        try proc2.startSession(configuration: config2)
                        let pool2 = makePool(width: currentWidth * 2, height: currentHeight * 2, from: config2.destinationPixelBufferAttributes)
                        guard pool2 != nil else {
                            throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to create SR pool 2"])
                        }
                        self.secondSpatialProcessor = proc2
                        self.secondSpatialPool = pool2
                    } else {
                        // Fallback: VTPixelTransferSession
                        var fallbackSession: VTPixelTransferSession?
                        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &fallbackSession)
                        if status == kCVReturnSuccess, let session = fallbackSession {
                            configureTransferSession(session)
                            // Keep this allocation in the same pool discipline as
                            // the processor-backed second stage. Allocating a new
                            // 4x surface for every frame is especially costly on
                            // macOS when the scaler's second session is unsupported.
                            guard let pool = makePool(
                                width: currentWidth * 2,
                                height: currentHeight * 2,
                                from: [
                                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
                                ]
                            ) else {
                                VTPixelTransferSessionInvalidate(session)
                                throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Failed to create fallback SR pool"])
                            }
                            self.fallbackTransferSession = session
                            self.secondSpatialPool = pool
                        } else {
                            throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to create fallback session"])
                        }
                    }
                    currentWidth *= 2
                    currentHeight *= 2
                }
            }
        }

        if !useTemporalFirstForSRInterpolation {
            try configureSpatialStages()
        }

        // ── 3. Temporal Stage ─────────────────────────────────────────
        if frameInterpolationLevel > 0 {
            if inCombinedMode && !useTemporalFirstForSRInterpolation {
                // Combined 2x spatial + 2x temporal
                let scale: Int = 2
                guard let config = VTLowLatencyFrameInterpolationConfiguration(
                    frameWidth: currentWidth,
                    frameHeight: currentHeight,
                    spatialScaleFactor: scale
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create combined FI config"])
                }
                let proc = VTFrameProcessor()
                try proc.startSession(configuration: config)
                let pool = makePool(width: currentWidth * scale, height: currentHeight * scale, from: config.destinationPixelBufferAttributes)
                guard pool != nil else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create combined pool"])
                }
                addStage(.temporal, processor: proc, pool: pool, outW: currentWidth * scale, outH: currentHeight * scale)
                currentWidth *= scale
                currentHeight *= scale
            } else {
                // Pure temporal interpolation (LL FI)
                // VideoToolbox expresses this as an interpolation exponent:
                // 1 produces the midpoint for 2x, while 2 produces the
                // quarter, midpoint, and three-quarter frames for 4x.
                let interpolationExponent = frameInterpolationLevel == 4 ? 2 : 1
                guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
                    frameWidth: currentWidth,
                    frameHeight: currentHeight,
                    numberOfInterpolatedFrames: interpolationExponent
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create FI config"])
                }
                let proc = VTFrameProcessor()
                try proc.startSession(configuration: configuration)
                sourceExtendedPixelsRight = (configuration.sourcePixelBufferAttributes[
                    kCVPixelBufferExtendedPixelsRightKey as String
                ] as? NSNumber)?.intValue ?? 0
                sourceExtendedPixelsBottom = (configuration.sourcePixelBufferAttributes[
                    kCVPixelBufferExtendedPixelsBottomKey as String
                ] as? NSNumber)?.intValue ?? 0
                let pool = makePool(width: currentWidth, height: currentHeight, from: configuration.destinationPixelBufferAttributes)
                guard pool != nil else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create FI pool"])
                }
                addStage(.temporal, processor: proc, pool: pool, outW: currentWidth, outH: currentHeight)
            }
        }

        if useTemporalFirstForSRInterpolation {
            try configureSpatialStages()

            // ── Interpolated Frame Transfer (temporal-first only) ──────
            // LL SR produces softer results on synthetically interpolated
            // frames. Use pixel transfer for interpolated frames instead.
            if needsSpatial && !hasQualitySR,
               let spatialInstance = stages[.spatial] {
                var session: VTPixelTransferSession?
                if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == kCVReturnSuccess,
                   let session {
                    configureTransferSession(session)
                    interpolatedTransferSession = session
                    interpolatedTransferPool = makePool(
                        width: spatialInstance.outputWidth,
                        height: spatialInstance.outputHeight,
                        from: [
                            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
                        ]
                    )
                }
            }
        }

        // ── 4. Motion Blur Stage ──────────────────────────────────────
        if motionBlurStrength > 0 {
            guard #available(macOS 26.0, iOS 26.0, *),
                  let config = VTMotionBlurConfiguration(
                frameWidth: currentWidth,
                frameHeight: currentHeight,
                usePrecomputedFlow: false,
                qualityPrioritization: qualityPrioritization >= 2 ? .quality : .normal,
                revision: .revision1
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create Motion Blur config"])
            }
            let proc = VTFrameProcessor()
            try proc.startSession(configuration: config)
            let pool = makePool(width: currentWidth, height: currentHeight, from: config.destinationPixelBufferAttributes)
            guard pool != nil else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create Motion Blur pool"])
            }
            addStage(.motionBlur, processor: proc, pool: pool, outW: currentWidth, outH: currentHeight)
        }

        self.targetWidth = currentWidth
        self.targetHeight = currentHeight

        #if os(macOS)
        if hasQualitySR || hasLLSR || frameInterpolationLevel > 0 {
            var transferSession: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession) == kCVReturnSuccess,
                  let transferSession else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create presentation transfer session"])
            }
            configureRendererTransferSession(transferSession)
            guard let rendererPool = makePool(width: currentWidth, height: currentHeight, from: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
            ]) else {
                VTPixelTransferSessionInvalidate(transferSession)
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create presentation pool"])
            }
            rendererTransferSession = transferSession
            rendererPixelBufferPool = rendererPool
        }
        #endif

        self.isSessionActive = true
    }

    // MARK: - End Session

    public func endSession() async {
        guard isSessionActive else { return }
        if endRequested {
            if activeProcessCount > 0 {
                await withCheckedContinuation { continuation in
                    endWaiters.append(continuation)
                }
            }
            return
        }

        endRequested = true
        if activeProcessCount > 0 {
            await withCheckedContinuation { continuation in
                endWaiters.append(continuation)
            }
        } else {
            completeEndSession()
        }
    }

    func completeEndSession() {
           var hasResources = isSessionActive || !stages.isEmpty || secondSpatialProcessor != nil ||
            fallbackTransferSession != nil || interpolatedTransferSession != nil
        #if os(macOS)
        hasResources = hasResources || rendererTransferSession != nil || rendererPixelBufferPool != nil
        #endif
        guard hasResources else { return }

        for (_, instance) in stages {
            instance.processor.endSession()
        }
        stages.removeAll()

        if let proc2 = secondSpatialProcessor {
            proc2.endSession()
        }
        secondSpatialProcessor = nil
        secondSpatialPool = nil

        if let session = fallbackTransferSession {
            VTPixelTransferSessionInvalidate(session)
        }
        fallbackTransferSession = nil

        if let session = interpolatedTransferSession {
            VTPixelTransferSessionInvalidate(session)
        }
        interpolatedTransferSession = nil
        interpolatedTransferPool = nil

        #if os(macOS)
        if let session = rendererTransferSession {
            VTPixelTransferSessionInvalidate(session)
        }
        rendererTransferSession = nil
        rendererPixelBufferPool = nil
        #endif

        temporalFirstForSRInterpolation = false

        frameHistory.removeAll()
        outputHistory.removeAll()
        upscaledFrameHistory.removeAll()
        sourceExtendedPixelsRight = 0
        sourceExtendedPixelsBottom = 0
        isSessionActive = false
        endRequested = false

        let waiters = endWaiters
        endWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func clearHistory() {
        frameHistory.removeAll()
        outputHistory.removeAll()
        upscaledFrameHistory.removeAll()
    }

    public func sourceFramePadding() -> (right: Int, bottom: Int) {
        (sourceExtendedPixelsRight, sourceExtendedPixelsBottom)
    }

    // MARK: - Helpers

    func configureTransferSession(_ session: VTPixelTransferSession) {
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        let downsamplingMode = useHighQualityDownsampling ? kVTDownsamplingMode_Average : kVTDownsamplingMode_Decimate
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DownsamplingMode, value: downsamplingMode)
        let realTimeValue = useRealTimePriority ? kCFBooleanTrue : kCFBooleanFalse
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_RealTime, value: realTimeValue)
    }

}
#else
public enum PipelineStage: Int, Comparable, CaseIterable {
    case denoise
    case spatial
    case temporal
    case motionBlur
    
    public static func < (lhs: PipelineStage, rhs: PipelineStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public actor VTFrameProcessorCoordinator {
    public static func isSuperResolutionSupported() -> Bool {
        return false
    }

    public static func supportedSuperResolutionScaleFactors(width: Int, height: Int) -> [Float] {
        return []
    }

    public static func isFrameInterpolationSupported(width: Int, height: Int) -> Bool {
        false
    }

    public static func canStartLowLatencyPipeline(width: Int, height: Int, scale: Float) async -> Bool {
        return false
    }

    public let superResolutionLevel: Float
    public let frameInterpolationLevel: Int
    public let useHighQualityDownsampling: Bool
    public let useRealTimePriority: Bool
    public let qualitySuperResolutionScaleFactor: Int
    public let motionBlurStrength: Int
    public let denoiseStrength: Double
    public let qualityPrioritization: Int

    public init(
        superResolutionLevel: Float,
        frameInterpolationLevel: Int,
        useHighQualityDownsampling: Bool = true,
        useRealTimePriority: Bool = true,
        preferSequentialSRFI: Bool = false,
        qualitySuperResolutionScaleFactor: Int = 0,
        motionBlurStrength: Int = 0,
        denoiseStrength: Double = 0.0,
        qualityPrioritization: Int = 1
    ) {
        self.superResolutionLevel = superResolutionLevel
        self.frameInterpolationLevel = frameInterpolationLevel
        self.useHighQualityDownsampling = useHighQualityDownsampling
        self.useRealTimePriority = useRealTimePriority
        self.preferSequentialSRFI = preferSequentialSRFI
        self.qualitySuperResolutionScaleFactor = qualitySuperResolutionScaleFactor
        self.motionBlurStrength = motionBlurStrength
        self.denoiseStrength = denoiseStrength
        self.qualityPrioritization = qualityPrioritization
    }

    public func startSession(width: Int, height: Int) async throws {}
    
    public func processFrame(_ frame: VTFrame) async throws -> [VTFrame] {
        return [frame]
    }
    
    public func endSession() async {}

    public func sourceFramePadding() -> (right: Int, bottom: Int) { (0, 0) }
    
    public func clearHistory() {}
}
#endif
