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
    private func elapsedUptimeSeconds(since start: DispatchTime, until end: DispatchTime) -> Double {
        guard end.uptimeNanoseconds >= start.uptimeNanoseconds else { return 0 }
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
    }

    /// Updates coordinator when features are toggled without changing playback state.
    func updateEnhancements() {
        validateEnhancementSelections()
        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        if isPlaying && !isPaused {
            if isPipelineActive {
                startPlaybackLoop()
            } else {
                stopPlaybackLoopOnly()
                if let player {
                    player.play()
                    player.rate = Float(playbackSpeed)
                    self.isPaused = false
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
            srInitializationError = qualitySuperResolutionScaleFactor == 4
                ? "Frame interpolation is unavailable with Quality 4x on this device."
                : "Frame interpolation is unavailable at this video's native resolution."
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

    private func startPlaybackLoopNow() {
        guard coordinatorTeardownTask == nil else {
            startPlaybackLoop()
            return
        }
        let shouldResumePlayback = isPlaying && !isPaused
        let restartAnchorPTS = pipelineRestartAnchorPTS
        pipelineRestartAnchorPTS = nil
        stopEnhancedAudioPlayback()
        #if os(macOS)
        pipelinePresentationReady = false
        renderer.setRenderingActive(true)
        setNativeVideoEnabled(true)
        #endif
        isBuffering = false
        playbackGeneration += 1
        qualityModelRetryTask?.cancel()
        qualityModelRetryTask = nil
        let gen = playbackGeneration
        let oldProducer = producerTask
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        endActiveCoordinator(after: oldProducer)

        let sourceFPS = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30.0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(sourceFPS))
        let pipelineWidth = videoWidth
        let pipelineHeight = videoHeight
        let targetFrameRate = sourceFrameRate * (frameInterpolationLevel > 0 ? Double(frameInterpolationLevel) : 1.0)
        #if os(macOS)
        // FI output needs callback headroom above its media cadence. A 60 Hz
        // request can settle below a 50/60 fps FI2 stream when rendering has
        // even small timing variance. macOS clamps 120 Hz to the display.
        renderer.preferredFramesPerSecond = frameInterpolationLevel > 0 ? 120 : 60
        #endif
        NSLog("PIPELINE: source=\(videoWidth)x\(videoHeight) input=\(pipelineWidth)x\(pipelineHeight) fi=\(frameInterpolationLevel)x sr=\(superResolutionLevel)x qsr=\(qualitySuperResolutionScaleFactor)x sourceFPS=\(String(format: "%.3f", sourceFrameRate)) targetFPS=\(String(format: "%.3f", targetFrameRate))")

        lockCache { clearProcessedFrameCache() }
        if let player = player {
            let startTime = restartAnchorPTS ?? player.currentTime()
            let adjusted = CMTimeSubtract(startTime, frameDuration)
            lastPulledTime = adjusted > .zero ? adjusted : .zero
            lastRenderedPTS = startTime
            resetPresentationClock(at: CMTimeGetSeconds(startTime))
        } else {
            lastPulledTime = .zero
            lastRenderedPTS = .zero
            resetPresentationClock(at: 0)
        }
        audioSyncLatency = 0
        fps = 0
        presentedFramesCount = 0
        displayRateSamples.removeAll(keepingCapacity: true)
        displayRate1PercentLow = 0
        fpsTimer = .now()
        displayRateMeasurementStart = .now()

        let srLevel = self.superResolutionLevel
        let fiLevel = self.frameInterpolationLevel
        let highQuality = self.useHighQualityDownsampling
        let realTime = self.useRealTimePriority
        #if os(macOS)
        // The combined LL SR/FI processor produces visibly softer output
        // than native FI followed by SR on macOS. Prefer the temporal-first
        // sequential path for this quality-sensitive combination.
        let sequentialSRFIFallback = self.useSequentialSRFIFallback ||
            (srLevel == 2 && fiLevel == 2)
        #else
        let sequentialSRFIFallback = self.useSequentialSRFIFallback
        #endif
        let qualitySR = self.qualitySuperResolutionScaleFactor
        let mbStrength = self.motionBlurStrength
        let dnStrength = self.denoiseStrength
        let qualPrior = self.qualityPrioritization

        producerTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var pausedForInitialization = false
            
            defer {
                // A replacement loop has a newer generation. Never let a
                // cancelled predecessor erase its producer handle.
                if self.playbackGeneration == gen {
                    self.producerTask = nil

                    // Session setup pauses AVPlayer so a new cache can be
                    // primed.  Every successful path below clears this flag.
                    // If setup exits early (for example, because a setting
                    // changed while VideoToolbox was initializing), restore
                    // the player instead of leaving it frozen until a seek.
                    if pausedForInitialization && self.isInitializingPipeline {
                        self.isInitializingPipeline = false
                        if self.isPlaying && !self.isPaused {
                            self.player?.rate = Float(self.playbackSpeed)
                        }
                    }
                }
            }

            // Check Quality SR model availability before starting (macOS only)
            var effectiveQualitySR = qualitySR
            var effectiveSRLevel = srLevel
            
            #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
            @MainActor func fallBackFromQualitySR(preserveSelection: Bool = false) {
                effectiveQualitySR = 0
                let requestedFallback: Float = qualitySR == 4 ? 4 : 2
                if self.availableSuperResolutionScales.contains(requestedFallback) {
                    effectiveSRLevel = requestedFallback
                } else if self.availableSuperResolutionScales.contains(2) {
                    effectiveSRLevel = 2
                } else {
                    effectiveSRLevel = 0
                }

                // Keep the controls truthful: the visible selection must
                // match the processor that will actually run.
                if !preserveSelection {
                    self.qualitySuperResolutionScaleFactor = 0
                }
                self.superResolutionLevel = effectiveSRLevel
            }

            if qualitySR > 0 {
                var qlConfig: VTSuperResolutionScalerConfiguration? = nil
                if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
                   VTSuperResolutionScalerConfiguration.isSupported {
                    qlConfig = VTSuperResolutionScalerConfiguration(
                        frameWidth: videoWidth, frameHeight: videoHeight,
                        scaleFactor: qualitySR, inputType: .video,
                        usePrecomputedFlow: false, qualityPrioritization: .normal,
                        revision: .revision1
                    )
                    if qlConfig == nil {
                        self.srInitializationError = "Quality SR unavailable for \(videoWidth)x\(videoHeight)"
                        print("Quality SR not available for \(videoWidth)x\(videoHeight) @ \(qualitySR)x")
                    }
                } else {
                    print("VTSuperResolutionScaler not supported on this system")
                }
                if let checkConfig = qlConfig {
                    self.modelManager.checkStatus(for: checkConfig)
                    switch self.modelManager.status {
                    case .ready:
                        break
                    case .downloadRequired:
                        print("Quality SR model download required, starting download")
                        self.modelManager.downloadModel(for: checkConfig)
                        self.retryAfterQualityModelDownload(generation: gen)
                        fallBackFromQualitySR(preserveSelection: true)
                    case .downloading:
                        self.retryAfterQualityModelDownload(generation: gen)
                        fallBackFromQualitySR(preserveSelection: true)
                    case .failed(let message):
                        self.srInitializationError = "Quality SR model unavailable: \(message)"
                        fallBackFromQualitySR()
                    case .notChecked:
                        fallBackFromQualitySR()
                    }
                } else {
                    fallBackFromQualitySR()
                }
            }

            #if os(macOS)
            if effectiveSRLevel > 0 {
                let canStartPipeline = await VTFrameProcessorCoordinator
                    .canStartLowLatencyPipeline(width: pipelineWidth, height: pipelineHeight, scale: effectiveSRLevel)
                if !canStartPipeline {
                    self.srInitializationError = "Low Latency SR does not support \(pipelineWidth)x\(pipelineHeight) on this device; enhancement disabled."
                    effectiveSRLevel = 0
                    print("Low Latency SR session unavailable for \(pipelineWidth)x\(pipelineHeight)")
                }
            }
            #endif
            #endif
            var coordinator = VTFrameProcessorCoordinator(
                superResolutionLevel: effectiveSRLevel,
                frameInterpolationLevel: fiLevel,
                useHighQualityDownsampling: highQuality,
                useRealTimePriority: realTime,
                preferSequentialSRFI: sequentialSRFIFallback,
                qualitySuperResolutionScaleFactor: effectiveQualitySR,
                motionBlurStrength: mbStrength,
                denoiseStrength: dnStrength,
                qualityPrioritization: qualPrior
            )
            guard !Task.isCancelled, gen == self.playbackGeneration else { return }
            self.activeCoordinator = coordinator

            // Pause the player during coordinator init so the audio clock
            // doesn't advance while the cache is empty.  Without this, the
            // consumer stalls (empty cache) while audio keeps running,
            // creating an audible gap followed by a video jump.
            self.isInitializingPipeline = true
            let wasRate = self.player?.rate ?? 0
            self.player?.pause()
            pausedForInitialization = true

            do {
                if (effectiveSRLevel > 0 || effectiveQualitySR > 0 || (srLevel == 0 && qualitySR == 0)),
                   self.srInitializationError == nil {
                    self.srInitializationError = nil
                }
                try await coordinator.startSession(width: pipelineWidth, height: pipelineHeight)
            } catch {
                guard gen == self.playbackGeneration else { return }
                await coordinator.endSession()

                // The combined processor is capability- and
                // resolution-dependent. Keep SR enabled when it rejects the
                // exact pixel-buffer requirements by retrying the established
                // sequential temporal-first LL SR path.
                if effectiveSRLevel == 2 && fiLevel == 2 && effectiveQualitySR == 0 && !sequentialSRFIFallback {
                    let message = "Combined 2x SR + 2x FI unavailable at \(pipelineWidth)x\(pipelineHeight); using sequential SR + FI."
                    self.srInitializationError = message
                    print("Failed to initialize combined SR/FI session: \(error.localizedDescription). Retrying sequential SR + FI.")
                    self.useSequentialSRFIFallback = true

                    coordinator = VTFrameProcessorCoordinator(
                        superResolutionLevel: effectiveSRLevel,
                        frameInterpolationLevel: fiLevel,
                        useHighQualityDownsampling: highQuality,
                        useRealTimePriority: realTime,
                        preferSequentialSRFI: true,
                        qualitySuperResolutionScaleFactor: effectiveQualitySR,
                        motionBlurStrength: mbStrength,
                        denoiseStrength: dnStrength,
                        qualityPrioritization: qualPrior
                    )
                    self.activeCoordinator = coordinator
                    do {
                        try await coordinator.startSession(width: pipelineWidth, height: pipelineHeight)
                    } catch {
                        self.srInitializationError = "Sequential SR + FI fallback unavailable: \(error.localizedDescription)"
                        print("Failed to initialize sequential SR/FI fallback session: \(error.localizedDescription)")
                        self.activeCoordinator = nil
                        await coordinator.endSession()
                        #if os(macOS)
                        self.restoreNativePresentationAfterPipelineFailure()
                        #else
                        self.stop()
                        #endif
                        return
                    }
                } else {
                    self.srInitializationError = error.localizedDescription
                    print("Failed to initialize coordinator session: \(error.localizedDescription)")
                    self.activeCoordinator = nil
                    #if os(macOS)
                    self.restoreNativePresentationAfterPipelineFailure()
                    #else
                    self.stop()
                    #endif
                    return
                }
            }

            guard let videoURL = self.videoURL else {
                self.activeCoordinator = nil
                await coordinator.endSession()
                return
            }

            // Re-sync after coordinator setup, then keep audio and video
            // paused until the entire safe processed-frame cache is ready.
            var waitingForFramePreroll = false
            if let player = self.player {
                let resumeTime = restartAnchorPTS ?? player.currentTime()
                if restartAnchorPTS != nil {
                    _ = await player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                let readerStart = CMTimeSubtract(resumeTime, frameDuration)
                self.lastPulledTime = readerStart > .zero ? readerStart : .zero
                self.lastRenderedPTS = CMTimeSubtract(
                    resumeTime,
                    CMTime(value: 1, timescale: 600)
                )
                self.resetPresentationClock(at: CMTimeGetSeconds(resumeTime))
                let shouldResume = shouldResumePlayback && gen == self.playbackGeneration
                self.isInitializingPipeline = false
                pausedForInitialization = false
                if shouldResume {
                    self.isPlaying = true
                    self.isPaused = false
                    self.isBuffering = true
                    waitingForFramePreroll = true
                    let audioPlayer = EnhancedAudioPlayer()
                    if audioPlayer.prepare(url: videoURL, initialRate: self.playbackSpeed) {
                        audioPlayer.setVolume(Float(self.volume))
                        self.enhancedAudioPlayer = audioPlayer
                        self.setPrimaryAudioMuted(true)
                    }
                } else {
                    player.pause()
                    if resumeTime <= .zero, let url = self.videoURL,
                       let firstFrame = await self.readSingleFrame(from: url, at: .zero) {
                        self.renderer.render(pixelBuffer: firstFrame.buffer)
                    }
                }
            } else {
                self.isInitializingPipeline = false
                pausedForInitialization = false
            }

            // Create VTFrameSequence to decode frames faster-than-real-time
            var iteratorStartTime = self.lastPulledTime
            let sourcePadding = await coordinator.sourceFramePadding()
            let frameSequence = VTFrameSequence(
                url: videoURL,
                startTime: iteratorStartTime,
                outputSize: nil,
                extendedPixelsRight: sourcePadding.right,
                extendedPixelsBottom: sourcePadding.bottom
            )
            var frameIterator = frameSequence.makeAsyncIterator()
            var prefetchedFrameTask: Task<VTFrame?, Error>?
            var sourceFrameOrdinal = 0
            var combinedProcessFallbackAttempted = false
            defer { prefetchedFrameTask?.cancel() }

            @MainActor
            func resumeAfterFramePrerollIfReady(force: Bool = false) {
                guard waitingForFramePreroll, let player = self.player else { return }
                let cachedFrameCount = self.lockCache {
                    max(0, self.processedFrameCache.count - self.processedFrameCacheStart)
                }
                guard cachedFrameCount >= self.initialPrerollFrameCount || (force && cachedFrameCount > 0) else {
                    return
                }
                waitingForFramePreroll = false
                self.isBuffering = false
                self.resetPresentationClock(at: CMTimeGetSeconds(player.currentTime()))
                player.rate = wasRate != 0 ? wasRate : Float(self.playbackSpeed)
            }

            @MainActor
            func waitForCacheCapacity(_ byteCount: Int) async -> Bool {
                guard byteCount <= self.frameCacheMemoryBudget else { return false }
                while !Task.isCancelled && gen == self.playbackGeneration {
                    let hasRoom = self.lockCache {
                        self.cacheCanAccept(byteCount)
                    }
                    if hasRoom { return true }
                    self.lockCache {
                        self.compactProcessedFrameCacheIfNeeded(force: true)
                    }
                    let hasRoomAfterCompaction = self.lockCache {
                        self.cacheCanAccept(byteCount)
                    }
                    if hasRoomAfterCompaction { return true }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return false
            }

            @MainActor
            func admitStreamedFrame(_ frame: VTFrame) async -> Bool {
                let byteCount = CVPixelBufferGetDataSize(frame.buffer)
                guard byteCount <= self.frameCacheMemoryBudget else {
                    self.srInitializationError = "An enhanced frame exceeds the selected frame cache limit."
                    return false
                }
                let admissionStart = DispatchTime.now()
                guard await waitForCacheCapacity(byteCount) else { return false }
                let admissionMilliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds - admissionStart.uptimeNanoseconds
                ) / 1_000_000.0
                let insertionStart = DispatchTime.now()
                let inserted = self.lockCache {
                    self.insertProcessedFrameIntoCache(frame)
                }
                let insertionMilliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds - insertionStart.uptimeNanoseconds
                ) / 1_000_000.0
                self.recordProducerTiming(
                    cacheAdmissionMilliseconds: admissionMilliseconds,
                    cacheInsertionMilliseconds: insertionMilliseconds
                )
                if inserted {
                    self.producedFramesCount += 1
                    resumeAfterFramePrerollIfReady()
                }
                return !Task.isCancelled && gen == self.playbackGeneration
            }

            while !Task.isCancelled {
                guard gen == self.playbackGeneration else { break }

                if self.isPaused && !self.isBuffering {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    continue
                }

                // Detect seek: if lastPulledTime was changed by seekRelative,
                // recreate the iterator at the new position. Without this, the
                // producer would keep feeding stale frames from the old position.
                if self.lastPulledTime != iteratorStartTime {
                    prefetchedFrameTask?.cancel()
                    prefetchedFrameTask = nil
                    iteratorStartTime = self.lastPulledTime
                    let newSequence = VTFrameSequence(
                        url: videoURL,
                        startTime: iteratorStartTime,
                        outputSize: nil,
                        extendedPixelsRight: sourcePadding.right,
                        extendedPixelsBottom: sourcePadding.bottom
                    )
                    frameIterator = newSequence.makeAsyncIterator()
                    sourceFrameOrdinal = 0
                    continue
                }

                // Keep a modest look-ahead so the consumer can absorb brief
                // processor spikes without retaining an unnecessarily large
                // decoded frame backlog on macOS.
                let count = self.lockCache {
                    max(0, self.processedFrameCache.count - self.processedFrameCacheStart)
                }
                if count >= self.bufferedFrameLimit {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }

                // Read next decoded frame (hardware decoder, ~1ms per frame)
                let vtFrame: VTFrame
                let decodeWaitStart = DispatchTime.now()
                do {
                    let next: VTFrame?
                    if let prefetchedTask = prefetchedFrameTask {
                        next = try await prefetchedTask.value
                        prefetchedFrameTask = nil
                    } else {
                        next = try await frameIterator.next()
                    }
                    guard let next else {
                        break  // EOF
                    }
                    vtFrame = next
                } catch {
                    print("VTFrameSequence error: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                let decodeWaitMilliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds - decodeWaitStart.uptimeNanoseconds
                ) / 1_000_000.0

                let iteratorForPrefetch = frameIterator
                prefetchedFrameTask = Task.detached(priority: .userInitiated) {
                    try await iteratorForPrefetch.next()
                }

                sourceFrameOrdinal += 1
                #if os(macOS)
                let fastFI4Stride = fiLevel == 4 && self.playbackSpeed > 1
                    ? Int(self.playbackSpeed.rounded(.up))
                    : 1
                if fastFI4Stride > 1,
                   (sourceFrameOrdinal - 1) % fastFI4Stride != 0 {
                    continue
                }
                #endif

                // Process through the VideoToolbox pipeline
                let processStart = DispatchTime.now()
                do {
                    var streamedFrameCount = 0
                    let outputFrames = try await coordinator.processFrame(vtFrame) { frame in
                        guard await admitStreamedFrame(frame) else { return false }
                        streamedFrameCount += 1
                        return true
                    }
                    let processEnd = DispatchTime.now()

                    guard gen == self.playbackGeneration else { break }

                    self.publishProcessingDiagnostics(
                        Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000.0
                    )
                    let processingMilliseconds = Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000.0
                    let sourceFrameBudgetMilliseconds = sourceFPS > 0 ? 1_000.0 / sourceFPS : 0
                    let outputFrameCount = streamedFrameCount + outputFrames.count
                    if frameInterpolationLevel > 0,
                       processingMilliseconds > sourceFrameBudgetMilliseconds {
                        let processingText = String(format: "%.1f", processingMilliseconds)
                        let budgetText = String(format: "%.1f", sourceFrameBudgetMilliseconds)
                        print("PERF: FI deadline miss processing=\(processingText)ms budget=\(budgetText)ms outputs=\(outputFrameCount) sr=\(effectiveSRLevel) qsr=\(effectiveQualitySR) size=\(pipelineWidth)x\(pipelineHeight)")
                    }

                    if outputFrameCount < 2 && self.frameInterpolationLevel > 0 {
                        print("⚠️ FI: expected >=2 output frames, got \(outputFrameCount) for frame at \(CMTimeGetSeconds(vtFrame.presentationTimeStamp))")
                    }

                    if streamedFrameCount > 0 {
                        self.recordProducerTiming(decodeWaitMilliseconds: decodeWaitMilliseconds)
                        continue
                    }

                    let outputByteCount = outputFrames.reduce(into: 0) { total, frame in
                        total += CVPixelBufferGetDataSize(frame.buffer)
                    }
                    guard outputByteCount <= self.frameCacheMemoryBudget else {
                        self.srInitializationError = "An enhanced frame exceeds the selected frame cache limit."
                        print("⚠️ Enhanced frame requires \(outputByteCount) bytes, exceeding the configured cache limit of \(self.frameCacheMemoryBudget) bytes.")
                        break
                    }
                    let cacheAdmissionStart = DispatchTime.now()
                    guard await waitForCacheCapacity(outputByteCount) else { break }
                    let cacheAdmissionMilliseconds = Double(
                        DispatchTime.now().uptimeNanoseconds - cacheAdmissionStart.uptimeNanoseconds
                    ) / 1_000_000.0
                    let cacheInsertionStart = DispatchTime.now()
                    let insertedFrameCount = self.lockCache {
                        outputFrames.reduce(into: 0) { count, frame in
                            if self.insertProcessedFrameIntoCache(frame) {
                                count += 1
                            }
                        }
                    }
                    let cacheInsertionMilliseconds = Double(
                        DispatchTime.now().uptimeNanoseconds - cacheInsertionStart.uptimeNanoseconds
                    ) / 1_000_000.0
                    self.recordProducerTiming(
                        decodeWaitMilliseconds: decodeWaitMilliseconds,
                        cacheAdmissionMilliseconds: cacheAdmissionMilliseconds,
                        cacheInsertionMilliseconds: cacheInsertionMilliseconds
                    )
                    self.producedFramesCount += insertedFrameCount
                    resumeAfterFramePrerollIfReady()

                } catch {
                    guard gen == self.playbackGeneration else { break }
                    if effectiveSRLevel == 2 && fiLevel == 2 && effectiveQualitySR == 0 &&
                        !self.useSequentialSRFIFallback && !combinedProcessFallbackAttempted {
                        combinedProcessFallbackAttempted = true
                        self.useSequentialSRFIFallback = true
                        self.srInitializationError = "Combined 2x SR + 2x FI failed during processing (\(error.localizedDescription)); using sequential SR + FI."
                        print("⚠️ Combined SR/FI processing failed: \(error.localizedDescription). Restarting with sequential SR + FI.")
                        self.startPlaybackLoop()
                        break
                    }
                    print("⚠️ Pipeline processing error: \(error) — preserving source frame; fi=\(fiLevel) sr=\(effectiveSRLevel) qsr=\(effectiveQualitySR) size=\(pipelineWidth)x\(pipelineHeight)")
                    let fallbackByteCount = CVPixelBufferGetDataSize(vtFrame.buffer)
                    guard fallbackByteCount <= self.frameCacheMemoryBudget else {
                        self.srInitializationError = "An enhanced frame exceeds the selected frame cache limit."
                        break
                    }
                    let cacheAdmissionStart = DispatchTime.now()
                    guard await waitForCacheCapacity(fallbackByteCount) else { break }
                    let cacheAdmissionMilliseconds = Double(
                        DispatchTime.now().uptimeNanoseconds - cacheAdmissionStart.uptimeNanoseconds
                    ) / 1_000_000.0
                    let cacheInsertionStart = DispatchTime.now()
                    let inserted = self.lockCache {
                        self.insertProcessedFrameIntoCache(vtFrame)
                    }
                    let cacheInsertionMilliseconds = Double(
                        DispatchTime.now().uptimeNanoseconds - cacheInsertionStart.uptimeNanoseconds
                    ) / 1_000_000.0
                    self.recordProducerTiming(
                        decodeWaitMilliseconds: decodeWaitMilliseconds,
                        cacheAdmissionMilliseconds: cacheAdmissionMilliseconds,
                        cacheInsertionMilliseconds: cacheInsertionMilliseconds
                    )
                    if inserted {
                        self.producedFramesCount += 1
                    }
                    resumeAfterFramePrerollIfReady()
                }
            }

            resumeAfterFramePrerollIfReady(force: true)

            await coordinator.endSession()
            if self.playbackGeneration == gen {
                self.activeCoordinator = nil
                self.producerTask = nil
            }
        }
        
        startDisplayLinkIfNeeded()

        audioSyncTask?.cancel()
        audioSyncTask = Task {
            let myGen = gen
            while !Task.isCancelled {
                guard myGen == self.playbackGeneration else { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !self.isPaused, let player = self.player else { continue }
                guard !self.isBuffering else { continue }
                let currentSecs = CMTimeGetSeconds(player.currentTime())
                let lastSecs = CMTimeGetSeconds(self.lastRenderedPTS)
                let latency = currentSecs - lastSecs
                // Keep the audio clock independent from the processed-frame
                // queue. Pausing AVPlayer here can deadlock playback when a
                // restart or a slow FI/SR frame leaves fewer than two frames
                // buffered; the display consumer already performs PTS-aware
                // pacing and late-frame dropping.
                self.isBuffering = false

                // Record desync for diagnostics without interrupting audio.
                if latency > self.audioSyncLatencyThreshold {
                    self.audioSyncLatency = latency
                } else {
                    self.audioSyncLatency = 0
                }

            }
        }
    }

    func startDisplayLinkIfNeeded() {
        #if os(iOS)
        if let displayLink {
            configureDisplayLinkFrameRate(displayLink)
            return
        }
        #else
        guard displayLink == nil else { return }
        #endif

        // Use the same display-link scheduler on both platforms.
        #if os(macOS)
        // Let the renderer's MTKView own the display cadence. A separate
        // NSWindow display link can be throttled independently and then
        // starves FI output even while the Metal view is drawing at refresh.
        renderer.onDisplayTick = { [weak self] in
            self?.tickDisplayLink()
        }
        #else
        let link = CADisplayLink(target: self, selector: #selector(caDisplayLinkTick))
        #if os(iOS)
        configureDisplayLinkFrameRate(link)
        #endif
        #endif
        #if !os(macOS)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
        #endif
    }

    #if os(iOS)
    private func configureDisplayLinkFrameRate(_ displayLink: CADisplayLink) {
        // Default display links are commonly capped at 60 Hz even on
        // ProMotion hardware. Request the display maximum for 4x FI and
        // restore the system default for other playback modes.
        if frameInterpolationLevel == 4 {
            let maximumRate = Float(UIScreen.main.maximumFramesPerSecond)
            if #available(iOS 15.0, *) {
                displayLink.preferredFrameRateRange = CAFrameRateRange(
                    minimum: maximumRate,
                    maximum: maximumRate,
                    preferred: maximumRate
                )
            } else {
                displayLink.preferredFramesPerSecond = Int(maximumRate)
            }
        } else {
            displayLink.preferredFramesPerSecond = 0
        }
    }
    #endif
    #endif

    @MainActor
    func tickDisplayLink() {
        guard isPlaying && !isPaused, let player = self.player else { return }
        #if os(iOS)
        // AVPlayerViewController owns the transport controls. Honor its pause
        // state in the render callback as well as through KVO, because a busy
        // 4x pipeline can defer the KVO delivery by a display interval.
        if player.timeControlStatus == .paused, !isInitializingPipeline, !isBuffering {
            pause()
            return
        }
        #endif
        displayLinkTickCount += 1
        
        let currentTime = player.currentTime()
        let observedSecs = CMTimeGetSeconds(currentTime)
        let currentSecs = presentationClockSeconds(playerSeconds: observedSecs)
        let presentationSecs = currentSecs
        
        var lastFrameToRender: VTFrame? = nil
        var drained = 0
        let now = DispatchTime.now()
        let needsTimelineCatchUp = frameInterpolationLevel > 0 && sourceFrameRate > 0
        
        self.lockCache {
            if needsTimelineCatchUp {
                // 4x output can exceed the display callback rate. Keep media
                // time authoritative: present the newest frame due now and
                // discard only interpolation frames the display has missed.
                while self.processedFrameCacheStart < self.processedFrameCache.count {
                    let candidate = self.processedFrameCache[self.processedFrameCacheStart]
                    if candidate.presentationTimeStamp <= self.lastRenderedPTS {
                        self.processedFrameCacheStart += 1
                        drained += 1
                        continue
                    }
                    let candidateTime = CMTimeGetSeconds(candidate.presentationTimeStamp)
                    guard candidateTime <= presentationSecs + 0.005 else { break }
                    lastFrameToRender = candidate
                    self.lastRenderedPTS = candidate.presentationTimeStamp
                    self.processedFrameCacheStart += 1
                    drained += 1
                }
                guard lastFrameToRender != nil else { return }
            } else {
                while self.processedFrameCacheStart < self.processedFrameCache.count,
                      self.processedFrameCache[self.processedFrameCacheStart].presentationTimeStamp <= self.lastRenderedPTS {
                    self.processedFrameCacheStart += 1
                    drained += 1
                }
                guard self.processedFrameCacheStart < self.processedFrameCache.count else { return }
                let firstFrame = self.processedFrameCache[self.processedFrameCacheStart]
                let frameTime = CMTimeGetSeconds(firstFrame.presentationTimeStamp)
                guard frameTime <= presentationSecs + 0.005 else { return }
                lastFrameToRender = firstFrame
                self.lastRenderedPTS = firstFrame.presentationTimeStamp
                drained = 1
                self.processedFrameCacheStart += 1
            }
            self.compactProcessedFrameCacheIfNeeded()
        }
        
        if let frame = lastFrameToRender {
            #if os(macOS)
            if !self.pipelinePresentationReady {
                self.pipelinePresentationReady = true
                self.setNativeVideoEnabled(false)
            }
            #endif
            self.renderer.render(pixelBuffer: frame.buffer, isInterpolated: frame.isInterpolated)
            self.recordRenderedTimeline(at: frame.presentationTimeStamp, wallTime: now)
            self.enhancedAudioPlayer?.frameRendered(at: frame.presentationTimeStamp)
            lastPresentationWall = now
            // Only one frame is visible after a display-link tick. Any
            // additional drained frames were skipped and are counted as
            // drops below; they must not inflate the displayed FPS.
            presentedFramesCount += 1
            diagnosticPresentedFramesCount += 1
            if frame.isInterpolated {
                diagnosticPresentedInterpolatedCount += 1
            } else {
                diagnosticPresentedSourceCount += 1
            }
            self.publishCurrentTime(min(currentSecs, duration))
            if drained > 1 {
                self.pendingDroppedFrames += drained - 1
                self.publishProcessingDiagnostics()
            }
        }
        
        // Stats calculations
        let statsNow = DispatchTime.now()
        let elapsedFPSTime = elapsedUptimeSeconds(since: fpsTimer, until: statsNow)
        if elapsedFPSTime >= 1.0 {
            let measuredRate = Double(presentedFramesCount) / elapsedFPSTime
            self.fps = measuredRate
            let measurementAge = elapsedUptimeSeconds(since: displayRateMeasurementStart, until: statsNow)
            // Ignore startup/reconfiguration warm-up, then retain a short
            // rolling window so the metric reflects recent playback quality.
            if measurementAge >= 2.0 {
                displayRateSamples.append(measuredRate)
                if displayRateSamples.count > 5 {
                    displayRateSamples.removeFirst(displayRateSamples.count - 5)
                }
                let sortedRates = displayRateSamples.sorted()
                let lowIndex = max(0, Int(ceil(Double(sortedRates.count) * 0.01)) - 1)
                self.displayRate1PercentLow = sortedRates[lowIndex]
            } else {
                self.displayRate1PercentLow = measuredRate
            }
            presentedFramesCount = 0
            fpsTimer = statsNow
        }
        
        let diagElapsed = elapsedUptimeSeconds(since: diagTimer, until: now)
        if diagElapsed >= 5.0 {
            let curRate = player.rate
            let curFPS = self.fps
            var firstFrame: VTFrame? = nil
            var cacheCount = 0
            var cacheBytes = 0
            self.lockCache {
                if self.processedFrameCacheStart < self.processedFrameCache.count {
                    firstFrame = self.processedFrameCache[self.processedFrameCacheStart]
                }
                cacheCount = max(0, self.processedFrameCache.count - self.processedFrameCacheStart)
                cacheBytes = self.processedFrameCacheByteUsage
            }
            
            let produced = producedFramesCount
            let callbacks = displayLinkTickCount
            let presented = diagnosticPresentedFramesCount
            let interpolated = diagnosticPresentedInterpolatedCount
            let source = diagnosticPresentedSourceCount
            let timingSamples = max(1, producerTimingSampleCount)
            let decodeWait = producerDecodeWaitMilliseconds / Double(timingSamples)
            let cacheAdmission = producerCacheAdmissionMilliseconds / Double(timingSamples)
            let cacheInsertion = producerCacheInsertionMilliseconds / Double(timingSamples)
            if let first = firstFrame {
                let ft = CMTimeGetSeconds(first.presentationTimeStamp)
                NSLog("DIAG: cache=\(cacheCount) currentSecs=\(String(format: "%.3f", currentSecs)) nextPTS=\(String(format: "%.3f", ft)) rate=\(curRate) produced5s=\(produced) callbacks5s=\(callbacks) presented5s=\(presented) interp5s=\(interpolated) source5s=\(source) rendered=\(curFPS)")
            } else {
                NSLog("DIAG: cache=0 currentSecs=\(String(format: "%.3f", currentSecs)) rate=\(curRate) produced5s=\(produced) callbacks5s=\(callbacks) presented5s=\(presented) interp5s=\(interpolated) source5s=\(source) rendered=\(curFPS)")
            }
            NSLog("PERF: cacheMB=\(cacheBytes / (1024 * 1024)) decodeWaitMs=\(String(format: "%.2f", decodeWait)) cacheWaitMs=\(String(format: "%.2f", cacheAdmission)) cacheInsertMs=\(String(format: "%.2f", cacheInsertion)) samples=\(producerTimingSampleCount)")
            producedFramesCount = 0
            displayLinkTickCount = 0
            diagnosticPresentedFramesCount = 0
            diagnosticPresentedInterpolatedCount = 0
            diagnosticPresentedSourceCount = 0
            resetProducerTiming()
            diagTimer = now
        }
    }

    @objc func caDisplayLinkTick() {
        self.tickDisplayLink()
    }

    /// Pauses/stops playback entirely.
    func stop() {
        stopEnhancedAudioPlayback()
        inactivityTask?.cancel()
        inactivityTask = nil
        #if os(macOS)
        pipelinePresentationReady = false
        renderer.setRenderingActive(false)
        setNativeVideoEnabled(false)
        stopDisplayLinkIfNeeded()
        #endif
        pipelineRestartTask?.cancel()
        pipelineRestartTask = nil
        playbackGeneration += 1
        seekGeneration &+= 1
        if self.currentTime > 0 {
            self.saveProgress()
        }
        saveVideoSettings()
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        let producer = producerTask
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        endActiveCoordinator(after: producer)
        #if os(macOS)
        stopDisplayLinkIfNeeded()
        #else
        if let link = displayLink {
            link.invalidate()
            self.displayLink = nil
        }
        #endif
        if let scoped = securityScopedURL {
            scoped.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
        audioSyncTask?.cancel()
        audioSyncTask = nil
        audioSyncLatency = 0
        pipelineRestartAnchorPTS = nil
        lastRenderedPTS = .zero
        lockCache { clearProcessedFrameCache() }
        
        if let observer = playerItemObserver {
            NotificationCenter.default.removeObserver(observer)
            playerItemObserver = nil
        }
        if let observer = timeJumpedObserver {
            NotificationCenter.default.removeObserver(observer)
            timeJumpedObserver = nil
        }
        rateObserver?.invalidate()
        rateObserver = nil
        player?.pause()
        player = nil
        #if os(iOS)
        clearNowPlayingInfo()
        #endif
        
        self.isPlaying = false
        self.isPaused = false
        self.isBuffering = false
        self.currentTime = 0.0
        self.lastPublishedCurrentTime = -Double.infinity
        self.duration = 0.0
        self.fps = 0.0
        self.displayRate1PercentLow = 0.0
        self.presentedFramesCount = 0
        self.diagnosticPresentedFramesCount = 0
        self.diagnosticPresentedInterpolatedCount = 0
        self.diagnosticPresentedSourceCount = 0
        self.producedFramesCount = 0
        self.displayLinkTickCount = 0
        self.displayRateSamples.removeAll(keepingCapacity: true)
        self.displayRateMeasurementStart = .now()
        self.frameProcessingTime = 0.0
        self.aneUsagePercent = 0.0
        self.srInitializationError = nil
        self.isInitializingPipeline = false
        self.enhancementsPendingRestart = false
        self.renderer.clear()
        self.userActivityDetected()
    }

}
