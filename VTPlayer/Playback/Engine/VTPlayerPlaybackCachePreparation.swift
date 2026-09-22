import AVFoundation
import CoreMedia
import Foundation

extension VTPlayerViewModel {
    func cancelEnhancedCachePreparation(restorePreviousPlayback: Bool = true) {
        let hasActivePreparation = enhancedCachePreparationTask != nil ||
            enhancedPresentationMonitorTask != nil ||
            isPreparingEnhancedCache
        guard hasActivePreparation else { return }
        let shouldRestore = restorePreviousPlayback
        let wasPlaying = enhancementTransactionWasPlaying
        let previousConfiguration = enhancementTransactionPreviousConfiguration
        enhancedCachePreparationGeneration &+= 1
        enhancedCachePreparationTask?.cancel()
        enhancedCachePreparationTask = nil
        enhancedPresentationMonitorTask?.cancel()
        enhancedPresentationMonitorTask = nil
        enhancedCachePreparationState = .idle
        if shouldRestore {
            forceFullCachePreparation = false
        }
        guard shouldRestore else { return }

        appliedPipelineConfiguration = previousConfiguration
        nativeFallbackActive = false
        player?.pause()
        stopPlaybackLoopOnly()
        if wasPlaying {
            isPlaying = true
            isPaused = false
            if previousConfiguration == .disabled {
                setNativeVideoEnabled(true)
                transitionPlayback(to: .playingNative)
                player?.play()
                player?.rate = Float(playbackSpeed)
            } else {
                transitionPlayback(to: .prerollingEnhanced)
                startPlaybackLoop()
            }
        } else {
            isPlaying = false
            isPaused = true
            transitionPlayback(to: enhancementTransactionPreviousPhase)
        }
    }

    func applyPipelineEnhancements() {
        validateEnhancementSelections()
        #if os(macOS)
        guard hasUnappliedPipelineChanges else { return }
        let candidate = draftPipelineConfiguration
        let previousConfiguration = appliedPipelineConfiguration
        guard let url = videoURL, videoWidth > 0, videoHeight > 0 else {
            appliedPipelineConfiguration = candidate
            persistedPipelineConfiguration = candidate
            restartAppliedEnhancements()
            return
        }

        let wasPlaying = isPlaying && !isPaused
        enhancementTransactionWasPlaying = wasPlaying
        enhancementTransactionPreviousPhase = playbackPhase
        enhancementTransactionPreviousConfiguration = previousConfiguration
        livePresentationGateValidated = false
        let forceFullCache = forceFullCachePreparation
        forceFullCachePreparation = false
        player?.pause()
        isPaused = true
        stopPlaybackLoopOnly()
        enhancedCachePreparationState = .benchmarking
        transitionPlayback(to: .benchmarking)

        cancelEnhancedCachePreparation(restorePreviousPlayback: false)
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
                let benchmarkPlan = SparseCachePlanner.makePlan(
                    benchmark: benchmark,
                    configuration: candidate,
                    totalGroupCount: groupCount
                )
                let plan = forceFullCache
                    ? SparseCachePlan(
                        mode: .full,
                        coveragePercent: 100,
                        coverageBitmap: Array(repeating: true, count: groupCount)
                    )
                    : benchmarkPlan
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
                    self.nativeFallbackActive = false
                    self.persistedPipelineConfiguration = candidate
                    self.liveFallbackPreviousConfiguration = previousConfiguration
                    self.liveFallbackCandidateConfiguration = candidate
                    self.liveFallbackWasPlaying = wasPlaying
                    self.resumeAfterApplyingEnhancements(wasPlaying: wasPlaying)
                    if wasPlaying {
                        self.startEnhancedPresentationGateMonitor(
                            url: url,
                            candidate: candidate,
                            preparationGeneration: preparationGeneration
                        )
                    }
                    return
                }

