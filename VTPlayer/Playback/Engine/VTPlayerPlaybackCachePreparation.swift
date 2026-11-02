import AVFoundation
import CoreMedia
import Foundation
#if os(macOS)
import AppKit
#endif

extension VTPlayerViewModel {
    #if os(macOS)
    func setProcessingEnhancementsEnabled(_ enabled: Bool) {
        guard processingEnhancementsEnabled != enabled else { return }
        enhancementApplyTask?.cancel()
        enhancementApplyTask = nil
        cancelEnhancedCachePreparation(restorePreviousPlayback: false)
        processingEnhancementsEnabled = enabled
        nativeFallbackActive = false
        if enabled {
            applyPipelineEnhancements()
        } else {
            stopPlaybackLoopOnly()
            appliedPipelineConfiguration = .disabled
            preparedEnhancedFrameCacheKey = nil
            preparedEnhancedFrameCacheMode = nil
            enhancedCacheCoveragePercent = 0
            restartAppliedEnhancements()
        }
        saveVideoSettings()
    }

    func cancelPreparationAndDisableEnhancements() {
        setProcessingEnhancementsEnabled(false)
    }

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
            previousHDRStrength > 0 || previousSharpness > 0
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

    #else
    func cancelEnhancedCachePreparation(restorePreviousPlayback: Bool = true) {
        enhancedCachePreparationGeneration &+= 1
        enhancedCachePreparationTask?.cancel()
        enhancedCachePreparationTask = nil
        enhancedCachePreparationState = .idle
    }
    #endif

    func applyPipelineEnhancements() {
        applyPipelineEnhancements(fullCacheConfiguration: nil, rendererSettings: nil)
    }

    #if os(macOS)
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

    #endif

