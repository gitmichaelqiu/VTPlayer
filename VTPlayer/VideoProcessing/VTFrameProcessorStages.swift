import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
extension VTFrameProcessorCoordinator {
    // MARK: - Process Frame

    func beginProcessing() -> Bool {
        guard isSessionActive, !endRequested else { return false }
        activeProcessCount += 1
        return true
    }

    func finishProcessing() {
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
            currentFrames = try currentFrames.map {
                isNativeHDR($0.buffer) ? $0 : try convertForRenderer($0, session: session, pool: pool)
            }
        }
        #endif

        return currentFrames
    }

    #if os(macOS)
    func convertForRenderer(_ frame: VTFrame, session: VTPixelTransferSession, pool: CVPixelBufferPool) throws -> VTFrame {
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

    func processStage(_ stage: PipelineStage, instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
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

    func processDenoise(instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
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

    func processTemporal(instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
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

        #if os(macOS)
        let isCombined = superResolutionLevel >= 2 && frameInterpolationLevel == 2 && !temporalFirstForSRInterpolation
        #else
        let isCombined = false
        #endif

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
                // In spatial mode, VideoToolbox supports one interpolated
                // midpoint plus an additional destination for the scaled
                // source frame. Supplying a second 0.5 phase makes that
                // source-output slot ambiguous and can yield alternating
                // interpolation-quality frames at presentation time.
                interpolationPhase: [0.5] as [Float],
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

    func processSpatial(instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
        guard let pool = instance.pixelBufferPool else { return inputFrames }

        // Process each frame through spatial upscaling
        var outputFrames: [VTFrame] = []

        for f in inputFrames {
            var currentBuffer = f.buffer

            if qualitySuperResolutionScaleFactor > 0 {
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
                    } else if let fallbackSession = fallbackTransferSession,
                              let fallbackPool = secondSpatialPool {
                        var buf2: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, fallbackPool, &buf2) == kCVReturnSuccess,
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

    func processMotionBlur(instance: StageInstance, inputFrames: [VTFrame]) async throws -> [VTFrame] {
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
            let prevFP: VTFrameProcessorFrame?
            if idx > 0,
               let prev = VTFrameProcessorFrame(buffer: inputFrames[idx - 1].buffer,
                                                 presentationTimeStamp: inputFrames[idx - 1].presentationTimeStamp) {
                prevFP = prev
            } else {
                let historyToUse = stages.keys.contains(.spatial) ? upscaledFrameHistory : frameHistory
                prevFP = historyToUse.count >= 2 ? historyToUse[1] : nil
            }

            let nextFP: VTFrameProcessorFrame?
            if idx + 1 < inputFrames.count,
               let next = VTFrameProcessorFrame(
                   buffer: inputFrames[idx + 1].buffer,
                   presentationTimeStamp: inputFrames[idx + 1].presentationTimeStamp
               ) {
                nextFP = next
            } else {
                nextFP = nil
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

}
#endif
