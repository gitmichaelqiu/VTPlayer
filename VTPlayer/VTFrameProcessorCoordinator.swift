//
//  VTFrameProcessorCoordinator.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

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
struct StageInstance {
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

    // MARK: - Configuration

    // Existing
    public let superResolutionLevel: Int       // 0, 2, 4 (LL SR)
    public let frameInterpolationLevel: Int    // 0, 2, 4 (LL FI)
    public let useHighQualityDownsampling: Bool
    public let useRealTimePriority: Bool

    // New: Quality SR (alternative to LL SR)
    public let qualitySuperResolutionScaleFactor: Int  // 0=off, 2, 4

    // New: Motion blur
    public let motionBlurStrength: Int         // 0=off, 1-100

    // New: Temporal denoise
    public let denoiseStrength: Double         // 0.0=off, 0.0-1.0

    // New: Quality prioritization
    public let qualityPrioritization: Int      // 0=normal, 1=quality

    // MARK: - Pipeline State

    private var stages: [PipelineStage: StageInstance] = [:]
    private var isSessionActive = false
    private var activeProcessCount = 0
    private var endRequested = false
    private var endWaiters: [CheckedContinuation<Void, Never>] = []

    // Source dimensions for the pipeline
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var targetWidth = 0
    private var targetHeight = 0

    // Reference frame ring buffer (newest first)
    private var frameHistory: [VTFrameProcessorFrame] = []
    private var outputHistory: [VTFrameProcessorFrame] = []
    private var upscaledFrameHistory: [VTFrameProcessorFrame] = []
    private let maxHistoryLength = 8

    // Fallback transfer session (for unsupported 2nd stage SR scaler)
    private var fallbackTransferSession: VTPixelTransferSession?

    #if os(macOS)
    // Convert enhanced Y'CbCr output before handing it to Core Image/Metal.
    private var rendererTransferSession: VTPixelTransferSession?
    private var rendererPixelBufferPool: CVPixelBufferPool?
    #endif

    // Fast scaling path for interpolated frames when temporal processing runs
    // before the heavy SR stage.
    private var interpolationTransferSession: VTPixelTransferSession?

    // 4x FI is substantially cheaper at source resolution. Keep the
    // existing combined 2x SR + 2x FI mode unchanged.
    private var temporalFirstForSRInterpolation = false

    // Second spatial stage for 4x LL SR cascading (2x → 2x)
    private var secondSpatialProcessor: VTFrameProcessor?
    private var secondSpatialPool: CVPixelBufferPool?

    // MARK: - Init

    public init(
        superResolutionLevel: Int = 0,
        frameInterpolationLevel: Int = 0,
        useHighQualityDownsampling: Bool = true,
        useRealTimePriority: Bool = true,
        qualitySuperResolutionScaleFactor: Int = 0,
        motionBlurStrength: Int = 0,
        denoiseStrength: Double = 0.0,
        qualityPrioritization: Int = 1
    ) {
        self.superResolutionLevel = superResolutionLevel
        self.frameInterpolationLevel = frameInterpolationLevel
        self.useHighQualityDownsampling = useHighQualityDownsampling
        self.useRealTimePriority = useRealTimePriority
        self.qualitySuperResolutionScaleFactor = qualitySuperResolutionScaleFactor
        self.motionBlurStrength = motionBlurStrength
        self.denoiseStrength = denoiseStrength
        self.qualityPrioritization = qualityPrioritization
    }

    // MARK: - Pool Helper

