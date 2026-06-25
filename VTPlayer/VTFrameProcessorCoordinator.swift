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

/// Ordered pipeline stages for frame processing.
public enum PipelineStage: Int, Comparable, CaseIterable {
    case denoise    // Temporal noise filter (VTTemporalNoiseFilter)
    case temporal   // Frame interpolation or frame rate conversion
    case spatial    // Super resolution (LL SR or Quality SR)
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

    // Source dimensions for the pipeline
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var targetWidth = 0
    private var targetHeight = 0

    // Reference frame ring buffer (newest first)
    private var frameHistory: [VTFrameProcessorFrame] = []
    private var outputHistory: [VTFrameProcessorFrame] = []
    private let maxHistoryLength = 8

    // Fallback transfer session (for unsupported 2nd stage SR scaler)
    private var fallbackTransferSession: VTPixelTransferSession?

    // Transfer session for interpolated frames to bypass heavy SR processing
    private var interpolationTransferSession: VTPixelTransferSession?

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
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 15] as CFDictionary
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, dict as CFDictionary, &pool)
        return status == kCVReturnSuccess ? pool : nil
    }

    // MARK: - Start Session

    public func startSession(width: Int, height: Int) throws {
        guard !isSessionActive else { return }

        self.sourceWidth = width
        self.sourceHeight = height
        self.frameHistory.removeAll()
        self.outputHistory.removeAll()
        self.stages.removeAll()

        var currentWidth = width
        var currentHeight = height
        var buildError: Error?

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
            if #available(macOS 26.0, *),
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

        // ── 2. Temporal Stage ─────────────────────────────────────────
        let useQualitySR = qualitySuperResolutionScaleFactor > 0
        let inCombinedMode = superResolutionLevel == 2 && frameInterpolationLevel == 2
        let inSR4FI2Mode = superResolutionLevel == 4 && frameInterpolationLevel == 2

        if frameInterpolationLevel > 0 {
            if inCombinedMode || inSR4FI2Mode {
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
                let numFrames = frameInterpolationLevel == 4 ? 3 : 1
                guard let config = VTLowLatencyFrameInterpolationConfiguration(
                    frameWidth: currentWidth,
                    frameHeight: currentHeight,
                    numberOfInterpolatedFrames: numFrames
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create FI config"])
                }
                let proc = VTFrameProcessor()
                try proc.startSession(configuration: config)
                let pool = makePool(width: currentWidth, height: currentHeight, from: config.destinationPixelBufferAttributes)
                guard pool != nil else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create FI pool"])
                }
                addStage(.temporal, processor: proc, pool: pool, outW: currentWidth, outH: currentHeight)
            }
        }

        // ── 3. Spatial Stage ──────────────────────────────────────────
        let hasQualitySR = qualitySuperResolutionScaleFactor > 0
        let hasLLSR = superResolutionLevel >= 2
        let needsSpatial = hasQualitySR || (hasLLSR && !inCombinedMode)

        if needsSpatial {
            var transferSession: VTPixelTransferSession?
            if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession) == kCVReturnSuccess,
               let session = transferSession {
                configureTransferSession(session)
                self.interpolationTransferSession = session
            }

            // If combined mode already handled spatial (temporal stage produced 2x), skip LL SR
            if hasQualitySR {
                // Quality SR — single stage at requested scale
                let scale = qualitySuperResolutionScaleFactor
                guard #available(macOS 26.0, *),
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
                let config1 = VTLowLatencySuperResolutionScalerConfiguration(
                    frameWidth: currentWidth,
                    frameHeight: currentHeight,
                    scaleFactor: 2.0
                )
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
                        var transferSession: VTPixelTransferSession?
                        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
                        if status == kCVReturnSuccess, let session = transferSession {
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
        } else {
            // No spatial stage — target is current width/height (input or temporal output)
        }

        // ── 4. Motion Blur Stage ──────────────────────────────────────
        if motionBlurStrength > 0 {
            guard #available(macOS 26.0, *),
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
        self.isSessionActive = true
    }

    // MARK: - Process Frame

    public func processFrame(_ frame: VTFrame) async throws -> [VTFrame] {
        guard isSessionActive else { return [frame] }

        // Track this frame in history
        if let fpFrame = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: frame.presentationTimeStamp) {
            frameHistory.insert(fpFrame, at: 0)
            if frameHistory.count > maxHistoryLength {
                frameHistory.removeLast()
            }
        }

        var currentFrames: [VTFrame] = [frame]

        // Process stages in order
        let orderedStages = PipelineStage.allCases
            .filter { stages.keys.contains($0) }
            .sorted()

        for stage in orderedStages {
            guard let instance = stages[stage] else { continue }
            currentFrames = try await processStage(stage, instance: instance, inputFrames: currentFrames)
        }

        return currentFrames
    }

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
        if frameHistory.count >= 2 {
            prevSourceFP = frameHistory[1]
        } else {
            // First frame: use dummy
            let offsetTime = CMTimeSubtract(sourcePTS, CMTime(value: 1, timescale: 30))
            guard let dummy = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: offsetTime) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create dummy frame"])
            }
            prevSourceFP = dummy
        }

        let isCombined = superResolutionLevel >= 2 && frameInterpolationLevel == 2

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
                interpolationPhase: [0.5] as [Float],
                destinationFrames: [destFrame1, destFrame2]
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create combined params"])
            }

            _ = try await instance.processor.process(parameters: params)

            return [
                VTFrame(buffer: outBuf1, presentationTimeStamp: midPTS),
                VTFrame(buffer: outBuf2, presentationTimeStamp: sourcePTS)
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

            // Log params creation
            let params = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: sourceFP,
                previousFrame: prevSourceFP,
                interpolationPhase: phases,
                destinationFrames: destFrames
            )
            guard let params = params else {
                print("⚠️ VTLowLatencyFrameInterpolationParameters returned nil: fiLevel=\(frameInterpolationLevel), phases=\(phases), destCount=\(destFrames.count)")
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create FI params"])
            }

            _ = try await instance.processor.process(parameters: params)

            var outputFrames: [VTFrame] = []
            for (i, buf) in destBufs.enumerated() {
                outputFrames.append(VTFrame(buffer: buf, presentationTimeStamp: interpPTSList[i]))
            }
            // Include the source frame as the final output
            outputFrames.append(frame)


            return outputFrames
        }
    }

    private func processSpatial(instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
        guard let pool = instance.pixelBufferPool else { return inputFrames }
        let finalPool = self.secondSpatialPool ?? pool

        // Process each frame through spatial upscaling
        var outputFrames: [VTFrame] = []

        for (idx, f) in inputFrames.enumerated() {
            let isSourceFrame = idx == inputFrames.count - 1
            var currentBuffer = f.buffer

            if !isSourceFrame, let transferSession = interpolationTransferSession {
                // Upscale interpolated frames directly to the final target size in a single step
                // to prevent GPU/bandwidth starvation, while keeping output resolution consistent.
                var outBuf: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, finalPool, &outBuf) == kCVReturnSuccess,
                      let destinationBuffer = outBuf else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Spatial pool allocation failed for interpolated frame"])
                }
                VTPixelTransferSessionTransferImage(transferSession, from: currentBuffer, to: destinationBuffer)
                outputFrames.append(VTFrame(buffer: destinationBuffer, presentationTimeStamp: f.presentationTimeStamp))
                continue
            }

            // Stage 1: LL SR or Quality SR
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

            if qualitySuperResolutionScaleFactor > 0 {
                // Quality SR
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
            } else {
                // LL SR
                let params = VTLowLatencySuperResolutionScalerParameters(
                    sourceFrame: sourceFP,
                    destinationFrame: destFP
                )
                _ = try await instance.processor.process(parameters: params)
            }

            currentBuffer = outBuf1

            // Stage 2: Second 2x step for 4x LL SR
            if superResolutionLevel == 4 && qualitySuperResolutionScaleFactor == 0 {
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
                    VTPixelTransferSessionTransferImage(fallbackSession, from: currentBuffer, to: outBuf2)
                    currentBuffer = outBuf2
                }
            }

            outputFrames.append(VTFrame(buffer: currentBuffer, presentationTimeStamp: f.presentationTimeStamp))

            if let outFP = VTFrameProcessorFrame(buffer: currentBuffer, presentationTimeStamp: f.presentationTimeStamp) {
                outputHistory.insert(outFP, at: 0)
                if outputHistory.count > maxHistoryLength {
                    outputHistory.removeLast()
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
            // frameHistory for the first frame in the batch.
            let prevFP: VTFrameProcessorFrame
            if idx > 0,
               let prev = VTFrameProcessorFrame(buffer: inputFrames[idx - 1].buffer,
                                                 presentationTimeStamp: inputFrames[idx - 1].presentationTimeStamp) {
                prevFP = prev
            } else {
                prevFP = frameHistory.count >= 2 ? frameHistory[1] : sourceFP
            }

            guard let params = VTMotionBlurParameters(
                sourceFrame: sourceFP,
                nextFrame: sourceFP,
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
            outputFrames.append(VTFrame(buffer: destBuf, presentationTimeStamp: frame.presentationTimeStamp))
        }

        return outputFrames
    }

    // MARK: - End Session

    public func endSession() {
        guard isSessionActive else { return }

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

        if let session = interpolationTransferSession {
            VTPixelTransferSessionInvalidate(session)
        }
        interpolationTransferSession = nil

        frameHistory.removeAll()
        outputHistory.removeAll()
        isSessionActive = false
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
