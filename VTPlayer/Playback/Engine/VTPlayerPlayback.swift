import SwiftUI
import AVFoundation
import VideoToolbox
import CoreVideo
import MetalKit
#if os(iOS)
import MediaPlayer
#endif

extension VTPlayerViewModel {
    /// Converts monotonic uptime deltas without trapping if a timestamp was
    /// reset after the caller captured `now` during a pipeline transition.
    internal func elapsedUptimeSeconds(since start: DispatchTime, until end: DispatchTime) -> Double {
        guard end.uptimeNanoseconds >= start.uptimeNanoseconds else { return 0 }
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
    }

    /// Records a macOS draft change. Other platforms retain their immediate
    /// enhancement behavior until their Apply workflow is introduced.
    func updateEnhancements() {
        validateEnhancementSelections()
        #if os(macOS)
        cancelEnhancedCachePreparation()
        return
        #else
        appliedPipelineConfiguration = draftPipelineConfiguration
        restartAppliedEnhancements()
        #endif
    }

    /// Updates the active processor configuration without changing playback state.
    func restartAppliedEnhancements() {
        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        if isPlaying && !isPaused {
            if isPipelineActive {
                startPlaybackLoop()
            } else {
                stopPlaybackLoopOnly()
                if let player {
                    // The native layer is reinserted by SwiftUI after the
                    // pipeline view is removed. Re-enable the track once more
                    // on the next main-actor turn so disabling the last
                    // enhancement cannot leave AVPlayer presenting a black
                    // frame until the user restarts playback.
                    #if os(macOS)
                    setNativeVideoEnabled(true)
                    #endif
                    player.play()
                    player.rate = Float(playbackSpeed)
                    self.isPaused = false
                    #if os(macOS)
                    Task { @MainActor [weak self, weak player] in
                        guard let self, let player else { return }
                        await Task.yield()
                        guard self.videoURL != nil, !self.isPaused else { return }
                        self.setNativeVideoEnabled(true)
                        player.play()
                        player.rate = Float(self.playbackSpeed)
                    }
                    #endif
                }
            }
        } else if isPlaying && isPaused {
            // Don't restart the pipeline while paused — the cache clear
            // would cause a visible freeze on resume.  Flag it so play()
            // rebuilds the pipeline when the user unpauses.
            enhancementsPendingRestart = true
            #if os(macOS)
            if !isPipelineActive {
                setNativeVideoEnabled(true)
            }
            #endif
        }
        #endif
    }

    /// Toggles play and pause state.
    func togglePlayPause() {
        guard !isPreparingEnhancedCache else { return }
        guard player != nil else { return }
        if isPaused || !isPlaying {
            play()
        } else {
            pause()
        }
    }

    /// Starts playback and the VideoToolbox processing loop.
    func play() {
        guard let player = player else { return }

        self.isPlaying = true
        self.isPaused = false

        #if os(macOS)
        renderer.setRenderingActive(true)
        #endif

        #if os(iOS)
        player.playImmediately(atRate: Float(self.playbackSpeed))
        #else
        player.rate = Float(self.playbackSpeed)
        #endif
        enhancedAudioPlayer?.resume()
        #if os(iOS)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackSpeed
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif

        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        // Rebuild the pipeline if enhancements were changed while paused,
        // or if the loop has not yet been initialized. Otherwise, the existing
        // active loop will automatically resume processing when isPaused is false.
        if isPipelineActive {
            if enhancementsPendingRestart || producerTask == nil {
                enhancementsPendingRestart = false
                startPlaybackLoop()
            } else {
                startDisplayLinkIfNeeded()
            }
        } else {
            #if os(macOS)
            setNativeVideoEnabled(true)
            #endif
            stopPlaybackLoopOnly()
        }
        #endif
        self.userActivityDetected()
    }

    /// Drop persisted or programmatically assigned enhancement values that
    /// the current machine/video cannot actually run. Menu disabling is only
    /// a UI affordance; this guard protects the pipeline from stale state.
    func validateEnhancementSelections() {
        var disabledSelection = false
        if superResolutionLevel > 0,
           !availableSuperResolutionScales.contains(superResolutionLevel) {
            superResolutionLevel = 0
            disabledSelection = true
        }
        if qualitySuperResolutionScaleFactor > 0,
           !availableQualitySuperResolutionScales.contains(qualitySuperResolutionScaleFactor) {
            qualitySuperResolutionScaleFactor = 0
            disabledSelection = true
        }
        if frameInterpolationLevel > 0, !frameInterpolationIsAvailable {
            frameInterpolationLevel = 0
            // Capability filtering already removes this combination from the
            // menu. Keep the fallback silent instead of exposing an internal
            // device/configuration detail as a confusing playback error.
            srInitializationError = nil
        }
        if disabledSelection {
            srInitializationError = "Selected super-resolution mode is unavailable for this video on this device."
        }
    }

    /// Pauses player
    func pause() {
        guard let player = player else { return }
        player.pause()
        enhancedAudioPlayer?.pause()
        #if os(iOS)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
        resetPresentationClock(at: CMTimeGetSeconds(player.currentTime()))
        self.isPaused = true
        self.isBuffering = false
        #if os(macOS)
        renderer.setRenderingActive(false)
        stopDisplayLinkIfNeeded()
        #else
        if let link = displayLink {
            link.invalidate()
            self.displayLink = nil
        }
        #endif
        self.saveProgress()
        self.saveVideoSettings()
        self.userActivityDetected()
    }

    #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
    func endActiveCoordinator(after producer: Task<Void, Never>? = nil) {
        let coordinator = activeCoordinator
        activeCoordinator = nil
        guard let coordinator else { return }

        let producer = producer ?? producerTask
        producer?.cancel()
        coordinatorTeardownTask = Task {
            if let producer {
                await producer.value
            }
            await coordinator.endSession()
        }
    }