    func applyPipelineEnhancements(
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
            candidateHDRStrength > 0 || candidateSharpness > 0
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
            } else if !wasPlaying,
                      candidateWouldBePipelineActive,
                      candidateWouldBePipelineActive != wasPipelineActive {
                prepareEnhancedPlaybackWhilePaused()
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
                #if os(macOS)
            transitionPlayback(to: .readyPaused)
            #endif
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
                  preservesDraft || self.draftPipelineConfiguration == candidate else { return }

            let sourceRate = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30
            let preparer = EnhancedFrameCachePreparer(diskCache: self.enhancedFrameDiskCache)
            do {
                #if os(macOS)
                let screenRate = self.renderer.schedulingSnapshot().screenMaximumFramesPerSecond
                let cacheDisplayRate = min(120, max(1, screenRate > 0 ? screenRate : 120))
                if let cached = try await preparer.reusableFullCache(
                    url: url, sourceFramesPerSecond: sourceRate, displayTargetFrameRate: cacheDisplayRate,
                    configuration: candidate, duration: self.duration
                ) {
                    guard !Task.isCancelled,
                          self.enhancedCachePreparationGeneration == preparationGeneration,
                          self.videoURL == url,
                          preservesDraft || self.draftPipelineConfiguration == candidate else { return }
                    self.preparedEnhancedFrameCacheKey = cached.key
                    self.preparedEnhancedFrameCacheMode = .full
                    self.enhancedCacheCoveragePercent = 100
                    self.appliedPipelineConfiguration = candidate
                    self.appliedSharpness = self.sharpness
                    self.appliedHDRStrength = self.hdrStrength
                    self.appliedHDRColorfulness = self.hdrColorfulness
                    self.applyActiveRendererSettings()
                    self.persistedPipelineConfiguration = candidate
                    self.persistedSharpness = self.sharpness
                    self.persistedHDRStrength = self.hdrStrength
                    self.persistedHDRColorfulness = self.hdrColorfulness
                    self.enhancedCachePreparationState = .ready
                    self.nativeFallbackActive = false
                    self.liveFallbackPreviousConfiguration = previousConfiguration
                    self.liveFallbackCandidateConfiguration = candidate
                    let shouldResume = self.enhancementTransactionWasPlaying
                    self.liveFallbackWasPlaying = shouldResume
                    self.livePresentationGateValidated = false
                    if self.enhancementTransactionReachedEnd {
                        self.isPlaying = false
                        self.isPaused = true
                        self.transitionPlayback(to: .ended)
                        self.enhancementTransactionReachedEnd = false
                    } else if shouldResume {
                        self.resumeAfterApplyingEnhancements(wasPlaying: true)
                    } else {
                        self.prepareEnhancedPlaybackWhilePaused()
                    }
                    if shouldResume {
                        self.startEnhancedPresentationGateMonitor(url: url, candidate: candidate,
                                                                  preparationGeneration: preparationGeneration)
                    }
                    return
                }
                #endif
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
                      preservesDraft || self.draftPipelineConfiguration == candidate else { return }

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
                    self.appliedSharpness = self.sharpness
                    self.appliedHDRStrength = self.hdrStrength
                    self.appliedHDRColorfulness = self.hdrColorfulness
                    self.applyActiveRendererSettings()
                    self.enhancedCachePreparationState = .ready
                    self.nativeFallbackActive = false
                    self.persistedPipelineConfiguration = candidate
                    self.persistedSharpness = self.sharpness
                    self.persistedHDRStrength = self.hdrStrength
                    self.persistedHDRColorfulness = self.hdrColorfulness
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
                    } else if shouldResume {
                        self.resumeAfterApplyingEnhancements(wasPlaying: true)
                    } else {
                        self.prepareEnhancedPlaybackWhilePaused()
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
                self.enhancedCachePreparationState = .preparing(
                    progress: 0,
                    bytesWritten: 0,
                    estimatedTotalBytes: estimatedRequiredBytes,
                    estimatedRemainingSeconds: nil
                )
                self.transitionPlayback(to: .preparingCache)
                let preparationStartedAt = ProcessInfo.processInfo.systemUptime
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
                    let boundedProgress = min(1, max(0, progress))
                    let elapsedSeconds = ProcessInfo.processInfo.systemUptime - preparationStartedAt
                    let estimatedRemainingSeconds = boundedProgress >= 0.03 && boundedProgress < 1
                        ? elapsedSeconds * (1 - boundedProgress) / boundedProgress
                        : nil
                    self?.enhancedCachePreparationState = .preparing(
                        progress: progress,
                        bytesWritten: bytesWritten,
                        estimatedTotalBytes: estimatedRequiredBytes,
                        estimatedRemainingSeconds: estimatedRemainingSeconds
                    )
                }
                guard self.enhancedCachePreparationGeneration == preparationGeneration,
                      self.videoURL == url,
                      preservesDraft || self.draftPipelineConfiguration == candidate else { return }
                self.preparedEnhancedFrameCacheKey = result.key
                self.preparedEnhancedFrameCacheMode = result.mode
                self.enhancedCacheCoveragePercent = result.status.coverageBitmap.isEmpty
                    ? 0
                    : Int((Double(result.status.coverageBitmap.filter { $0 }.count) / Double(result.status.coverageBitmap.count) * 100).rounded())
                self.appliedPipelineConfiguration = candidate
                self.appliedSharpness = self.sharpness
                self.appliedHDRStrength = self.hdrStrength
                self.appliedHDRColorfulness = self.hdrColorfulness
                self.applyActiveRendererSettings()
                self.persistedPipelineConfiguration = candidate
                self.persistedSharpness = self.sharpness
                self.persistedHDRStrength = self.hdrStrength
                self.persistedHDRColorfulness = self.hdrColorfulness
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
                } else if shouldResume {
                    self.resumeAfterApplyingEnhancements(wasPlaying: true)
                } else {
                    self.prepareEnhancedPlaybackWhilePaused()
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
                    self.appliedSharpness = self.enhancementTransactionPreviousSharpness
                    self.appliedHDRStrength = self.enhancementTransactionPreviousHDRStrength
                    self.appliedHDRColorfulness = self.enhancementTransactionPreviousHDRColorfulness
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
                        if !self.isPipelineActive {
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
                            self.appliedHDRStrength > 0 || self.appliedSharpness > 0
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
                    self.appliedSharpness = self.enhancementTransactionPreviousSharpness
                    self.appliedHDRStrength = self.enhancementTransactionPreviousHDRStrength
                    self.appliedHDRColorfulness = self.enhancementTransactionPreviousHDRColorfulness
                    self.applyActiveRendererSettings()
                    self.nativeFallbackActive = true
                    self.isPlaying = false
                    self.isPaused = true
                    let isQualitySRFailure = candidate.qualitySuperResolutionScaleFactor > 0
                    self.reportPlaybackIssue(
                        stage: isQualitySRFailure ? .qualitySRPreparation : .preparation,
                        message: isQualitySRFailure
                            ? "Quality Super Resolution couldn’t start with the selected level. Choose another upscale level to try again, or watch the original video."
                            : "Enhancement setup couldn’t be completed. Try changing the settings or watch the original video."
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

    private func prepareEnhancedPlaybackWhilePaused() {
        guard isPipelineActive else {
            isPlaying = false
            isPaused = true
            #if os(macOS)
            transitionPlayback(to: .readyPaused)
            #endif
            return
        }

        isPlaying = false
        isPaused = true
        enhancedCachePreparationState = .prerolling
        #if os(macOS)
        transitionPlayback(to: .prerollingEnhanced)
        #endif
        startPlaybackLoop()
    }

}