                self.enhancedCachePreparationState = .preparing(progress: 0, bytesWritten: 0)
                self.transitionPlayback(to: .preparingCache)
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
                self.persistedPipelineConfiguration = candidate
                self.enhancedCachePreparationState = .ready
                self.nativeFallbackActive = false
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
                    self.appliedPipelineConfiguration = previousConfiguration
                    self.nativeFallbackActive = false
                    if wasPlaying {
                        self.isPlaying = true
                        self.isPaused = false
                        if previousConfiguration == .disabled {
                            self.setNativeVideoEnabled(true)
                            self.transitionPlayback(to: .playingNative)
                            self.player?.play()
                            self.player?.rate = Float(self.playbackSpeed)
                        } else {
                            self.transitionPlayback(to: .prerollingEnhanced)
                            self.startPlaybackLoop()
                        }
                    } else {
                        self.isPlaying = false
                        self.isPaused = true
                        self.transitionPlayback(to: self.enhancementTransactionPreviousPhase)
                    }
                }
            } catch {
                if self.enhancedCachePreparationGeneration == preparationGeneration {
                    NSLog("CACHE: preparation failed: %@", error.localizedDescription)
                    self.enhancedCachePreparationState = .failed(error.localizedDescription)
                    self.srInitializationError = error.localizedDescription
                    self.setNativeVideoEnabled(true)
                    self.appliedPipelineConfiguration = previousConfiguration
                    self.nativeFallbackActive = true
                    self.isPlaying = false
                    self.isPaused = true
                    self.reportPlaybackIssue(
                        stage: .preparation,
                        message: "Enhancement preparation failed: \(error.localizedDescription)"
                    )
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
            #if os(macOS)
            transitionPlayback(to: .prerollingEnhanced)
            enhancedCachePreparationState = .prerolling
            #endif
            startPlaybackLoop()
        } else {
            isPlaying = false
            isPaused = true
            #if os(macOS)
            transitionPlayback(to: isPipelineActive ? .paused : .readyPaused)
            #endif
        }
    }

    #if os(macOS)
    func startEnhancedPresentationGateMonitor(
        url: URL,
        candidate: AppliedPipelineConfiguration,
        preparationGeneration: UInt64
    ) {
        enhancedPresentationMonitorTask?.cancel()
        enhancedPresentationMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startupDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while !Task.isCancelled,
                  self.enhancedCachePreparationGeneration == preparationGeneration,
                  !self.pipelinePresentationReady,
                  DispatchTime.now().uptimeNanoseconds < startupDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if !self.pipelinePresentationReady {
                self.enhancedPresentationMonitorTask = nil
                self.fallbackToFullCacheAfterPresentationFailure()
                return
            }
            guard !Task.isCancelled,
                  self.videoURL == url,
                  self.draftPipelineConfiguration == candidate,
                  self.isPlaying,
                  !self.isPaused else {
                self.enhancedPresentationMonitorTask = nil
                return
            }

            let monitoringStart = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard self.videoURL == url,
                      self.draftPipelineConfiguration == candidate,
                      self.isPlaying,
                      !self.isPaused else {
                    self.enhancedPresentationMonitorTask = nil
                    return
                }
                let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds &- monitoringStart
                guard elapsedNanoseconds >= 5_000_000_000 else { continue }
                let elapsed = Double(elapsedNanoseconds) / 1_000_000_000

                let requestedRate = self.sourceFrameRate *
                    (candidate.frameInterpolationLevel > 0 ? Double(candidate.frameInterpolationLevel) : 1)
                let physicalRate = Double(self.renderer.schedulingSnapshot().screenMaximumFramesPerSecond)
                // `fps` counts submitted frames. The acceptance gate must use
                // drawable presentation handlers instead, because a drawable
                // with presentedTime == 0 was dropped before reaching the
                // screen.
                let rendererPerformance = self.renderer.consumePerformanceSnapshot()
                let measuredRate = Double(rendererPerformance.presentedFrames) / elapsed
                self.actualPresentedFrameRate = measuredRate
                self.actualPresentedRateSamples.append(measuredRate)
                if self.actualPresentedRateSamples.count > 5 {
                    self.actualPresentedRateSamples.removeFirst(self.actualPresentedRateSamples.count - 5)
                }
                self.actualPresented1PercentLow = self.actualPresentedRateSamples.min() ?? measuredRate
                let passes = EnhancedPresentationGate.passes(
                    measuredFramesPerSecond: measuredRate,
                    physicalFramesPerSecond: physicalRate,
                    requestedFramesPerSecond: requestedRate,
                    renderedTimelineRatio: self.renderedTimelineRatio
                )
                NSLog(
                    "RENDER: live presentation gate measured=%.2f physical=%.2f requested=%.2f timelineRatio=%.4f passes=%@",
                    measuredRate,
                    physicalRate,
                    requestedRate,
                    self.renderedTimelineRatio,
                    passes.description
                )
                self.enhancedPresentationMonitorTask = nil
                if passes {
                    self.livePresentationGateValidated = true
                    self.enhancedCachePreparationState = .ready
                    self.transitionPlayback(to: .playingEnhanced)
                } else {
                    self.fallbackToFullCacheAfterPresentationFailure()
                }
                return
            }
        }
    }

    private func fallbackToFullCacheAfterPresentationFailure() {
        guard videoURL != nil,
              liveFallbackWasPlaying,
              liveFallbackCandidateConfiguration == draftPipelineConfiguration else { return }
        let candidate = liveFallbackCandidateConfiguration
        appliedPipelineConfiguration = liveFallbackPreviousConfiguration
        livePresentationGateValidated = false
        isPlaying = true
        isPaused = false
        forceFullCachePreparation = true
        stopPlaybackLoopOnly()
        appliedPipelineConfiguration = liveFallbackPreviousConfiguration
        // Keep the candidate in the draft fields and reuse the normal
        // transactional preparation path with a forced full-cache plan.
        guard draftPipelineConfiguration == candidate else { return }
        applyPipelineEnhancements()
    }
    #endif
}
