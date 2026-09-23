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
        let previousSharpness = enhancementTransactionPreviousSharpness
        let previousHDRStrength = enhancementTransactionPreviousHDRStrength
        let previousHDRColorfulness = enhancementTransactionPreviousHDRColorfulness
        enhancedCachePreparationGeneration &+= 1
        enhancedCachePreparationTask?.cancel()
        enhancedCachePreparationTask = nil
        enhancedPresentationMonitorGeneration &+= 1
        enhancedPresentationMonitorTask?.cancel()
        enhancedPresentationMonitorTask = nil
        enhancedCachePreparationState = .idle
        if shouldRestore {
            forceFullCachePreparation = false
        }
        guard shouldRestore else { return }

        appliedPipelineConfiguration = previousConfiguration
        appliedSharpness = previousSharpness
        appliedHDRStrength = previousHDRStrength
        appliedHDRColorfulness = previousHDRColorfulness
        applyActiveRendererSettings()
        nativeFallbackActive = false
        player?.pause()
        stopPlaybackLoopOnly()
        let previousPipelineWasActive = previousConfiguration.superResolutionLevel > 0 ||
            previousConfiguration.qualitySuperResolutionScaleFactor > 0 ||
            previousConfiguration.frameInterpolationLevel > 0 ||
            previousConfiguration.denoiseStrength > 0 ||
            previousConfiguration.motionBlurStrength > 0 ||
            previousHDRStrength > 0
        if enhancementTransactionReachedEnd {
            isPlaying = false
            isPaused = true
            transitionPlayback(to: .ended)
            enhancementTransactionReachedEnd = false
        } else if wasPlaying {
            isPlaying = true
            isPaused = false
            if !previousPipelineWasActive {
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
            transitionPlayback(to: previousPipelineWasActive ? .paused : .readyPaused)
        }
    }

    func cancelEnhancedPlaybackPreroll() {
        guard enhancedCachePreparationState == .prerolling else { return }
        player?.pause()
        isPlaying = false
        isPaused = true
        stopPlaybackLoopOnly()
        enhancedCachePreparationState = .ready
        transitionPlayback(to: isPipelineActive ? .paused : .readyPaused)
        saveProgress()
    }

    func applyPipelineEnhancements() {
        applyPipelineEnhancements(fullCacheConfiguration: nil, rendererSettings: nil)
    }

    func retryEnhancedPreparation(configuration: AppliedPipelineConfiguration) {
        let benchmark: EnhancedPipelineBenchmark?
        if liveFallbackBenchmarkURL == videoURL,
           liveFallbackBenchmarkConfiguration == configuration {
            benchmark = liveFallbackBenchmark
        } else {
            benchmark = nil
        }
        applyPipelineEnhancements(
            fullCacheConfiguration: configuration,
            rendererSettings: (
                sharpness: appliedSharpness,
                hdrStrength: appliedHDRStrength,
                hdrColorfulness: appliedHDRColorfulness
            ),
            benchmarkOverride: benchmark
        )
    }

    private func applyPipelineEnhancements(
        fullCacheConfiguration: AppliedPipelineConfiguration?,
        rendererSettings: (sharpness: Double, hdrStrength: Double, hdrColorfulness: Double)?,
        benchmarkOverride: EnhancedPipelineBenchmark? = nil
    ) {
        validateEnhancementSelections()
        #if os(macOS)
        guard fullCacheConfiguration != nil || hasUnappliedPipelineChanges else { return }
        let candidate = fullCacheConfiguration ?? draftPipelineConfiguration
        let previousConfiguration = appliedPipelineConfiguration
        let candidateSharpness = rendererSettings?.sharpness ?? sharpness
        let candidateHDRStrength = rendererSettings?.hdrStrength ?? hdrStrength
        let candidateHDRColorfulness = rendererSettings?.hdrColorfulness ?? hdrColorfulness
        let previousSharpness = appliedSharpness
        let previousHDRStrength = appliedHDRStrength
        let previousHDRColorfulness = appliedHDRColorfulness
        let wasPipelineActive = isPipelineActive
        let forceFullCache = fullCacheConfiguration != nil || forceFullCachePreparation
        let preservesDraft = fullCacheConfiguration != nil
        let candidateWouldBePipelineActive = candidate.superResolutionLevel > 0 ||
            candidate.qualitySuperResolutionScaleFactor > 0 ||
            candidate.frameInterpolationLevel > 0 ||
            candidate.denoiseStrength > 0 ||
            candidate.motionBlurStrength > 0 ||
            candidateHDRStrength > 0
        guard let url = videoURL, videoWidth > 0, videoHeight > 0 else {
            appliedPipelineConfiguration = candidate
            appliedSharpness = candidateSharpness
            appliedHDRStrength = candidateHDRStrength
            appliedHDRColorfulness = candidateHDRColorfulness
            persistedPipelineConfiguration = candidate
            persistedSharpness = candidateSharpness
            persistedHDRStrength = candidateHDRStrength
            persistedHDRColorfulness = candidateHDRColorfulness
            applyActiveRendererSettings()
            restartAppliedEnhancements()
            return
        }

        let wasPlaying = isPlaying && !isPaused
        enhancementTransactionWasPlaying = wasPlaying
        enhancementTransactionReachedEnd = false
        enhancementTransactionPreviousPhase = playbackPhase
        enhancementTransactionPreviousConfiguration = previousConfiguration
        enhancementTransactionPreviousSharpness = previousSharpness
        enhancementTransactionPreviousHDRStrength = previousHDRStrength
        enhancementTransactionPreviousHDRColorfulness = previousHDRColorfulness
        livePresentationGateValidated = false

        // Renderer-only edits do not require another frame-cache benchmark.
        // Commit them transactionally, then rebuild the transport only when
        // the HDR edit changes whether the decoded-frame pipeline is needed.
        if candidate == previousConfiguration && !forceFullCache {
            appliedSharpness = candidateSharpness
            appliedHDRStrength = candidateHDRStrength
            appliedHDRColorfulness = candidateHDRColorfulness
            persistedSharpness = candidateSharpness
            persistedHDRStrength = candidateHDRStrength
            persistedHDRColorfulness = candidateHDRColorfulness
            applyActiveRendererSettings()
            nativeFallbackActive = false
            if candidateWouldBePipelineActive != wasPipelineActive {
                player?.pause()
                stopPlaybackLoopOnly()
            }
            if wasPlaying,
               candidateWouldBePipelineActive != wasPipelineActive {
                isPlaying = true
                isPaused = false
                if candidateWouldBePipelineActive {
                    transitionPlayback(to: .prerollingEnhanced)
                    startPlaybackLoop()
                } else {
                    setNativeVideoEnabled(true)
                    transitionPlayback(to: .playingNative)
                    player?.play()
                    player?.rate = Float(playbackSpeed)
                }
            } else if !wasPlaying {
                transitionPlayback(to: candidateWouldBePipelineActive ? .paused : .readyPaused)
            }
            if wasPlaying, candidateWouldBePipelineActive {
                liveFallbackPreviousConfiguration = previousConfiguration
                liveFallbackCandidateConfiguration = candidate
                liveFallbackWasPlaying = true
                if enhancedPresentationMonitorTask == nil, let url = videoURL {
                    startEnhancedPresentationGateMonitor(
                        url: url,
                        candidate: candidate,
                        preparationGeneration: enhancedCachePreparationGeneration
                    )
                }
            }
            saveVideoSettings()
            return
        }

        if !candidateWouldBePipelineActive {
            forceFullCachePreparation = false
            preparedEnhancedFrameCacheKey = nil
            preparedEnhancedFrameCacheMode = nil
            enhancedCacheCoveragePercent = 0
            stopPlaybackLoopOnly()
            appliedPipelineConfiguration = candidate
            appliedSharpness = candidateSharpness
            appliedHDRStrength = candidateHDRStrength
            appliedHDRColorfulness = candidateHDRColorfulness
            persistedPipelineConfiguration = candidate
            persistedSharpness = candidateSharpness
            persistedHDRStrength = candidateHDRStrength
            persistedHDRColorfulness = candidateHDRColorfulness
            applyActiveRendererSettings()
            nativeFallbackActive = false
            setNativeVideoEnabled(true)
            enhancedCachePreparationState = .ready
            if wasPlaying {
                isPlaying = true
                isPaused = false
                transitionPlayback(to: .playingNative)
                player?.play()
                player?.rate = Float(playbackSpeed)
            } else {
                isPlaying = false
                isPaused = true
                transitionPlayback(to: .readyPaused)
            }
            saveVideoSettings()
            return
        }

        forceFullCachePreparation = false
        player?.pause()
        stopPlaybackLoopOnly()
        setNativeVideoEnabled(true)
        nativeFallbackActive = true
        if wasPlaying {
            player?.play()
            player?.rate = Float(playbackSpeed)
            isPlaying = true
            isPaused = false
        } else {
            isPlaying = false
            isPaused = true
        }
        enhancedCachePreparationState = .benchmarking
        transitionPlayback(to: .benchmarking)

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
                  preservesDraft || (
                    self.draftPipelineConfiguration == candidate &&
                    abs(self.sharpness - candidateSharpness) <= 0.0001 &&
                    abs(self.hdrStrength - candidateHDRStrength) <= 0.0001 &&
                    abs(self.hdrColorfulness - candidateHDRColorfulness) <= 0.0001
                  ) else { return }

            let sourceRate = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30
            let preparer = EnhancedFrameCachePreparer(diskCache: self.enhancedFrameDiskCache)
            do {
                let benchmark: EnhancedPipelineBenchmark
                if let benchmarkOverride {
                    benchmark = benchmarkOverride
                    NSLog("CACHE: reusing processing benchmark for fallback cache preparation")
                } else {
                    benchmark = try await preparer.benchmark(
                        url: url,
                        width: self.videoWidth,
                        height: self.videoHeight,
                        sourceFramesPerSecond: sourceRate,
                        configuration: candidate,
                        qualityPrioritization: self.qualityPrioritization,
                        preferSequentialSRFI: self.useSequentialSRFIFallback
                    )
                }
                guard self.enhancedCachePreparationGeneration == preparationGeneration,
                      self.videoURL == url,
                      preservesDraft || (
                        self.draftPipelineConfiguration == candidate &&
                        abs(self.sharpness - candidateSharpness) <= 0.0001 &&
                        abs(self.hdrStrength - candidateHDRStrength) <= 0.0001 &&
                        abs(self.hdrColorfulness - candidateHDRColorfulness) <= 0.0001
                      ) else { return }

                self.liveFallbackBenchmark = benchmark
                self.liveFallbackBenchmarkURL = url
                self.liveFallbackBenchmarkConfiguration = candidate

                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let groupCount = max(1, Int((CMTimeGetSeconds(duration) * sourceRate).rounded(.up)) + 8)
                #if os(macOS)
                let physicalDisplayRate = self.renderer.schedulingSnapshot().screenMaximumFramesPerSecond
                let displayTargetFrameRate = min(120, max(1, physicalDisplayRate > 0 ? physicalDisplayRate : 120))
                #else
                let displayTargetFrameRate = 60
                #endif
                let benchmarkPlan = SparseCachePlanner.makePlan(
                    benchmark: benchmark,
                    configuration: candidate,
                    totalGroupCount: groupCount
                )
                #if os(macOS)
                // All non-live macOS preparation uses the bounded encoded
                // chunk format; full coverage avoids mixing encoded segments
                // with real-time processing during seeks.
                let plan = benchmarkPlan.mode == .realTime && !forceFullCache
                    ? benchmarkPlan
                    : SparseCachePlan(
                        mode: .full,
                        coveragePercent: 100,
                        coverageBitmap: Array(repeating: true, count: groupCount)
                    )
                #else
                let plan = forceFullCache
                    ? SparseCachePlan(
                        mode: .full,
                        coveragePercent: 100,
                        coverageBitmap: Array(repeating: true, count: groupCount)
                    )
                    : benchmarkPlan
                #endif
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
                    self.appliedSharpness = candidateSharpness
                    self.appliedHDRStrength = candidateHDRStrength
                    self.appliedHDRColorfulness = candidateHDRColorfulness
                    self.applyActiveRendererSettings()
                    self.enhancedCachePreparationState = .ready
                    self.nativeFallbackActive = false
                    self.persistedPipelineConfiguration = candidate
                    self.persistedSharpness = candidateSharpness
                    self.persistedHDRStrength = candidateHDRStrength
                    self.persistedHDRColorfulness = candidateHDRColorfulness
                    self.liveFallbackPreviousConfiguration = previousConfiguration
                    self.liveFallbackCandidateConfiguration = candidate
                    let shouldResume = self.enhancementTransactionWasPlaying
                    self.liveFallbackWasPlaying = shouldResume
                    self.nativeFallbackActive = false
                    if self.enhancementTransactionReachedEnd {
                        self.isPlaying = false
                        self.isPaused = true
                        self.transitionPlayback(to: .ended)
                        self.enhancementTransactionReachedEnd = false
                    } else {
                        self.resumeAfterApplyingEnhancements(wasPlaying: shouldResume)
                    }
                    if shouldResume {
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
                let requestedOutputFrameRate = sourceRate * Double(max(1, candidate.frameInterpolationLevel))
                let selectedOutputFrameRate = min(Double(displayTargetFrameRate), requestedOutputFrameRate)
                let scaleFactor = candidate.qualitySuperResolutionScaleFactor > 0
                    ? Double(candidate.qualitySuperResolutionScaleFactor)
                    : max(1, Double(candidate.superResolutionLevel))
                let estimatedOutputWidth = max(1, Int((Double(self.videoWidth) * scaleFactor).rounded(.up)))
                let estimatedOutputHeight = max(1, Int((Double(self.videoHeight) * scaleFactor).rounded(.up)))
                let durationSeconds = max(0, CMTimeGetSeconds(duration))
                #if os(macOS)
                let estimatedRequiredBytes = EnhancedFrameCacheSizing.estimatedBytes(
                    width: estimatedOutputWidth,
                    height: estimatedOutputHeight,
                    frameRate: selectedOutputFrameRate,
                    durationSeconds: durationSeconds
                )
                #else
                let estimatedBytesPerGroup = max(1, benchmark.averageOutputBytesPerGroup)
                let groupMultiplier = plan.mode == .sparse
                    ? Double(plan.cachedGroupCount) / Double(max(1, plan.coverageBitmap.count))
                    : 1
                let estimatedRequiredBytes = Int64(
                    Double(estimatedBytesPerGroup * Int64(groupCount)) * 1.2 * groupMultiplier
                )
                #endif
                let result = try await preparer.prepareCache(
                    url: url,
                    width: self.videoWidth,
                    height: self.videoHeight,
                    sourceFramesPerSecond: sourceRate,
                    displayTargetFrameRate: displayTargetFrameRate,
                    estimatedGroupCount: groupCount,
                    plan: plan,
                    configuration: candidate,
                    qualityPrioritization: self.qualityPrioritization,
                    preferSequentialSRFI: self.useSequentialSRFIFallback,
                    diskBudgetBytes: self.enhancedFrameDiskCacheBudget,
                    estimatedRequiredBytes: estimatedRequiredBytes,
                    benchmark: benchmark
                ) { [weak self] progress, bytesWritten in
                    self?.enhancedCachePreparationState = .preparing(
                        progress: progress,
                        bytesWritten: bytesWritten
                    )
                }
                guard self.enhancedCachePreparationGeneration == preparationGeneration,
                      self.videoURL == url,
                      preservesDraft || (
                        self.draftPipelineConfiguration == candidate &&
                        abs(self.sharpness - candidateSharpness) <= 0.0001 &&
                        abs(self.hdrStrength - candidateHDRStrength) <= 0.0001 &&
                        abs(self.hdrColorfulness - candidateHDRColorfulness) <= 0.0001
                      ) else { return }
                self.preparedEnhancedFrameCacheKey = result.key
                self.preparedEnhancedFrameCacheMode = result.mode
                self.enhancedCacheCoveragePercent = result.status.coverageBitmap.isEmpty
                    ? 0
                    : Int((Double(result.status.coverageBitmap.filter { $0 }.count) / Double(result.status.coverageBitmap.count) * 100).rounded())
                self.appliedPipelineConfiguration = candidate
                self.appliedSharpness = candidateSharpness
                self.appliedHDRStrength = candidateHDRStrength
                self.appliedHDRColorfulness = candidateHDRColorfulness
                self.applyActiveRendererSettings()
                self.persistedPipelineConfiguration = candidate
                self.persistedSharpness = candidateSharpness
                self.persistedHDRStrength = candidateHDRStrength
                self.persistedHDRColorfulness = candidateHDRColorfulness
                self.enhancedCachePreparationState = .ready
                self.nativeFallbackActive = false
                self.liveFallbackPreviousConfiguration = previousConfiguration
                self.liveFallbackCandidateConfiguration = candidate
                let shouldResume = self.enhancementTransactionWasPlaying
                self.liveFallbackWasPlaying = shouldResume
                self.livePresentationGateValidated = false
                NSLog(
                    "CACHE: prepared mode=%@ groups=%d bytes=%lld",
                    result.mode.rawValue,
                    result.totalGroupCount,
                    result.status.byteCount
                )
                if self.enhancementTransactionReachedEnd {
                    self.isPlaying = false
                    self.isPaused = true
                    self.transitionPlayback(to: .ended)
                    self.enhancementTransactionReachedEnd = false
                } else {
                    self.resumeAfterApplyingEnhancements(wasPlaying: shouldResume)
                }
                if shouldResume {
                    self.startEnhancedPresentationGateMonitor(
                        url: url,
                        candidate: candidate,
                        preparationGeneration: preparationGeneration
                    )
                }
            } catch is CancellationError {
                if self.enhancedCachePreparationGeneration == preparationGeneration {
                    self.enhancedCachePreparationState = .idle
                    self.appliedPipelineConfiguration = previousConfiguration
                    self.appliedSharpness = previousSharpness
                    self.appliedHDRStrength = previousHDRStrength
                    self.appliedHDRColorfulness = previousHDRColorfulness
                    self.applyActiveRendererSettings()
                    self.nativeFallbackActive = false
                    let shouldResume = self.enhancementTransactionWasPlaying
                    if self.enhancementTransactionReachedEnd {
                        self.isPlaying = false
                        self.isPaused = true
                        self.transitionPlayback(to: .ended)
                        self.enhancementTransactionReachedEnd = false
                    } else if shouldResume {
                        self.isPlaying = true
                        self.isPaused = false
                        if !wasPipelineActive {
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
                        let previousPipelineWasActive = previousConfiguration.superResolutionLevel > 0 ||
                            previousConfiguration.qualitySuperResolutionScaleFactor > 0 ||
                            previousConfiguration.frameInterpolationLevel > 0 ||
                            previousConfiguration.denoiseStrength > 0 ||
                            previousConfiguration.motionBlurStrength > 0 ||
                            previousHDRStrength > 0
                        self.transitionPlayback(to: previousPipelineWasActive ? .paused : .readyPaused)
                    }
                }
            } catch {
                if self.enhancedCachePreparationGeneration == preparationGeneration {
                    NSLog("CACHE: preparation failed: %@", error.localizedDescription)
                    self.enhancedCachePreparationState = .failed(error.localizedDescription)
                    self.srInitializationError = error.localizedDescription
                    self.player?.pause()
                    self.enhancedAudioPlayer?.pause()
                    self.setNativeVideoEnabled(true)
                    self.appliedPipelineConfiguration = previousConfiguration
                    self.appliedSharpness = previousSharpness
                    self.appliedHDRStrength = previousHDRStrength
                    self.appliedHDRColorfulness = previousHDRColorfulness
                    self.applyActiveRendererSettings()
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
        enhancedPresentationMonitorGeneration &+= 1
        let monitorGeneration = enhancedPresentationMonitorGeneration
        enhancedPresentationMonitorTask?.cancel()
        enhancedPresentationMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startupDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while !Task.isCancelled,
                  self.enhancedPresentationMonitorGeneration == monitorGeneration,
                  self.enhancedCachePreparationGeneration == preparationGeneration,
                  !self.pipelinePresentationReady,
                  DispatchTime.now().uptimeNanoseconds < startupDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled,
                  self.enhancedPresentationMonitorGeneration == monitorGeneration,
                  self.enhancedCachePreparationGeneration == preparationGeneration,
                  self.videoURL == url,
                  self.appliedPipelineConfiguration == candidate,
                  self.isPlaying,
                  !self.isPaused else { return }
            if !self.pipelinePresentationReady {
                self.enhancedPresentationMonitorTask = nil
                self.handleEnhancedPresentationFailure(
                    url: url,
                    candidate: candidate,
                    measuredRate: 0,
                    requestedRate: self.sourceFrameRate *
                        (candidate.frameInterpolationLevel > 0 ? Double(candidate.frameInterpolationLevel) : 1) *
                        self.playbackSpeed,
                    reason: "No enhanced frame reached the display within 2 seconds."
                )
                return
            }
            var presentationWindowStart = DispatchTime.now()
            var presentationFrameBaseline = self.renderer.totalPresentedFrameCount()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled,
                      self.enhancedPresentationMonitorGeneration == monitorGeneration,
                      self.enhancedCachePreparationGeneration == preparationGeneration,
                      self.videoURL == url,
                      self.appliedPipelineConfiguration == candidate,
                      self.isPlaying,
                      !self.isPaused else {
                    if self.enhancedPresentationMonitorGeneration == monitorGeneration {
                        self.enhancedPresentationMonitorTask = nil
                    }
                    return
                }
                let now = DispatchTime.now()
                let elapsed = self.elapsedUptimeSeconds(since: presentationWindowStart, until: now)
                guard elapsed >= 5 else { continue }

                let requestedRate = self.sourceFrameRate *
                    (candidate.frameInterpolationLevel > 0 ? Double(candidate.frameInterpolationLevel) : 1) *
                    self.playbackSpeed
                let physicalRate = Double(self.renderer.schedulingSnapshot().screenMaximumFramesPerSecond)
                // `fps` counts submitted frames. The acceptance gate must use
                // drawable presentation handlers instead, because a drawable
                // with presentedTime == 0 was dropped before reaching the
                // screen. Use a lifetime count so other metrics readers cannot
                // consume the gate's frames first.
                let totalPresentedFrames = self.renderer.totalPresentedFrameCount()
                let presentedFrames = max(0, totalPresentedFrames - presentationFrameBaseline)
                let measuredRate = Double(presentedFrames) / elapsed
                self.actualPresentedFrameRate = measuredRate
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
                if passes {
                    self.livePresentationGateValidated = true
                    self.enhancedCachePreparationState = .ready
                    if self.playbackPhase == .monitoringEnhanced ||
                        self.playbackPhase == .prerollingEnhanced {
                        self.transitionPlayback(to: .playingEnhanced)
                    }
                } else {
                    self.enhancedPresentationMonitorTask = nil
                    self.handleEnhancedPresentationFailure(
                        url: url,
                        candidate: candidate,
                        measuredRate: measuredRate,
                        requestedRate: requestedRate,
                        reason: "Enhanced playback did not meet its measured presentation target."
                    )
                    return
                }
                presentationFrameBaseline = totalPresentedFrames
                presentationWindowStart = now
            }
        }
    }

    private func handleEnhancedPresentationFailure(
        url: URL,
        candidate: AppliedPipelineConfiguration,
        measuredRate: Double,
        requestedRate: Double,
        reason: String
    ) {
        guard videoURL == url,
              isPlaying,
              !isPaused,
              candidate == appliedPipelineConfiguration else { return }

        guard preparedEnhancedFrameCacheMode == .full else {
            fallbackToFullCacheAfterPresentationFailure()
            return
        }

        let physicalRate = Double(renderer.schedulingSnapshot().screenMaximumFramesPerSecond)
        let targetRate = physicalRate > 0 ? min(requestedRate, physicalRate) : requestedRate
        player?.pause()
        enhancedAudioPlayer?.pause()
        isPlaying = false
        isPaused = true
        liveFallbackWasPlaying = false
        stopPlaybackLoopOnly()
        isPlaying = false
        isPaused = true
        actualPresentedFrameRate = measuredRate
        actualPresented1PercentLow = actualPresentedRateSamples.min() ?? measuredRate
        reportPlaybackIssue(
            stage: .pipeline,
            message: "Enhanced playback was paused because the full-cache presentation path also missed its target.\n\n" +
                "\(reason) Presented \(String(format: "%.1f", measuredRate)) Hz; target \(String(format: "%.1f", targetRate)) Hz. " +
                "The full cache is already active, so preparing more cached frames cannot fix this. Retry Enhanced or continue with native playback."
        )
    }

    private func fallbackToFullCacheAfterPresentationFailure() {
        guard videoURL != nil,
              liveFallbackWasPlaying,
              liveFallbackCandidateConfiguration == appliedPipelineConfiguration else { return }
        let candidate = liveFallbackCandidateConfiguration
        let rendererSettings = (
            sharpness: appliedSharpness,
            hdrStrength: appliedHDRStrength,
            hdrColorfulness: appliedHDRColorfulness
        )
        let benchmark: EnhancedPipelineBenchmark?
        if liveFallbackBenchmarkURL == videoURL,
           liveFallbackBenchmarkConfiguration == candidate {
            benchmark = liveFallbackBenchmark
        } else {
            benchmark = nil
        }
        appliedPipelineConfiguration = liveFallbackPreviousConfiguration
        appliedSharpness = enhancementTransactionPreviousSharpness
        appliedHDRStrength = enhancementTransactionPreviousHDRStrength
        appliedHDRColorfulness = enhancementTransactionPreviousHDRColorfulness
        applyActiveRendererSettings()
        livePresentationGateValidated = false
        isPlaying = true
        isPaused = false
        forceFullCachePreparation = true
        stopPlaybackLoopOnly()
        appliedPipelineConfiguration = liveFallbackPreviousConfiguration
        // Preserve any newer selection as a draft while preparing a full
        // cache for the configuration that actually failed the live gate.
        applyPipelineEnhancements(
            fullCacheConfiguration: candidate,
            rendererSettings: rendererSettings,
            benchmarkOverride: benchmark
        )
    }
    #endif
}
