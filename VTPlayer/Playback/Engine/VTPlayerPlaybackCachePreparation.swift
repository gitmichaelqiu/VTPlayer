import AVFoundation
import CoreMedia
import Foundation

extension VTPlayerViewModel {
    func cancelEnhancedCachePreparation() {
        guard enhancedCachePreparationTask != nil else { return }
        enhancedCachePreparationGeneration &+= 1
        enhancedCachePreparationTask?.cancel()
        enhancedCachePreparationTask = nil
        enhancedCachePreparationState = .idle
    }

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

        cancelEnhancedCachePreparation()
        enhancedCachePreparationGeneration &+= 1
        let preparationGeneration = enhancedCachePreparationGeneration
        enhancedCachePreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.enhancedCachePreparationGeneration == preparationGeneration {
                    self.enhancedCachePreparationTask = nil
                }
            }
            if let teardown = self.coordinatorTeardownTask {
                await teardown.value
                self.coordinatorTeardownTask = nil
            }
            guard self.enhancedCachePreparationGeneration == preparationGeneration,
                  self.videoURL == url,
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
                guard self.enhancedCachePreparationGeneration == preparationGeneration,
                      self.videoURL == url,
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
                    self.preparedEnhancedFrameCacheMode = nil
                    self.enhancedCacheCoveragePercent = 0
                    self.appliedPipelineConfiguration = candidate
                    self.enhancedCachePreparationState = .ready
                    self.resumeAfterApplyingEnhancements(wasPlaying: wasPlaying)
                    return
                }

                self.enhancedCachePreparationState = .preparing(progress: 0, bytesWritten: 0)
                let estimatedBytesPerGroup = max(1, benchmark.averageOutputBytesPerGroup)
                let result = try await preparer.prepareCache(
                    url: url,
                    width: self.videoWidth,
                    height: self.videoHeight,
                    sourceFramesPerSecond: sourceRate,
                    estimatedGroupCount: groupCount,
                    plan: plan,
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
                guard self.enhancedCachePreparationGeneration == preparationGeneration,
                      self.videoURL == url,
                      self.draftPipelineConfiguration == candidate else { return }
                self.preparedEnhancedFrameCacheKey = result.key
                self.preparedEnhancedFrameCacheMode = result.mode
                self.enhancedCacheCoveragePercent = result.status.coverageBitmap.isEmpty
                    ? 0
                    : Int((Double(result.status.coverageBitmap.filter { $0 }.count) / Double(result.status.coverageBitmap.count) * 100).rounded())
                self.appliedPipelineConfiguration = candidate
                self.enhancedCachePreparationState = .ready
                NSLog(
                    "CACHE: prepared mode=%@ groups=%d bytes=%lld",
                    result.mode.rawValue,
                    result.totalGroupCount,
                    result.status.byteCount
                )
                self.resumeAfterApplyingEnhancements(wasPlaying: wasPlaying)
            } catch is CancellationError {
                if self.enhancedCachePreparationGeneration == preparationGeneration {
                    self.enhancedCachePreparationState = .idle
                }
            } catch {
                if self.enhancedCachePreparationGeneration == preparationGeneration {
                    self.enhancedCachePreparationState = .failed(error.localizedDescription)
                    self.srInitializationError = error.localizedDescription
                    self.setNativeVideoEnabled(true)
                    if wasPlaying {
                        self.player?.rate = Float(self.playbackSpeed)
                        self.isPaused = false
                    }
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
