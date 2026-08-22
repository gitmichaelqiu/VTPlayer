import Foundation
@preconcurrency import VideoToolbox
import CoreMedia
@preconcurrency import CoreVideo

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

    public func processFrame(
        _ frame: VTFrame,
        onOutput: (@MainActor @Sendable (VTFrame) async -> Bool)? = nil
    ) async throws -> [VTFrame] {
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

        let canStreamTemporalOutput = onOutput != nil &&
            !(superResolutionLevel == 2 && frameInterpolationLevel == 2 && !temporalFirstForSRInterpolation) &&
            (temporalFirstForSRInterpolation || stages[.spatial] == nil) &&
            motionBlurStrength <= 0 &&
            qualitySuperResolutionScaleFactor <= 0 &&
            stages[.temporal] != nil

        if canStreamTemporalOutput, let temporalInstance = stages[.temporal], let onOutput {
            if let denoiseInstance = stages[.denoise] {
                currentFrames = try await processDenoise(instance: denoiseInstance, inputFrames: currentFrames)
            }

            _ = try await processTemporal(
                instance: temporalInstance,
                inputFrames: currentFrames,
                colorSource: frame.buffer,
                onOutput: { outputFrame in
                    guard await onOutput(outputFrame) else {
                        throw CancellationError()
                    }
                }
            )
            return []
        }

        for stage in orderedStages {
            guard let instance = stages[stage] else { continue }
            currentFrames = try await processStage(stage, instance: instance, inputFrames: currentFrames)
            for outputFrame in currentFrames {
                propagateColorAttachments(from: frame.buffer, to: outputFrame.buffer)
            }
        }

        return currentFrames
    }

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

}
#endif
