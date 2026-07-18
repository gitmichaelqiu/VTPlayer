import SwiftUI
import AVFoundation
import VideoToolbox
import CoreVideo

extension VTPlayerViewModel {
    /// Updates coordinator when features are toggled without changing playback state.
    func updateEnhancements() {
        validateEnhancementSelections()
        #if os(macOS)
        setNativeVideoEnabled(!isPipelineActive)
        #endif
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

        player.rate = Float(self.playbackSpeed)

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
        if disabledSelection {
            srInitializationError = "Selected super-resolution mode is unavailable for this video on this device."
        }
    }
    
    /// Pauses player
    func pause() {
        guard let player = player else { return }
        player.pause()
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
        Task {
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
        // Keep audio explicitly enabled across pipeline restarts. AVPlayer
        // owns the audio clock even while native video is hidden.
        for track in tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = true
        }
    }
    #endif

    func stopPlaybackLoopOnly() {
        #if os(macOS)
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
        presentedFramesCount = 0
        diagnosticPresentedFramesCount = 0
        diagnosticPresentedInterpolatedCount = 0
        diagnosticPresentedSourceCount = 0
        producedFramesCount = 0
        displayLinkTickCount = 0
        displayRateSamples.removeAll(keepingCapacity: true)
        displayRate1PercentLow = 0
        displayRateMeasurementStart = .now()
        isBuffering = false
        lockCache { clearProcessedFrameCache() }
    }

    /// Serializes enhancement restarts. VideoToolbox sessions cannot safely be
    /// initialized while the previous producer still owns in-flight frames.
    func startPlaybackLoop() {
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

    /// Returns the supported source-resolution tiers for the established
    /// macOS temporal-first SR2 + FI2 path, ordered from cadence-safe to
    /// higher-detail. The processor is restarted only between source frames
    /// when this selection changes.
    func resolveAdaptiveSRFIInputSize() -> CGSize? {
        #if os(macOS)
        guard superResolutionLevel == 2,
              frameInterpolationLevel == 2,
              videoWidth > 0,
              videoHeight > 0,
              (videoWidth > 1280 || videoHeight > 720) else {
            adaptiveSRFITiers.removeAll(keepingCapacity: true)
            adaptiveSRFITierIndex = 0
            return nil
        }

        func alignedDimension(_ value: Double, maximum: Int) -> Int {
            let rounded = Int(ceil(value / 16.0) * 16.0)
            return min(maximum, max(2, rounded & ~1))
        }

        var tiers: [CGSize] = []
        for (maxWidth, maxHeight) in [(640.0, 360.0), (960.0, 540.0)] {
            let scale = min(1.0, maxWidth / Double(videoWidth), maxHeight / Double(videoHeight))
            let width = alignedDimension(Double(videoWidth) * scale, maximum: Int(maxWidth))
            let height = alignedDimension(Double(videoHeight) * scale, maximum: Int(maxHeight))
            guard width > 0, height > 0,
                  VTLowLatencySuperResolutionScalerConfiguration
                    .supportedScaleFactors(frameWidth: width, frameHeight: height)
                    .contains(2.0),
                  VTLowLatencyFrameInterpolationConfiguration(
                    frameWidth: width,
                    frameHeight: height,
                    numberOfInterpolatedFrames: 1
                  ) != nil else {
                continue
            }
            let tier = CGSize(width: width, height: height)
            if !tiers.contains(tier) {
                tiers.append(tier)
            }
        }

        if tiers != adaptiveSRFITiers {
            adaptiveSRFITiers = tiers
            adaptiveSRFITierIndex = 0
            adaptiveSRFIDeadlineMisses = 0
            adaptiveSRFIHeadroomFrames = 0
            adaptiveSRFICacheStarvations = 0
            adaptiveSRFIHasPresentedFrame = false
        }
        guard !tiers.isEmpty else { return nil }
        adaptiveSRFITierIndex = min(adaptiveSRFITierIndex, tiers.count - 1)
        return tiers[adaptiveSRFITierIndex]
        #else
        return nil
        #endif
    }

    /// Updates the adaptive controller after a complete source-frame process.
    /// Returning a reason asks the caller to serialize a normal pipeline
    /// restart; no coordinator is changed while it owns a frame.
    func recordAdaptiveSRFIProcessing(
        processingMilliseconds: Double,
        sourceFrameBudgetMilliseconds: Double
    ) -> String? {
        #if os(macOS)
        guard adaptiveSRFITiers.count > 1,
              sourceFrameBudgetMilliseconds > 0 else { return nil }

        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - adaptiveSRFILastTransition.uptimeNanoseconds) / 1_000_000_000.0
        guard elapsed >= 8.0 else { return nil }

        let cacheDepth = lockCache {
            max(0, processedFrameCache.count - processedFrameCacheStart)
        }
        if processingMilliseconds > sourceFrameBudgetMilliseconds * 0.90 {
            adaptiveSRFIDeadlineMisses += 1
        } else {
            adaptiveSRFIDeadlineMisses = 0
        }
        if processingMilliseconds < sourceFrameBudgetMilliseconds * 0.55, cacheDepth >= 2 {
            adaptiveSRFIHeadroomFrames += 1
        } else {
            adaptiveSRFIHeadroomFrames = 0
        }

        let shouldDemote = adaptiveSRFITierIndex > 0 &&
            (adaptiveSRFIDeadlineMisses >= 8 || adaptiveSRFICacheStarvations >= 6)
        if shouldDemote {
            adaptiveSRFITierIndex -= 1
            let reason = adaptiveSRFIDeadlineMisses >= 8 ? "deadline misses" : "cache starvation"
            adaptiveSRFIDeadlineMisses = 0
            adaptiveSRFIHeadroomFrames = 0
            adaptiveSRFICacheStarvations = 0
            adaptiveSRFIHasPresentedFrame = false
            adaptiveSRFILastTransition = now
            return "demoting to \(Int(adaptiveSRFITiers[adaptiveSRFITierIndex].width))x\(Int(adaptiveSRFITiers[adaptiveSRFITierIndex].height)) after \(reason)"
        }
        if adaptiveSRFITierIndex + 1 < adaptiveSRFITiers.count,
           adaptiveSRFIHeadroomFrames >= 180 {
            adaptiveSRFITierIndex += 1
            adaptiveSRFIDeadlineMisses = 0
            adaptiveSRFIHeadroomFrames = 0
            adaptiveSRFICacheStarvations = 0
            adaptiveSRFIHasPresentedFrame = false
            adaptiveSRFILastTransition = now
            return "promoting to \(Int(adaptiveSRFITiers[adaptiveSRFITierIndex].width))x\(Int(adaptiveSRFITiers[adaptiveSRFITierIndex].height)) after sustained headroom"
        }
        #endif
        return nil
    }

