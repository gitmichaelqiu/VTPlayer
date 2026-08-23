import AVFoundation
import CoreMedia
import Foundation

nonisolated struct EnhancedFrameCachePreparationResult: Sendable {
    var key: EnhancedFrameCacheKey
    var benchmark: EnhancedPipelineBenchmark
    var status: EnhancedFrameCacheStatus
    var totalGroupCount: Int
    var mode: EnhancedCachePlaybackMode
}

@MainActor
private final class EnhancedPipelineBenchmarkOutputCollector {
    private(set) var count = 0
    private(set) var byteCount: Int64 = 0

    func reset() {
        count = 0
        byteCount = 0
    }

    func record(_ frame: VTFrame) {
        count += 1
        byteCount += Int64(CVPixelBufferGetDataSize(frame.buffer))
    }
}

/// Owns cache preparation off the view model. VideoToolbox processing remains
/// sequential inside one coordinator so temporal references retain order.
actor EnhancedFrameCachePreparer {
    private let diskCache: EnhancedFrameDiskCache

    init(diskCache: EnhancedFrameDiskCache) {
        self.diskCache = diskCache
    }

    func benchmark(
        url: URL,
        width: Int,
        height: Int,
        sourceFramesPerSecond: Double,
        configuration: AppliedPipelineConfiguration,
        qualityPrioritization: Int,
        preferSequentialSRFI: Bool,
        sampleCount: Int = 60
    ) async throws -> EnhancedPipelineBenchmark {
        let coordinator = makeCoordinator(
            configuration: configuration,
            qualityPrioritization: qualityPrioritization,
            preferSequentialSRFI: preferSequentialSRFI
        )
        try await coordinator.startSession(width: width, height: height)
        do {
            let streamedOutputCollector = await MainActor.run {
                EnhancedPipelineBenchmarkOutputCollector()
            }
            let padding = await coordinator.sourceFramePadding()
            var iterator = VTFrameSequence(
                url: url,
                startTime: .zero,
                extendedPixelsRight: padding.right,
                extendedPixelsBottom: padding.bottom
            ).makeAsyncIterator()
            var samples: [Double] = []
            var outputCount = 0
            var outputBytes: Int64 = 0
            var warmupRemaining = 4

            while samples.count < sampleCount, let frame = try await iterator.next() {
                try Task.checkCancellation()
                await streamedOutputCollector.reset()
                let start = DispatchTime.now()
                let output = try await coordinator.processFrame(frame) { streamedFrame in
                    streamedOutputCollector.record(streamedFrame)
                    return true
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
                let streamedOutputCount = await streamedOutputCollector.count
                let streamedOutputBytes = await streamedOutputCollector.byteCount
                if warmupRemaining > 0 {
                    warmupRemaining -= 1
                    continue
                }
                samples.append(elapsed)
                outputCount += output.count + streamedOutputCount
                outputBytes += streamedOutputBytes + output.reduce(into: 0) { partialResult, frame in
                    partialResult += Int64(CVPixelBufferGetDataSize(frame.buffer))
                }
            }
            await coordinator.endSession()
            guard !samples.isEmpty else { throw EnhancedFrameDiskCacheError.invalidFrameData }
            let sorted = samples.sorted()
            let percentile: (Double) -> Double = { fraction in
                sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded(.up))))]
            }
            let requestedOutputRate = sourceFramesPerSecond * Double(max(1, configuration.frameInterpolationLevel))
            return EnhancedPipelineBenchmark(
                p50GroupSeconds: percentile(0.5),
                p95GroupSeconds: percentile(0.95),
                sourceFramesPerSecond: sourceFramesPerSecond,
                requestedOutputFramesPerSecond: requestedOutputRate,
                // Presentation is rechecked from live renderer diagnostics. This
                // benchmark establishes the processing-side admission decision.
                measuredDisplayFramesPerSecond: requestedOutputRate,
                outputFramesPerGroup: Double(outputCount) / Double(samples.count),
                averageOutputBytesPerGroup: outputBytes / Int64(samples.count),
                diskWriteBytesPerSecond: 0
            )
        } catch {
            await coordinator.endSession()
            throw error
        }
    }

    func prepareCache(
        url: URL,
        width: Int,
        height: Int,
        sourceFramesPerSecond: Double,
        estimatedGroupCount: Int,
        plan: SparseCachePlan,
        configuration: AppliedPipelineConfiguration,
        qualityPrioritization: Int,
        preferSequentialSRFI: Bool,
        diskBudgetBytes: Int64,
        estimatedRequiredBytes: Int64,
        benchmark: EnhancedPipelineBenchmark,
        progress: @MainActor @Sendable (Double, Int64) -> Void
    ) async throws -> EnhancedFrameCachePreparationResult {
        let fingerprint = try EnhancedFrameDiskCache.sourceFingerprint(for: url)
        let key = EnhancedFrameCacheKey(sourceFingerprint: fingerprint, configuration: configuration)
        let preparationIdentifier = UUID()
        let coverage = plan.coverageBitmap
        let priorCacheStatus = try await diskCache.cachedStatus(for: key)
        if let cached = priorCacheStatus,
           cached.satisfies(coverage: coverage) {
            return EnhancedFrameCachePreparationResult(
                key: key,
                benchmark: benchmark,
                status: cached,
                totalGroupCount: cached.coverageBitmap.count,
                mode: plan.mode
            )
        }
        let existing = try await diskCache.prepare(
            key: key,
            coverageBitmap: coverage,
            diskBudgetBytes: diskBudgetBytes,
            requiredAdditionalBytes: max(0, estimatedRequiredBytes - (priorCacheStatus?.byteCount ?? 0)),
            preparationIdentifier: preparationIdentifier
        )
        if existing.missingGroupIndices.isEmpty {
            try await diskCache.discardPreparation(preparationIdentifier: preparationIdentifier)
            return EnhancedFrameCachePreparationResult(
                key: key,
                benchmark: benchmark,
                status: existing,
                totalGroupCount: existing.coverageBitmap.count,
                mode: plan.mode
            )
        }

        let coordinator = makeCoordinator(
            configuration: configuration,
            qualityPrioritization: qualityPrioritization,
            preferSequentialSRFI: preferSequentialSRFI
        )
        do {
            try await coordinator.startSession(width: width, height: height)
            let padding = await coordinator.sourceFramePadding()
            var iterator = VTFrameSequence(
                url: url,
                startTime: .zero,
                extendedPixelsRight: padding.right,
                extendedPixelsBottom: padding.bottom
            ).makeAsyncIterator()
            var groupIndex = 0
            var writtenBytes = existing.byteCount
            while let frame = try await iterator.next() {
                try Task.checkCancellation()
                try await diskCache.recordSourceGroup(
                    groupIndex,
                    presentationTime: frame.presentationTimeStamp,
                    preparationIdentifier: preparationIdentifier
                )
                let shouldCacheGroup = coverage.indices.contains(groupIndex) && coverage[groupIndex]
                if shouldCacheGroup && !existing.availableGroupIndices.contains(groupIndex) {
                    let output = try await coordinator.processFrame(frame)
                    try await diskCache.writeGroup(
                        output,
                        for: groupIndex,
                        sourcePresentationTime: frame.presentationTimeStamp,
                        preparationIdentifier: preparationIdentifier
                    )
                    writtenBytes += Int64(output.reduce(0) { $0 + CVPixelBufferGetDataSize($1.buffer) })
                } else if !(await coordinator.advanceSourceHistory(forCachedGroup: frame)) {
                    throw EnhancedFrameDiskCacheError.invalidFrameData
                }
                groupIndex += 1
                if groupIndex.isMultiple(of: 4) || groupIndex == estimatedGroupCount {
                    await progress(
                        min(1, Double(groupIndex) / Double(max(1, estimatedGroupCount))),
                        writtenBytes
                    )
                }
            }
            await coordinator.endSession()
            let status = try await diskCache.finalizePreparation(
                actualGroupCount: groupIndex,
                preparationIdentifier: preparationIdentifier
            )
            await progress(1, status.byteCount)
            return EnhancedFrameCachePreparationResult(
                key: key,
                benchmark: benchmark,
                status: status,
                totalGroupCount: groupIndex,
                mode: plan.mode
            )
        } catch {
            await coordinator.endSession()
            try? await diskCache.discardPreparation(preparationIdentifier: preparationIdentifier)
            throw error
        }
    }

    private func makeCoordinator(
        configuration: AppliedPipelineConfiguration,
        qualityPrioritization: Int,
        preferSequentialSRFI: Bool
    ) -> VTFrameProcessorCoordinator {
        VTFrameProcessorCoordinator(
            superResolutionLevel: configuration.superResolutionLevel,
            frameInterpolationLevel: configuration.frameInterpolationLevel,
            useHighQualityDownsampling: true,
            useRealTimePriority: true,
            preferSequentialSRFI: preferSequentialSRFI,
            qualitySuperResolutionScaleFactor: configuration.qualitySuperResolutionScaleFactor,
            motionBlurStrength: configuration.motionBlurStrength,
            denoiseStrength: configuration.denoiseStrength,
            qualityPrioritization: qualityPrioritization
        )
    }
}