    private func makePool(width: Int, height: Int, from attributes: [AnyHashable: Any]?) -> CVPixelBufferPool? {
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

    private func propagateColorAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
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
    private func configureRendererTransferSession(_ session: VTPixelTransferSession) {
        configureTransferSession(session)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
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
        self.interpolationTransferSession = nil
        self.temporalFirstForSRInterpolation = false

        var currentWidth = width
        var currentHeight = height
        var buildError: Error?

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
        let hasLLSR = superResolutionLevel >= 2
        let inCombinedMode = superResolutionLevel == 2 && frameInterpolationLevel == 2
        // SR2 + FI2 uses temporal-first processing at the adaptive input size,
        // then applies LL SR to every generated frame. This keeps the output
        // cadence stable without mixing upscaled and non-upscaled frames.
        // Combined SR2 + FI2 is unreliable across VideoToolbox revisions:
        // the documented extra scaled-source destination conflicts with the
        // initializer's equal phase/destination validation. Use a supported
        // temporal-first pipeline and apply LL SR to every generated frame.
        let useTemporalFirstForSRInterpolation = superResolutionLevel == 2 && frameInterpolationLevel == 2
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
                let pool = makePool(width: currentWidth * scale, height: currentHeight * scale, from: config.destinationPixelBufferAttributes)
                guard pool != nil else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create Quality SR pool"])
                }
                addStage(.spatial, processor: proc, pool: pool, outW: currentWidth * scale, outH: currentHeight * scale)
                currentWidth *= scale
                currentHeight *= scale
            } else {
                // LL SR — first stage 2x
                guard VTLowLatencySuperResolutionScalerConfiguration
                    .supportedScaleFactors(frameWidth: currentWidth, frameHeight: currentHeight)
                    .contains(2.0) else {
                    throw NSError(
                        domain: "VTFrameProcessorCoordinator",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Low Latency SR does not support \(currentWidth)x\(currentHeight) at 2x on this device"]
                    )
                }
                let config1 = VTLowLatencySuperResolutionScalerConfiguration(
                    frameWidth: currentWidth,
                    frameHeight: currentHeight,
                    scaleFactor: 2.0
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
                let pool1 = makePool(width: currentWidth * 2, height: currentHeight * 2, from: config1.destinationPixelBufferAttributes)
                guard pool1 != nil else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create SR pool 1"])
                }
                addStage(.spatial, processor: proc1, pool: pool1, outW: currentWidth * 2, outH: currentHeight * 2)
                currentWidth *= 2
                currentHeight *= 2

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
                            self.fallbackTransferSession = session
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
        if hasQualitySR || hasLLSR {
            var transferSession: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession) == kCVReturnSuccess,
                  let transferSession else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create SR presentation transfer session"])
            }
            configureRendererTransferSession(transferSession)
            guard let rendererPool = makePool(width: currentWidth, height: currentHeight, from: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
            ]) else {
                VTPixelTransferSessionInvalidate(transferSession)
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create SR presentation pool"])
            }
            rendererTransferSession = transferSession
            rendererPixelBufferPool = rendererPool
        }
        #endif

        self.isSessionActive = true
    }

    // MARK: - Process Frame

    private func beginProcessing() -> Bool {
        guard isSessionActive, !endRequested else { return false }
        activeProcessCount += 1
        return true
    }

    private func finishProcessing() {
        activeProcessCount = max(0, activeProcessCount - 1)
        if endRequested && activeProcessCount == 0 {
            completeEndSession()
        }
    }

    public func processFrame(_ frame: VTFrame) async throws -> [VTFrame] {
        guard beginProcessing() else { return [frame] }
        defer { finishProcessing() }

        // AVAssetReader does not always carry color attachments on macOS.
        // VideoToolbox and Core Image need an explicit Y'CbCr matrix to avoid
        // interpreting enhanced chroma as a green image.
        propagateColorAttachments(from: frame.buffer, to: frame.buffer)

        // Track this frame in history
        if let fpFrame = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: frame.presentationTimeStamp) {
            frameHistory.insert(fpFrame, at: 0)
            if frameHistory.count > maxHistoryLength {
                frameHistory.removeLast()
            }
        }

        var currentFrames: [VTFrame] = [frame]

        // Process stages in order
        let orderedStages: [PipelineStage]
        if temporalFirstForSRInterpolation {
            orderedStages = [.denoise, .temporal, .spatial, .motionBlur]
                .filter { stages.keys.contains($0) }
        } else {
            orderedStages = PipelineStage.allCases
                .filter { stages.keys.contains($0) }
                .sorted()
        }

        for stage in orderedStages {
            guard let instance = stages[stage] else { continue }
            currentFrames = try await processStage(stage, instance: instance, inputFrames: currentFrames)
            for outputFrame in currentFrames {
                propagateColorAttachments(from: frame.buffer, to: outputFrame.buffer)
            }
        }

        #if os(macOS)
        if let session = rendererTransferSession, let pool = rendererPixelBufferPool {
            currentFrames = try currentFrames.map { try convertForRenderer($0, session: session, pool: pool) }
        }
        #endif

        return currentFrames
    }

    #if os(macOS)
    private func convertForRenderer(_ frame: VTFrame, session: VTPixelTransferSession, pool: CVPixelBufferPool) throws -> VTFrame {
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output else {
            throw NSError(domain: "VTFrameProcessorCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "SR presentation pool allocation failed"])
        }
        guard VTPixelTransferSessionTransferImage(session, from: frame.buffer, to: output) == kCVReturnSuccess else {
            throw NSError(domain: "VTFrameProcessorCoordinator", code: -4, userInfo: [NSLocalizedDescriptionKey: "SR presentation color conversion failed"])
        }
        return VTFrame(buffer: output, presentationTimeStamp: frame.presentationTimeStamp, isInterpolated: frame.isInterpolated)
    }
    #endif

    private func processStage(_ stage: PipelineStage, instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
        switch stage {
        case .denoise:
            return try await processDenoise(instance: instance, inputFrames: inputFrames)
        case .temporal:
            return try await processTemporal(instance: instance, inputFrames: inputFrames)
        case .spatial:
            return try await processSpatial(instance: instance, inputFrames: inputFrames)
        case .motionBlur:
            return try await processMotionBlur(instance: instance, inputFrames: inputFrames)
        }
    }

    // MARK: - Individual Stage Processors

    private func processDenoise(instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
        guard denoiseStrength > 0,
              let pool = instance.pixelBufferPool,
              let frame = inputFrames.first else { return inputFrames }

        var outBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuf) == kCVReturnSuccess,
              let destBuf = outBuf else {
            throw NSError(domain: "VTFrameProcessorCoordinator", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Denoise pool allocation failed"])
        }

        guard let sourceFP = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: frame.presentationTimeStamp),
              let destFP = VTFrameProcessorFrame(buffer: destBuf, presentationTimeStamp: frame.presentationTimeStamp) else {
            throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create denoise frames"])
        }

        let previousFrames = frameHistory.dropFirst().prefix(2).map { $0 }
        guard let params = VTTemporalNoiseFilterParameters(
            sourceFrame: sourceFP,
            nextFrames: [],
            previousFrames: Array(previousFrames),
            destinationFrame: destFP,
            filterStrength: Float(denoiseStrength),
            hasDiscontinuity: previousFrames.isEmpty
        ) else {
            throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create denoise params"])
        }

        _ = try await instance.processor.process(parameters: params)
        return [VTFrame(buffer: destBuf, presentationTimeStamp: frame.presentationTimeStamp)]
    }

    private func processTemporal(instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
        guard let pool = instance.pixelBufferPool,
              let frame = inputFrames.first else { return inputFrames }

        let sourcePTS = frame.presentationTimeStamp
        guard let sourceFP = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: sourcePTS) else {
            throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create source FP frame"])
        }

        // Get the previous source frame (ring buffer index 1 = the frame before current)
        let prevSourceFP: VTFrameProcessorFrame
        let historyToUse: [VTFrameProcessorFrame]
        if temporalFirstForSRInterpolation {
            historyToUse = frameHistory
        } else {
            historyToUse = stages.keys.contains(.spatial) ? upscaledFrameHistory : frameHistory
        }
        if historyToUse.count >= 2 {
            prevSourceFP = historyToUse[1]
        } else {
            // First frame: use dummy
            let offsetTime = CMTimeSubtract(sourcePTS, CMTime(value: 1, timescale: 30))
            guard let dummy = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: offsetTime) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create dummy frame"])
            }
            prevSourceFP = dummy
        }

        let isCombined = superResolutionLevel >= 2 && frameInterpolationLevel == 2 && !temporalFirstForSRInterpolation

        if isCombined {
            // Combined 2x spatial + 2x temporal
            var buf1: CVPixelBuffer?
            var buf2: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf1) == kCVReturnSuccess, let outBuf1 = buf1,
                  CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf2) == kCVReturnSuccess, let outBuf2 = buf2 else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Combined pool allocation failed"])
            }

            let midPTS = CMTimeAdd(prevSourceFP.presentationTimeStamp,
                CMTimeMultiplyByFloat64(CMTimeSubtract(sourcePTS, prevSourceFP.presentationTimeStamp), multiplier: 0.5))

            guard let destFrame1 = VTFrameProcessorFrame(buffer: outBuf1, presentationTimeStamp: midPTS),
                  let destFrame2 = VTFrameProcessorFrame(buffer: outBuf2, presentationTimeStamp: sourcePTS) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create combined dest frames"])
            }

            guard let params = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: sourceFP,
                previousFrame: prevSourceFP,
                // Spatial mode returns both the interpolated frame and the
                // spatially-upscaled source frame.  VideoToolbox requires
                // one phase entry per destination even though the second
                // destination is the source-frame output; both entries use
                // the only supported spatial interpolation phase.
                interpolationPhase: [0.5, 0.5] as [Float],
                destinationFrames: [destFrame1, destFrame2]
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create combined params"])
            }

            _ = try await instance.processor.process(parameters: params)

            return [
                VTFrame(buffer: outBuf1, presentationTimeStamp: midPTS, isInterpolated: true),
                VTFrame(buffer: outBuf2, presentationTimeStamp: sourcePTS, isInterpolated: frame.isInterpolated)
            ]
        } else {
            // Pure temporal interpolation
            let numInterpolated = frameInterpolationLevel == 4 ? 3 : 1

            var destBufs: [CVPixelBuffer] = []
            for _ in 0..<numInterpolated {
                var buf: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf) == kCVReturnSuccess,
                      let b = buf else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "FI pool allocation failed"])
                }
                destBufs.append(b)
            }

            let diff = CMTimeSubtract(sourcePTS, prevSourceFP.presentationTimeStamp)
            var phases: [Float] = []
            var interpPTSList: [CMTime] = []
            if numInterpolated == 3 {
                phases = [0.25, 0.5, 0.75]
                for m in [0.25, 0.5, 0.75] {
                    interpPTSList.append(CMTimeAdd(prevSourceFP.presentationTimeStamp,
                        CMTimeMultiplyByFloat64(diff, multiplier: m)))
                }
            } else {
                phases = [0.5]
                interpPTSList.append(CMTimeAdd(prevSourceFP.presentationTimeStamp,
                    CMTimeMultiplyByFloat64(diff, multiplier: 0.5)))
            }

            let destFrames = destBufs.enumerated().compactMap { (i, buf) in
                VTFrameProcessorFrame(buffer: buf, presentationTimeStamp: interpPTSList[i])
            }
            guard destFrames.count == numInterpolated else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create FI dest frames"])
            }
            guard let params = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: sourceFP,
                previousFrame: prevSourceFP,
                interpolationPhase: phases,
                destinationFrames: destFrames
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create low-latency FI params"])
            }
            _ = try await instance.processor.process(parameters: params)

            var outputFrames: [VTFrame] = []
            for (i, buf) in destBufs.enumerated() {
                outputFrames.append(VTFrame(buffer: buf, presentationTimeStamp: interpPTSList[i], isInterpolated: true))
            }
            // Low-latency FI outputs only the requested in-between phases.
            // The current source frame completes the 2x/4x presentation cadence.
            outputFrames.append(frame)


            return outputFrames
        }
    }

    private func processSpatial(instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
        guard let pool = instance.pixelBufferPool else { return inputFrames }

        // Process each frame through spatial upscaling
        var outputFrames: [VTFrame] = []

        for f in inputFrames {
            var currentBuffer = f.buffer

            if temporalFirstForSRInterpolation && f.isInterpolated,
               let transferSession = interpolationTransferSession {
                let finalPool = secondSpatialPool ?? pool
                var outputBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, finalPool, &outputBuffer) == kCVReturnSuccess,
                      let destinationBuffer = outputBuffer else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Interpolated frame pool allocation failed"])
                }
                guard VTPixelTransferSessionTransferImage(
                    transferSession,
                    from: currentBuffer,
                    to: destinationBuffer
                ) == kCVReturnSuccess else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Interpolated frame scaling failed"])
                }
                currentBuffer = destinationBuffer
            } else if qualitySuperResolutionScaleFactor > 0 {
                // Quality SR
                var buf1: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf1) == kCVReturnSuccess,
                      let outBuf1 = buf1 else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Spatial pool allocation failed"])
                }
                guard let sourceFP = VTFrameProcessorFrame(buffer: currentBuffer, presentationTimeStamp: f.presentationTimeStamp),
                      let destFP = VTFrameProcessorFrame(buffer: outBuf1, presentationTimeStamp: f.presentationTimeStamp) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create spatial frames"])
                }
                let prevFP = frameHistory.dropFirst().first
                let prevOutFP = outputHistory.first
                guard let params = VTSuperResolutionScalerParameters(
                    sourceFrame: sourceFP,
                    previousFrame: prevFP,
                    previousOutputFrame: prevOutFP,
                    opticalFlow: nil,
                    submissionMode: .sequential,
                    destinationFrame: destFP
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create Quality SR params"])
                }
                _ = try await instance.processor.process(parameters: params)
                currentBuffer = outBuf1
            } else {
                // LL SR - Stage 1 2x
                var buf1: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf1) == kCVReturnSuccess,
                      let outBuf1 = buf1 else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Spatial pool allocation failed"])
                }
                guard let sourceFP = VTFrameProcessorFrame(buffer: currentBuffer, presentationTimeStamp: f.presentationTimeStamp),
                      let destFP = VTFrameProcessorFrame(buffer: outBuf1, presentationTimeStamp: f.presentationTimeStamp) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create spatial frames"])
                }
                let params = VTLowLatencySuperResolutionScalerParameters(
                    sourceFrame: sourceFP,
                    destinationFrame: destFP
                )
                _ = try await instance.processor.process(parameters: params)
                currentBuffer = outBuf1

                // Stage 2: Second 2x step for 4x LL SR
                if superResolutionLevel == 4 {
                    if let proc2 = secondSpatialProcessor,
                       let pool2 = secondSpatialPool {
                        var buf2: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool2, &buf2) == kCVReturnSuccess,
                              let outBuf2 = buf2 else {
                            throw NSError(domain: "VTFrameProcessorCoordinator", code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "Spatial stage 2 pool allocation failed"])
                        }
                        guard let sourceFP2 = VTFrameProcessorFrame(buffer: currentBuffer, presentationTimeStamp: f.presentationTimeStamp),
                              let destFP2 = VTFrameProcessorFrame(buffer: outBuf2, presentationTimeStamp: f.presentationTimeStamp) else {
                            throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to create spatial stage 2 frames"])
                        }
                        let params2 = VTLowLatencySuperResolutionScalerParameters(
                            sourceFrame: sourceFP2,
                            destinationFrame: destFP2
                        )
                        _ = try await proc2.process(parameters: params2)
                        currentBuffer = outBuf2
                    } else if let fallbackSession = fallbackTransferSession {
                        var buf2: CVPixelBuffer?
                        let outW = CVPixelBufferGetWidth(currentBuffer) * 2
                        let outH = CVPixelBufferGetHeight(currentBuffer) * 2
                        let attrs: [String: Any] = [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            kCVPixelBufferWidthKey as String: outW,
                            kCVPixelBufferHeightKey as String: outH,
                            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
                        ]
                        guard CVPixelBufferCreate(kCFAllocatorDefault, outW, outH, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &buf2) == kCVReturnSuccess,
                              let outBuf2 = buf2 else {
                            throw NSError(domain: "VTFrameProcessorCoordinator", code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "Spatial stage 2 fallback allocation failed"])
                        }
                        guard VTPixelTransferSessionTransferImage(
                            fallbackSession,
                            from: currentBuffer,
                            to: outBuf2
                        ) == kCVReturnSuccess else {
                            throw NSError(domain: "VTFrameProcessorCoordinator", code: -4,
                                userInfo: [NSLocalizedDescriptionKey: "Spatial stage 2 fallback scaling failed"])
                        }
                        currentBuffer = outBuf2
                    }
                }
            }

            outputFrames.append(VTFrame(buffer: currentBuffer, presentationTimeStamp: f.presentationTimeStamp, isInterpolated: f.isInterpolated))

            if !temporalFirstForSRInterpolation || !f.isInterpolated,
               let outFP = VTFrameProcessorFrame(buffer: currentBuffer, presentationTimeStamp: f.presentationTimeStamp) {
                outputHistory.insert(outFP, at: 0)
                if outputHistory.count > maxHistoryLength {
                    outputHistory.removeLast()
                }

                // Track source outputs for the temporal interpolation stage / motion blur.
                // In temporal-first mode, interpolated frames must not displace the
                // previous source frame in the history ring.
                upscaledFrameHistory.insert(outFP, at: 0)
                if upscaledFrameHistory.count > maxHistoryLength {
                    upscaledFrameHistory.removeLast()
                }
            }
        }

        return outputFrames
    }

    private func processMotionBlur(instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
        guard motionBlurStrength > 0,
              let pool = instance.pixelBufferPool,
              !inputFrames.isEmpty else { return inputFrames }

        var outputFrames: [VTFrame] = []

        for (idx, frame) in inputFrames.enumerated() {
            var outBuf: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuf) == kCVReturnSuccess,
                  let destBuf = outBuf else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "MB pool allocation failed"])
            }

            guard let sourceFP = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: frame.presentationTimeStamp),
                  let destFP = VTFrameProcessorFrame(buffer: destBuf, presentationTimeStamp: frame.presentationTimeStamp) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create MB frames"])
            }

            // Use the previous frame in the input batch, or fall back to
            // frameHistory/upscaledFrameHistory for the first frame in the batch.
            let prevFP: VTFrameProcessorFrame
            if idx > 0,
               let prev = VTFrameProcessorFrame(buffer: inputFrames[idx - 1].buffer,
                                                 presentationTimeStamp: inputFrames[idx - 1].presentationTimeStamp) {
                prevFP = prev
            } else {
                let historyToUse = stages.keys.contains(.spatial) ? upscaledFrameHistory : frameHistory
                prevFP = historyToUse.count >= 2 ? historyToUse[1] : sourceFP
            }

            let nextFP: VTFrameProcessorFrame
            if idx + 1 < inputFrames.count,
               let next = VTFrameProcessorFrame(
                   buffer: inputFrames[idx + 1].buffer,
                   presentationTimeStamp: inputFrames[idx + 1].presentationTimeStamp
               ) {
                nextFP = next
            } else {
                nextFP = sourceFP
            }

            guard let params = VTMotionBlurParameters(
                sourceFrame: sourceFP,
                nextFrame: nextFP,
                previousFrame: prevFP,
                nextOpticalFlow: nil,
                previousOpticalFlow: nil,
                motionBlurStrength: motionBlurStrength,
                submissionMode: .sequential,
                destinationFrame: destFP
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create MB params"])
            }

            _ = try await instance.processor.process(parameters: params)
            outputFrames.append(VTFrame(
                buffer: destBuf,
                presentationTimeStamp: frame.presentationTimeStamp,
                isInterpolated: frame.isInterpolated
            ))
        }

        return outputFrames
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

    private func completeEndSession() {
        var hasResources = isSessionActive || !stages.isEmpty || secondSpatialProcessor != nil ||
            fallbackTransferSession != nil || interpolationTransferSession != nil
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

        #if os(macOS)
        if let session = rendererTransferSession {
            VTPixelTransferSessionInvalidate(session)
        }
        rendererTransferSession = nil
        rendererPixelBufferPool = nil
        #endif

        if let session = interpolationTransferSession {
            VTPixelTransferSessionInvalidate(session)
        }
        interpolationTransferSession = nil
        temporalFirstForSRInterpolation = false

        frameHistory.removeAll()
        outputHistory.removeAll()
        upscaledFrameHistory.removeAll()
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

    // MARK: - Helpers

    private func configureTransferSession(_ session: VTPixelTransferSession) {
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

    public let superResolutionLevel: Int
    public let frameInterpolationLevel: Int
    public let useHighQualityDownsampling: Bool
    public let useRealTimePriority: Bool
    public let qualitySuperResolutionScaleFactor: Int
    public let motionBlurStrength: Int
    public let denoiseStrength: Double
    public let qualityPrioritization: Int

    public init(
        superResolutionLevel: Int,
        frameInterpolationLevel: Int,
        useHighQualityDownsampling: Bool = true,
        useRealTimePriority: Bool = true,
        qualitySuperResolutionScaleFactor: Int = 0,
        motionBlurStrength: Int = 0,
        denoiseStrength: Double = 0.0,
        qualityPrioritization: Int = 1
    ) {
        self.superResolutionLevel = superResolutionLevel
        self.frameInterpolationLevel = frameInterpolationLevel
        self.useHighQualityDownsampling = useHighQualityDownsampling
        self.useRealTimePriority = useRealTimePriority
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
    
    public func clearHistory() {}
}
#endif
