import AVFoundation
import CoreMedia
import Foundation

extension VTPlayerViewModel {
    func applyPipelineEnhancements() {
        validateEnhancementSelections()
        #if os(macOS)
        guard hasUnappliedPipelineChanges else { return }
        let candidate = draftPipelineConfiguration
        guard let url = videoURL, videoWidth > 0, videoHeight > 0 else {
            appliedPipelineConfiguration = candidate
            restartAppliedEnhancements()
            return
        }

        let wasPlaying = isPlaying && !isPaused
        player?.pause()
        isPaused = true
        stopPlaybackLoopOnly()
        enhancedCachePreparationState = .benchmarking

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let teardown = self.coordinatorTeardownTask {
                await teardown.value
                self.coordinatorTeardownTask = nil
            }
            guard self.videoURL == url,
                  self.draftPipelineConfiguration == candidate else { return }

            let sourceRate = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30
            let preparer = EnhancedFrameCachePreparer(diskCache: self.enhancedFrameDiskCache)
            do {
                let benchmark = try await preparer.benchmark(
                    url: url,
                    width: self.videoWidth,
                    height: self.videoHeight,
                    sourceFramesPerSecond: sourceRate,
                    configuration: candidate,
                    qualityPrioritization: self.qualityPrioritization,
                    preferSequentialSRFI: self.useSequentialSRFIFallback
                )
                guard self.videoURL == url,
                      self.draftPipelineConfiguration == candidate else { return }

                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let groupCount = max(1, Int((CMTimeGetSeconds(duration) * sourceRate).rounded(.up)) + 8)
                let plan = SparseCachePlanner.makePlan(
                    benchmark: benchmark,
                    configuration: candidate,
                    totalGroupCount: groupCount
                )
                NSLog(
                    "CACHE: benchmark p50Ms=%.2f p95Ms=%.2f sourceFPS=%.3f mode=%@ coverage=%d%% groups=%d",
                    benchmark.p50GroupSeconds * 1_000,
                    benchmark.p95GroupSeconds * 1_000,
                    sourceRate,
                    plan.mode.rawValue,
                    plan.coveragePercent,
                    groupCount
                )
                if plan.mode == .realTime {
                    self.preparedEnhancedFrameCacheKey = nil
                    self.appliedPipelineConfiguration = candidate
                    self.enhancedCachePreparationState = .ready
                    self.resumeAfterApplyingEnhancements(wasPlaying: wasPlaying)
                    return
                }

                // Full caching is the only enabled preparation mode until
                // hybrid FI equivalence has been validated on-device.
                self.enhancedCachePreparationState = .preparing(progress: 0, bytesWritten: 0)
                let scale = max(1, max(candidate.superResolutionLevel, Float(candidate.qualitySuperResolutionScaleFactor)))
                let outputMultiplier = max(1, candidate.frameInterpolationLevel)
                let estimatedBytesPerGroup = Int64(
                    Double(self.videoWidth * self.videoHeight) * 2 * Double(scale * scale) * Double(outputMultiplier)
                )
                let result = try await preparer.prepareFullCache(
                    url: url,
                    width: self.videoWidth,
                    height: self.videoHeight,
                    sourceFramesPerSecond: sourceRate,
                    estimatedGroupCount: groupCount,
                    configuration: candidate,
                    qualityPrioritization: self.qualityPrioritization,
                    preferSequentialSRFI: self.useSequentialSRFIFallback,
                    diskBudgetBytes: self.enhancedFrameDiskCacheBudget,
                    estimatedRequiredBytes: Int64(Double(estimatedBytesPerGroup * Int64(groupCount)) * 1.2),
                    benchmark: benchmark
                ) { [weak self] progress, bytesWritten in
                    self?.enhancedCachePreparationState = .preparing(
                        progress: progress,
                        bytesWritten: bytesWritten
                    )
                }
                guard self.videoURL == url,
                      self.draftPipelineConfiguration == candidate else { return }
                self.preparedEnhancedFrameCacheKey = result.key
                self.appliedPipelineConfiguration = candidate
                self.enhancedCachePreparationState = .ready
                NSLog(
                    "CACHE: prepared mode=full groups=%d bytes=%lld",
                    result.totalGroupCount,
                    result.status.byteCount
                )
                self.resumeAfterApplyingEnhancements(wasPlaying: wasPlaying)
            } catch is CancellationError {
                self.enhancedCachePreparationState = .idle
            } catch {
                self.enhancedCachePreparationState = .failed(error.localizedDescription)
                self.srInitializationError = error.localizedDescription
                self.setNativeVideoEnabled(true)
                if wasPlaying {
                    self.player?.rate = Float(self.playbackSpeed)
                    self.isPaused = false
                }
            }
        }
        #else
        appliedPipelineConfiguration = draftPipelineConfiguration
        restartAppliedEnhancements()
        #endif
    }

    private func resumeAfterApplyingEnhancements(wasPlaying: Bool) {
        if wasPlaying {
            isPlaying = true
            isPaused = false
            startPlaybackLoop()
        } else {
            isPaused = true
        }
    }
}