    func stopDisplayLinkIfNeeded() {
        #if os(macOS)
        renderer.onDisplayTick = nil
        macMetalDisplayLink?.invalidate()
        macMetalDisplayLink = nil
        macMetalDisplayTickDriver = nil
        if let macDisplayLink {
            CVDisplayLinkStop(macDisplayLink)
            self.macDisplayLink = nil
        }
        macDisplayTickDriver = nil
        renderer.setExternalDisplayScheduling(false)
        #endif
        if let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    #if os(macOS)
    func setNativeVideoEnabled(_ enabled: Bool) {
        guard let tracks = player?.currentItem?.tracks else { return }
        for track in tracks where track.assetTrack?.mediaType == .video {
            track.isEnabled = enabled
        }
        for track in tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = true
        }
    }
    #endif

    func setPrimaryAudioMuted(_ muted: Bool) {
        player?.volume = muted ? 0 : Float(volume)
    }

    func stopEnhancedAudioPlayback() {
        enhancedAudioPlayer?.stop()
        enhancedAudioPlayer = nil
        setPrimaryAudioMuted(false)
    }

    func stopPlaybackLoopOnly() {
        cancelEnhancedCachePreparation()
        stopEnhancedAudioPlayback()
        #if os(macOS)
        pipelinePresentationReady = false
        renderer.setRenderingActive(false)
        setNativeVideoEnabled(true)
        stopDisplayLinkIfNeeded()
        #endif
        pipelineRestartTask?.cancel()
        pipelineRestartTask = nil
        playbackGeneration += 1
        qualityModelRetryTask?.cancel()
        qualityModelRetryTask = nil
        let producer = producerTask
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        endActiveCoordinator(after: producer)

        #if !os(macOS)
        if let link = displayLink {
            link.invalidate()
            self.displayLink = nil
        }
        #endif

        audioSyncTask?.cancel()
        audioSyncTask = nil
        audioSyncLatency = 0
        pipelineRestartAnchorPTS = nil
        isInitializingPipeline = false
        presentedFramesCount = 0
        diagnosticPresentedFramesCount = 0
        diagnosticPresentedInterpolatedCount = 0
        diagnosticPresentedSourceCount = 0
        producedFramesCount = 0
        displayLinkTickCount = 0
        resetProducerTiming()
        displayRateSamples.removeAll(keepingCapacity: true)
        displayRate1PercentLow = 0
        displayRateMeasurementStart = .now()
        isBuffering = false
        lockCache { clearProcessedFrameCache() }
    }

    #if os(macOS)
    /// Leaves playback on AVPlayer's native video output if an enhancement
    /// session cannot be started. Settings stay intact so the user can adjust
    /// them and retry without the player going dark or losing audio.
    func restoreNativePresentationAfterPipelineFailure() {
        stopEnhancedAudioPlayback()
        isInitializingPipeline = false
        pipelinePresentationReady = false
        renderer.setRenderingActive(false)
        stopDisplayLinkIfNeeded()
        setNativeVideoEnabled(true)
        if let player {
            player.play()
            player.rate = Float(playbackSpeed)
            isPlaying = true
            isPaused = false
        }
    }
    #endif

    /// Serializes enhancement restarts. VideoToolbox sessions cannot safely be
    /// initialized while the previous producer still owns in-flight frames.
    func startPlaybackLoop() {
        if producerTask != nil || activeCoordinator != nil || coordinatorTeardownTask != nil,
           pipelineRestartAnchorPTS == nil {
            if let player {
                let currentTime = player.currentTime()
                if currentTime.isValid, currentTime.seconds.isFinite, currentTime.seconds >= 0 {
                    // The player clock is authoritative at an enhancement
                    // restart. The last rendered PTS can trail it by the
                    // processing/cache latency and cause a visible rewind.
                    pipelineRestartAnchorPTS = currentTime
                } else {
                    pipelineRestartAnchorPTS = lastRenderedPTS
                }
            } else {
                pipelineRestartAnchorPTS = lastRenderedPTS
            }
        }

        if let anchor = pipelineRestartAnchorPTS {
            isInitializingPipeline = true
            player?.pause()
            enhancedAudioPlayer?.pause()
            lockCache { clearProcessedFrameCache() }
            lastRenderedPTS = anchor
            resetPresentationClock(at: CMTimeGetSeconds(anchor))
        }

        if let coordinatorTeardownTask {
            playbackGeneration += 1
            let restartGeneration = playbackGeneration
            pipelineRestartTask?.cancel()
            pipelineRestartTask = Task { @MainActor [weak self] in
                await coordinatorTeardownTask.value
                guard let self, self.playbackGeneration == restartGeneration else { return }
                self.coordinatorTeardownTask = nil
                self.pipelineRestartTask = nil
                self.startPlaybackLoopNow()
            }
            return
        }

        guard producerTask != nil || activeCoordinator != nil else {
            startPlaybackLoopNow()
            return
        }

        playbackGeneration += 1
        let restartGeneration = playbackGeneration

        let oldProducer = producerTask
        let oldCoordinator = activeCoordinator
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        activeCoordinator = nil
        pipelineRestartTask?.cancel()
        pipelineRestartTask = Task { @MainActor [weak self] in
            if let oldProducer {
                await oldProducer.value
            }
            if let oldCoordinator {
                await oldCoordinator.endSession()
            }
            guard let self, self.playbackGeneration == restartGeneration else { return }
            self.pipelineRestartTask = nil
            self.startPlaybackLoopNow()
        }
    }

#endif
}
