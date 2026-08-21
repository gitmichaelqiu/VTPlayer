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
extension VTFrameProcessorCoordinator {

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

    #if os(macOS)
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
        // QSR4 followed by FI makes the temporal processor operate on a
        // 4x surface and can starve the display. Interpolate at source
        // resolution, then apply the complete QSR4 pass to every output.
        #if os(macOS)
        let useTemporalFirstForSRInterpolation =
            ((superResolutionLevel > 0 && !inCombinedMode) || qualitySuperResolutionScaleFactor == 4) &&
            frameInterpolationLevel > 0
        #else
        let useTemporalFirstForSRInterpolation =
            qualitySuperResolutionScaleFactor == 4 && frameInterpolationLevel > 0
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
#endif
