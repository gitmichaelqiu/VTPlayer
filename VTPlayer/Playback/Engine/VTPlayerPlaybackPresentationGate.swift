import SwiftUI
import AVFoundation

extension VTPlayerViewModel {
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
            let startupAllowanceNanoseconds: UInt64 = 6_000_000_000
            let startupDeadline = DispatchTime.now().uptimeNanoseconds + startupAllowanceNanoseconds
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
                    reason: self.enhancedPresentationStartupFailureDetail(
                        allowanceNanoseconds: startupAllowanceNanoseconds
                    )
                )
                return
            }
            // Allow seek and display-link handoffs to settle before sampling.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  self.enhancedPresentationMonitorGeneration == monitorGeneration,
                  self.enhancedCachePreparationGeneration == preparationGeneration,
                  self.videoURL == url,
                  self.appliedPipelineConfiguration == candidate,
                  self.isPlaying, !self.isPaused else { return }
            var presentationWindowStart = DispatchTime.now()
            var presentationFrameBaseline = self.renderer.totalPresentedFrameCount()
            var failureTracker = EnhancedPresentationFailureTracker()
            var wasInactive = false
            var recoveryDeadline: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
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
                if let window = self.renderer.window,
                   (!NSApp.isActive || !window.isKeyWindow || !window.occlusionState.contains(.visible)) {
                    wasInactive = true
                    failureTracker = EnhancedPresentationFailureTracker()
                    presentationFrameBaseline = self.renderer.totalPresentedFrameCount()
                    presentationWindowStart = now
                    continue
                }
                if wasInactive {
                    wasInactive = false
                    recoveryDeadline = now.uptimeNanoseconds + 2_000_000_000
                }
                if now.uptimeNanoseconds < recoveryDeadline {
                    failureTracker = EnhancedPresentationFailureTracker()
                    presentationFrameBaseline = self.renderer.totalPresentedFrameCount()
                    presentationWindowStart = now
                    continue
                }
                let elapsed = self.elapsedUptimeSeconds(since: presentationWindowStart, until: now)
                guard elapsed >= EnhancedPresentationFailureTracker.windowSeconds else { continue }

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
                let shouldRecover = failureTracker.shouldRecover(passes: passes)
                if passes {
                    self.livePresentationGateValidated = true
                    self.enhancedCachePreparationState = .ready
                    if self.playbackPhase == .monitoringEnhanced ||
                        self.playbackPhase == .prerollingEnhanced {
                        self.transitionPlayback(to: .playingEnhanced)
                    }
                } else {
                    if !EnhancedPresentationGate.canUseProcessedFrameCache(for: candidate) {
                        presentationFrameBaseline = totalPresentedFrames
                        presentationWindowStart = now
                        continue
                    }
                    if !shouldRecover {
                        presentationFrameBaseline = totalPresentedFrames
                        presentationWindowStart = now
                        continue
                    }
                    if failureTracker.canRetry,
                       self.preparedEnhancedFrameCacheMode != .full,
                       self.macDedicatedMetalDisplayTickDriver != nil,
                       let player = self.player {
                        self.stopDisplayLinkIfNeeded()
                        self.resetPresentationClock(at: CMTimeGetSeconds(player.currentTime()))
                        self.startDisplayLinkIfNeeded()
                        failureTracker.markRetry()
                        presentationFrameBaseline = self.renderer.totalPresentedFrameCount()
                        presentationWindowStart = DispatchTime.now()
                        NSLog("RENDER: retrying live presentation before cache fallback")
                        continue
                    }
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

    private func enhancedPresentationStartupFailureDetail(allowanceNanoseconds: UInt64) -> String {
        let allowedSeconds = Double(allowanceNanoseconds) / 1_000_000_000
        guard preparedEnhancedFrameCacheMode == .full else {
            return "No enhanced frame was submitted within \(String(format: "%.0f", allowedSeconds)) seconds."
        }

        let queue = fullCachePresentationQueue?.snapshot()
        let driver = macDedicatedMetalDisplayTickDriver?.startupSnapshot()
        let presentedSincePipelineStart = max(
            0,
            renderer.totalPresentedFrameCount() - actualPresentedFrameBaseline
        )
        let nextPresentationTime = queue?.nextPresentationSeconds.map {
            String(format: "%.3f", $0)
        } ?? "none"
        let metalDisplayLinkCallbacks = macMetalDisplayTickDriver?.startupCallbackCount() ?? 0
        let driverDetails: String
        if let driver {
            driverDetails = "dedicated callbacks=\(driver.callbacks), submitted=\(driver.renderedFrames), drawableFailures=\(driver.drawableAcquisitionFailures), encodeFailures=\(driver.encodingFailures)"
        } else if dedicatedPresentationFallbackURL == videoURL,
                  dedicatedPresentationFallbackConfiguration == appliedPipelineConfiguration,
                  let dedicatedPresentationFallbackSummary {
            driverDetails = "\(dedicatedPresentationFallbackSummary); CAMetalDisplayLink callbacks=\(metalDisplayLinkCallbacks)"
        } else {
            driverDetails = "CAMetalDisplayLink callbacks=\(metalDisplayLinkCallbacks)"
        }
        let diagnostics = "queueFrames=\(queue?.frameCount ?? 0), nextPTS=\(nextPresentationTime), actualPresentations=\(presentedSincePipelineStart), \(driverDetails)"
        NSLog("RENDER: full-cache first-frame startup timed out after %.0f seconds: %@", allowedSeconds, diagnostics)
        return "No enhanced frame appeared within \(String(format: "%.0f", allowedSeconds)) seconds."
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

        guard preparedEnhancedFrameCacheMode == .full ||
                !EnhancedPresentationGate.canUseProcessedFrameCache(for: candidate) else {
            fallbackToFullCacheAfterPresentationFailure()
            return
        }

        let physicalRate = Double(renderer.schedulingSnapshot().screenMaximumFramesPerSecond)
        let targetRate = physicalRate > 0 ? min(requestedRate, physicalRate) : requestedRate
        let renderedSeconds = CMTimeGetSeconds(lastRenderedPTS)
        let playerSeconds = player.map { CMTimeGetSeconds($0.currentTime()) } ?? currentTime
        let fallbackSeconds = min(
            duration,
            max(0, pipelinePresentationReady && renderedSeconds.isFinite ? renderedSeconds : playerSeconds)
        )
        suppressRateObserver = true
        player?.pause()
        enhancedAudioPlayer?.pause()
        stopPlaybackLoopOnly()
        nativeFallbackActive = true
        livePresentationGateValidated = false
        enhancedCachePreparationState = .ready
        liveFallbackWasPlaying = false
        actualPresentedFrameRate = measuredRate
        actualPresented1PercentLow = actualPresentedRateSamples.min() ?? measuredRate
        let performanceDetail: String
        if measuredRate > 0 {
            performanceDetail = "Enhanced playback reached \(String(format: "%.1f", measuredRate)) fps on a \(String(format: "%.0f", targetRate))-Hz display. "
        } else {
            performanceDetail = "\(reason) "
        }
        let notice = performanceDetail + (preparedEnhancedFrameCacheMode == .full
            ? "Continuing with the original video; your prepared cache is kept."
            : "Continuing with the original video.")
        clearPlaybackIssue()
        showPlaybackNotice(notice)

        guard let player else {
            isPlaying = false
            isPaused = true
            transitionPlayback(to: .paused)
            return
        }

        seekGeneration &+= 1
        let fallbackSeekGeneration = seekGeneration
        let fallbackTime = CMTime(seconds: fallbackSeconds, preferredTimescale: 600)
        lastPublishedCurrentTime = fallbackSeconds
        currentTime = fallbackSeconds
        resetPresentationClock(at: fallbackSeconds)
        pendingExplicitSeekPTS = fallbackTime
        suppressNativeTimeObserverDuringSeek = true
        suppressRateObserver = true
        isPlaying = true
        isPaused = false
        transitionPlayback(to: .playingNative)
        let fallbackPlaybackGeneration = playbackGeneration
        player.seek(to: fallbackTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] completed in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player,
                      self.videoURL == url,
                      self.playbackGeneration == fallbackPlaybackGeneration,
                      self.seekGeneration == fallbackSeekGeneration,
                      self.nativeFallbackActive else { return }
                self.suppressNativeTimeObserverDuringSeek = false
                self.suppressRateObserver = false
                self.pendingExplicitSeekPTS = nil
                guard self.playbackPhase == .playingNative,
                      self.isPlaying,
                      !self.isPaused else { return }
                if completed {
                    player.play()
                    player.rate = Float(self.playbackSpeed)
                } else {
                    self.publishCurrentTime(CMTimeGetSeconds(player.currentTime()), immediately: true)
                    player.play()
                    player.rate = Float(self.playbackSpeed)
                }
            }
        }
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