    func recordAdaptiveSRFICacheStarvation() {
        #if os(macOS)
        guard adaptiveSRFIHasPresentedFrame, adaptiveSRFITierIndex > 0 else { return }
        adaptiveSRFICacheStarvations += 1
        #endif
    }

    private func startPlaybackLoopNow() {
        let shouldResumePlayback = isPlaying && !isPaused
        #if os(macOS)
        setNativeVideoEnabled(false)
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
        let adaptiveFISize: CGSize? = resolveAdaptiveSRFIInputSize() ?? {
            guard frameInterpolationLevel > 0 else { return nil }
            let combinedMode = superResolutionLevel == 2 && frameInterpolationLevel == 2
            guard combinedMode || videoWidth > 1280 || videoHeight > 720 else { return nil }
            // Combined 2x SR + 2x FI is the heaviest real-time mode. When
            // possible, feed it a smaller source so the processor has enough
            // headroom to produce every output phase on time. Keep the normal
            // FI cap for pure interpolation.
            if combinedMode {
                // Probe the actual temporal-first configuration. A combined
                // FI+spatial initializer may accept 480×270 while the pure
                // FI configuration used by the stable sequential path
                // rejects it at processing time on this Mac.
                func alignedDimension(_ value: Double, maximum: Int) -> Int {
                    // VideoToolbox's SR/FI implementations commonly require
                    // macroblock-friendly heights. Flooring 266.7 to 266
                    // made the 960x400 path fail, while the equivalent 272
                    // pixel input is supported. Round up within the probe
                    // bound so we preserve aspect ratio without selecting a
                    // known-invalid odd-size surface.
                    let rounded = Int(ceil(value / 16.0) * 16.0)
                    return min(maximum, max(2, rounded & ~1))
                }
                for (maxWidth, maxHeight) in [(640.0, 360.0), (960.0, 540.0)] {
                    let scale = min(1.0, maxWidth / Double(videoWidth), maxHeight / Double(videoHeight))
                    let candidateWidth = alignedDimension(Double(videoWidth) * scale, maximum: Int(maxWidth))
                    let candidateHeight = alignedDimension(Double(videoHeight) * scale, maximum: Int(maxHeight))
                    guard candidateWidth > 0, candidateHeight > 0 else { continue }
                    if VTLowLatencySuperResolutionScalerConfiguration
                        .supportedScaleFactors(frameWidth: candidateWidth, frameHeight: candidateHeight)
                        .contains(2.0),
                       VTLowLatencyFrameInterpolationConfiguration(
                           frameWidth: candidateWidth,
                           frameHeight: candidateHeight,
                           numberOfInterpolatedFrames: 1
                       ) != nil {
                        return CGSize(width: candidateWidth, height: candidateHeight)
                    }
                }
                return nil
            }
            let scale = min(1280.0 / Double(videoWidth), 720.0 / Double(videoHeight))
            let candidate = CGSize(width: ceil(Double(videoWidth) * scale / 16) * 16,
                                   height: ceil(Double(videoHeight) * scale / 16) * 16)
            return candidate
        }()
        let pipelineWidth = Int(adaptiveFISize?.width ?? CGFloat(videoWidth))
        let pipelineHeight = Int(adaptiveFISize?.height ?? CGFloat(videoHeight))
        let targetFrameRate = sourceFrameRate * (frameInterpolationLevel > 0 ? Double(frameInterpolationLevel) : 1.0)
        NSLog("PIPELINE: source=\(videoWidth)x\(videoHeight) input=\(pipelineWidth)x\(pipelineHeight) fi=\(frameInterpolationLevel)x sr=\(superResolutionLevel)x qsr=\(qualitySuperResolutionScaleFactor)x sourceFPS=\(String(format: "%.3f", sourceFrameRate)) targetFPS=\(String(format: "%.3f", targetFrameRate))")

        lockCache { clearProcessedFrameCache() }
        if let player = player {
            let adjusted = CMTimeSubtract(player.currentTime(), frameDuration)
            lastPulledTime = adjusted > .zero ? adjusted : .zero
            lastRenderedPTS = player.currentTime()
            resetPresentationClock(at: CMTimeGetSeconds(player.currentTime()))
        } else {
            lastPulledTime = .zero
            lastRenderedPTS = .zero
            resetPresentationClock(at: 0)
        }
        audioSyncLatency = 0

        // Re-assert player rate so audio keeps playing after a pipeline
        // restart triggered by updateEnhancements().  Without this, a
        // rate that dropped to 0 (AVPlayer internal stall) stays silent
        // because the old audioSyncTask was already cancelled and the new
        // one won't check for 200 ms.
        if let player = player, !isPaused {
            player.rate = Float(playbackSpeed)
        }

        let srLevel = self.superResolutionLevel
        let fiLevel = self.frameInterpolationLevel
        let highQuality = self.useHighQualityDownsampling
        let realTime = self.useRealTimePriority
        let qualitySR = self.qualitySuperResolutionScaleFactor
        let mbStrength = self.motionBlurStrength
        let dnStrength = self.denoiseStrength
        let qualPrior = self.qualityPrioritization

        producerTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            defer {
                // A replacement loop has a newer generation. Never let a
                // cancelled predecessor erase its producer handle.
                if self.playbackGeneration == gen {
                    self.producerTask = nil
                }
            }

            // Check Quality SR model availability before starting (macOS only)
            var effectiveQualitySR = qualitySR
            var effectiveSRLevel = srLevel
            
            #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
            @MainActor func fallBackFromQualitySR(preserveSelection: Bool = false) {
                effectiveQualitySR = 0
                let requestedFallback = qualitySR == 4 ? 4 : 2
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
                    await self.modelManager.checkStatus(for: checkConfig)
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
                let supportedScales = VTLowLatencySuperResolutionScalerConfiguration
                    .supportedScaleFactors(frameWidth: videoWidth, frameHeight: videoHeight)
                if !supportedScales.contains(2.0) {
                    self.srInitializationError = "Low Latency SR does not support \(videoWidth)x\(videoHeight) on this device; enhancement disabled."
                    effectiveSRLevel = 0
                    print("Low Latency SR unavailable for \(videoWidth)x\(videoHeight): \(supportedScales)")
                }
            }
            #endif
            #endif
            var coordinator = VTFrameProcessorCoordinator(
                superResolutionLevel: effectiveSRLevel,
                frameInterpolationLevel: fiLevel,
                useHighQualityDownsampling: highQuality,
                useRealTimePriority: realTime,
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

            do {
                if (effectiveSRLevel > 0 || effectiveQualitySR > 0 || (srLevel == 0 && qualitySR == 0)),
                   self.srInitializationError == nil {
                    self.srInitializationError = nil
                }
                try await coordinator.startSession(width: pipelineWidth, height: pipelineHeight)
            } catch {
                guard gen == self.playbackGeneration else { return }
                await coordinator.endSession()

                // The combined VideoToolbox processor is capability- and
                // resolution-dependent.  Its configuration initializer can
                // succeed while session creation still rejects the actual
                // pixel-buffer requirements.  Do not reset playback to time
                // zero in that case: retry as FI-only at the same adaptive
                // input size and make the fallback visible in diagnostics.
                if effectiveSRLevel == 2 && fiLevel == 2 && effectiveQualitySR == 0 {
                    let message = "Combined 2x SR + 2x FI unavailable at \(pipelineWidth)x\(pipelineHeight); using FI-only."
                    self.srInitializationError = message
                    print("Failed to initialize combined SR/FI session: \(error.localizedDescription). Retrying FI-only.")

                    effectiveSRLevel = 0
                    self.superResolutionLevel = 0
                    coordinator = VTFrameProcessorCoordinator(
                        superResolutionLevel: 0,
                        frameInterpolationLevel: fiLevel,
                        useHighQualityDownsampling: highQuality,
                        useRealTimePriority: realTime,
                        qualitySuperResolutionScaleFactor: 0,
                        motionBlurStrength: mbStrength,
                        denoiseStrength: dnStrength,
                        qualityPrioritization: qualPrior
                    )
                    self.activeCoordinator = coordinator
                    do {
                        try await coordinator.startSession(width: pipelineWidth, height: pipelineHeight)
                    } catch {
                        self.srInitializationError = "FI fallback unavailable: \(error.localizedDescription)"
                        print("Failed to initialize FI fallback session: \(error.localizedDescription)")
                        self.activeCoordinator = nil
                        await coordinator.endSession()
                        self.stop()
                        return
                    }
                } else {
                    self.srInitializationError = error.localizedDescription
                    print("Failed to initialize coordinator session: \(error.localizedDescription)")
                    self.activeCoordinator = nil
                    self.stop()
                    return
                }
            }

            // Re-sync lastPulledTime after potentially slow coordinator setup
            // and resume the player from the same position.
            if let player = self.player {
                let resumeTime = player.currentTime()
                self.lastPulledTime = resumeTime
                self.lastRenderedPTS = resumeTime
                self.resetPresentationClock(at: CMTimeGetSeconds(resumeTime))
                await player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
                let shouldResume = shouldResumePlayback && gen == self.playbackGeneration
                self.isInitializingPipeline = false
                if shouldResume {
                    self.isPlaying = true
                    self.isPaused = false
                    player.rate = wasRate != 0 ? wasRate : Float(self.playbackSpeed)
                } else {
                    player.pause()
                }
            } else {
                self.isInitializingPipeline = false
            }

            // Create VTFrameSequence to decode frames faster-than-real-time
            guard let videoURL = self.videoURL else {
                self.activeCoordinator = nil
                await coordinator.endSession()
                return
            }
            var iteratorStartTime = self.lastPulledTime
            let frameSequence = VTFrameSequence(url: videoURL, startTime: iteratorStartTime, outputSize: adaptiveFISize)
            var frameIterator = frameSequence.makeAsyncIterator()
            var combinedProcessFallbackAttempted = false

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
                    iteratorStartTime = self.lastPulledTime
                    let newSequence = VTFrameSequence(url: videoURL, startTime: iteratorStartTime, outputSize: adaptiveFISize)
                    frameIterator = newSequence.makeAsyncIterator()
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
                do {
                    guard let next = try await frameIterator.next() else {
                        break  // EOF
                    }
                    vtFrame = next
                } catch {
                    print("VTFrameSequence error: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                // Drop late frames to maintain real-time audio-video synchronization.
                // Do not drop frames if the cache is completely empty (e.g. after seek or startup),
                // to avoid getting stuck in a dropping loop before the rendering loop recovers.
                if let player = self.player, !self.isPaused, player.rate > 0 {
                    let currentSecs = self.presentationClockSeconds(
                        playerSeconds: CMTimeGetSeconds(player.currentTime())
                    )
                    let frameSecs = CMTimeGetSeconds(vtFrame.presentationTimeStamp)
                    // If the frame is late by more than 100ms, skip processing it
                    let isEmpty = self.lockCache {
                        self.processedFrameCacheStart >= self.processedFrameCache.count
                    }
                    if !isEmpty && frameSecs < currentSecs - 0.10 {
                        self.pendingDroppedFrames += 1
                        self.publishProcessingDiagnostics()
                        continue
                    }
                }

                // Process through the VideoToolbox pipeline
                let processStart = DispatchTime.now()
                do {
                    let outputFrames = try await coordinator.processFrame(vtFrame)
                    let processEnd = DispatchTime.now()

                    guard gen == self.playbackGeneration else { break }

                    self.publishProcessingDiagnostics(
                        Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000.0
                    )
                    let processingMilliseconds = Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000.0
                    let sourceFrameBudgetMilliseconds = sourceFPS > 0 ? 1_000.0 / sourceFPS : 0
                    if frameInterpolationLevel > 0,
                       processingMilliseconds > sourceFrameBudgetMilliseconds {
                        let processingText = String(format: "%.1f", processingMilliseconds)
                        let budgetText = String(format: "%.1f", sourceFrameBudgetMilliseconds)
                        print("PERF: FI deadline miss processing=\(processingText)ms budget=\(budgetText)ms outputs=\(outputFrames.count) sr=\(effectiveSRLevel) qsr=\(effectiveQualitySR) size=\(pipelineWidth)x\(pipelineHeight)")
                    }

                    if outputFrames.count < 2 && self.frameInterpolationLevel > 0 {
                        print("⚠️ FI: expected >=2 output frames, got \(outputFrames.count) for frame at \(CMTimeGetSeconds(vtFrame.presentationTimeStamp))")
                    }

                    // Insert output frames in PTS-sorted order using binary
                    // search.  The cache is already sorted and output frames
                    // arrive roughly in order, so this is O(log n) per frame
                    // instead of re-sorting the entire array every time.
                    self.lockCache {
                        for outFrame in outputFrames {
                            let pts = outFrame.presentationTimeStamp
                            var lo = self.processedFrameCacheStart
                            var hi = self.processedFrameCache.count
                            while lo < hi {
                                let mid = (lo + hi) / 2
                                if self.processedFrameCache[mid].presentationTimeStamp < pts {
                                    lo = mid + 1
                                } else {
                                    hi = mid
                                }
                            }
                            self.processedFrameCache.insert(outFrame, at: lo)
                        }
                        self.compactProcessedFrameCacheIfNeeded()
                    }
                    self.producedFramesCount += outputFrames.count

                    // A completed source frame is the only safe point to
                    // retier: startPlaybackLoop() serializes teardown with
                    // this producer before creating the replacement session.
                    if let transition = self.recordAdaptiveSRFIProcessing(
                        processingMilliseconds: processingMilliseconds,
                        sourceFrameBudgetMilliseconds: sourceFrameBudgetMilliseconds
                    ) {
                        let processingText = String(format: "%.1f", processingMilliseconds)
                        let budgetText = String(format: "%.1f", sourceFrameBudgetMilliseconds)
                        NSLog("PIPELINE ADAPTIVE SR/FI: \(transition); cache=\(self.frameCacheCount) processing=\(processingText)ms budget=\(budgetText)ms")
                        self.startPlaybackLoop()
                        break
                    }
                } catch {
                    guard gen == self.playbackGeneration else { break }
                    if effectiveSRLevel == 2 && fiLevel == 2 && effectiveQualitySR == 0 && !combinedProcessFallbackAttempted {
                        combinedProcessFallbackAttempted = true
                        self.superResolutionLevel = 0
                        self.srInitializationError = "Combined 2x SR + 2x FI failed during processing (\(error.localizedDescription)); using FI-only."
                        print("⚠️ Combined SR/FI processing failed: \(error.localizedDescription). Restarting as FI-only.")
                        self.startPlaybackLoop()
                        break
                    }
                    print("⚠️ Pipeline processing error: \(error) — preserving source frame; fi=\(fiLevel) sr=\(effectiveSRLevel) qsr=\(effectiveQualitySR) size=\(pipelineWidth)x\(pipelineHeight)")
                    self.lockCache { self.processedFrameCache.append(vtFrame) }
                    self.producedFramesCount += 1
                }
            }

            await coordinator.endSession()
            if self.playbackGeneration == gen {
                self.activeCoordinator = nil
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

                // AVPlayer may stop playback (rate → 0) if its audio decoder fails
                // on certain file formats. Periodically re-assert the desired rate
                // to kickstart the decoder. This does NOT pause — it only recovers.
                if player.rate == 0 && self.isPlaying && !self.isPaused && !self.isInitializingPipeline {
                    player.rate = Float(self.playbackSpeed)
                }
            }
        }
    }

    func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }

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
        #endif
        #if !os(macOS)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
        #endif
    }
    #endif

    @MainActor
    func tickDisplayLink() {
        guard isPlaying && !isPaused, let player = self.player else { return }
        displayLinkTickCount += 1
        
        let currentTime = player.currentTime()
        let observedSecs = CMTimeGetSeconds(currentTime)
        let currentSecs = presentationClockSeconds(playerSeconds: observedSecs)
        let presentationSecs = currentSecs - interpolationPresentationDelay
        
        var lastFrameToRender: VTFrame? = nil
        var drained = 0
        let now = DispatchTime.now()
        let wallElapsed = Double(now.uptimeNanoseconds - lastPresentationWall.uptimeNanoseconds) / 1_000_000_000.0
        // MTKView callbacks may arrive around 48 Hz on a 60 Hz display.
        // Requiring 90% of the 33 ms FI2 interval then presents every other
        // callback (~24 Hz). A bounded 60% threshold lets the scheduler
        // alternate one- and two-callback gaps, converging on the requested
        // 30 Hz without allowing an unbounded burst.
        let canForceNextFrame = wallElapsed >= outputPresentationInterval * 0.6
        let useWallClockPacing = frameInterpolationLevel > 0 && sourceFrameRate > 0
        
        self.lockCache {
            if useWallClockPacing {
                // FI output has a fixed cadence independent of the display
                // callback cadence. Present at most one queued frame per
                // wall-clock deadline; draining every PTS-eligible frame can
                // turn 2x output into source-rate output when callbacks are
                // delivered at an uneven ~45 Hz cadence.
                guard canForceNextFrame else { return }

                // Discard frames that are already behind the last visible
                // timestamp, but never consume two eligible frames in one
                // display callback.
                while self.processedFrameCacheStart < self.processedFrameCache.count,
                      self.processedFrameCache[self.processedFrameCacheStart].presentationTimeStamp <= self.lastRenderedPTS {
                    self.processedFrameCacheStart += 1
                    drained += 1
                }

                guard self.processedFrameCacheStart < self.processedFrameCache.count else { return }
                let firstFrame = self.processedFrameCache[self.processedFrameCacheStart]
                let frameTime = CMTimeGetSeconds(firstFrame.presentationTimeStamp)
                // Keep audio/video bounded: a frame may lead the audio clock
                // by at most 80 ms while the wall-clock cadence is restored.
                guard frameTime <= presentationSecs + 0.08 else { return }
                lastFrameToRender = firstFrame
                self.lastRenderedPTS = firstFrame.presentationTimeStamp
                drained += 1
                self.processedFrameCacheStart += 1
            } else {
                while self.processedFrameCacheStart < self.processedFrameCache.count {
                    let firstFrame = self.processedFrameCache[self.processedFrameCacheStart]
                    let frameTime = CMTimeGetSeconds(firstFrame.presentationTimeStamp)
                    if frameTime > presentationSecs + 0.005 {
                        break
                    }

                    lastFrameToRender = firstFrame
                    self.lastRenderedPTS = firstFrame.presentationTimeStamp
                    drained += 1
                    self.processedFrameCacheStart += 1
                }
            }
            self.compactProcessedFrameCacheIfNeeded()
        }
        
        if let frame = lastFrameToRender {
            self.renderer.render(pixelBuffer: frame.buffer, isInterpolated: frame.isInterpolated)
            #if os(macOS)
            self.adaptiveSRFIHasPresentedFrame = true
            #endif
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
        } else {
            // Do not restart from the display callback. The counter is
            // consumed after the next completed source frame so coordinator
            // teardown remains serialized with the producer.
            self.recordAdaptiveSRFICacheStarvation()
        }
        
        // Stats calculations
        let statsNow = DispatchTime.now()
        let elapsedFPSTime = Double(statsNow.uptimeNanoseconds - fpsTimer.uptimeNanoseconds) / 1_000_000_000.0
        if elapsedFPSTime >= 1.0 {
            let measuredRate = Double(presentedFramesCount) / elapsedFPSTime
            self.fps = measuredRate
            let measurementAge = Double(statsNow.uptimeNanoseconds - displayRateMeasurementStart.uptimeNanoseconds) / 1_000_000_000.0
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
        
        let diagElapsed = Double(now.uptimeNanoseconds - diagTimer.uptimeNanoseconds) / 1_000_000_000.0
        if diagElapsed >= 5.0 {
            let curRate = player.rate
            let curFPS = self.fps
            var firstFrame: VTFrame? = nil
            var cacheCount = 0
            self.lockCache {
                if self.processedFrameCacheStart < self.processedFrameCache.count {
                    firstFrame = self.processedFrameCache[self.processedFrameCacheStart]
                }
                cacheCount = max(0, self.processedFrameCache.count - self.processedFrameCacheStart)
            }
            
            let produced = producedFramesCount
            let callbacks = displayLinkTickCount
            let presented = diagnosticPresentedFramesCount
            let interpolated = diagnosticPresentedInterpolatedCount
            let source = diagnosticPresentedSourceCount
            if let first = firstFrame {
                let ft = CMTimeGetSeconds(first.presentationTimeStamp)
                NSLog("DIAG: cache=\(cacheCount) currentSecs=\(String(format: "%.3f", currentSecs)) nextPTS=\(String(format: "%.3f", ft)) rate=\(curRate) produced5s=\(produced) callbacks5s=\(callbacks) presented5s=\(presented) interp5s=\(interpolated) source5s=\(source) rendered=\(curFPS)")
            } else {
                NSLog("DIAG: cache=0 currentSecs=\(String(format: "%.3f", currentSecs)) rate=\(curRate) produced5s=\(produced) callbacks5s=\(callbacks) presented5s=\(presented) interp5s=\(interpolated) source5s=\(source) rendered=\(curFPS)")
            }
            producedFramesCount = 0
            displayLinkTickCount = 0
            diagnosticPresentedFramesCount = 0
            diagnosticPresentedInterpolatedCount = 0
            diagnosticPresentedSourceCount = 0
            diagTimer = now
        }
    }

    @objc func caDisplayLinkTick() {
        self.tickDisplayLink()
    }

    /// Pauses/stops playback entirely.
    func stop() {
        #if os(macOS)
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
        #if os(iOS)
        self.tempLocalURL = nil
        #endif
        if let scoped = securityScopedURL {
            scoped.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
        audioSyncTask?.cancel()
        audioSyncTask = nil
        audioSyncLatency = 0
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
