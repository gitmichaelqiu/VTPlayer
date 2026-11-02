import AVFoundation
import CoreVideo
import Foundation

extension VTPlayerViewModel {
    /// Seeks to a specific timestamp in seconds.
    func seek(to seconds: Double) {
        #if os(macOS)
        if macDedicatedMetalDisplayTickDriver != nil {
            stopDisplayLinkIfNeeded()
        }
        #endif
        ignoreAutomaticTimeJumpsUntil = nil
        pendingResumePTS = nil
        pendingExplicitSeekPTS = CMTime(seconds: seconds, preferredTimescale: 600)
        seekGeneration &+= 1
        let requestGeneration = seekGeneration
        self.lastPublishedCurrentTime = seconds
        self.currentTime = seconds
        self.saveProgress()
        self.lastRenderedPTS = .zero
        resetPresentationClock(at: seconds)
        lockCache { self.clearProcessedFrameCache() }
        self.lastPulledTime = CMTime(seconds: seconds, preferredTimescale: 600)
        Task { @MainActor in
            await self.activeCoordinator?.clearHistory()
        }
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let targetRate = Float(self.playbackSpeed)
        let shouldPlay = self.isPlaying && !self.isPaused
        enhancedAudioPlayer?.awaitRenderedFrameAnchor(shouldPlay: shouldPlay)
        #if os(macOS)
        suppressNativeTimeObserverDuringSeek = true
        suppressRateObserver = true
        #endif
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            guard let self = self else { return }
            Task { @MainActor in
                guard requestGeneration == self.seekGeneration,
                      self.player === player else { return }
#if os(macOS)
                self.suppressNativeTimeObserverDuringSeek = false
                self.suppressRateObserver = false
#endif
                guard completed else { return }
                self.pendingExplicitSeekPTS = nil

                // Re-assert player rate — AVPlayer can transiently drop
                // rate to 0 during seek, causing arrow-key seeks to
                // unexpectedly pause playback.
                if shouldPlay && self.isPlaying && !self.isPaused {
                    player.rate = targetRate
                    #if os(macOS)
                    if self.fullCachePresentationQueue != nil {
                        self.startDisplayLinkIfNeeded()
                        if let url = self.videoURL {
                            self.startEnhancedPresentationGateMonitor(
                                url: url,
                                candidate: self.appliedPipelineConfiguration,
                                preparationGeneration: self.enhancedCachePreparationGeneration
                            )
                        }
                    }
                    #endif
                }
                await self.triggerSingleFrameUpdate(
                    at: time,
                    for: player,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    /// Rewinds after natural completion before building a new paused pipeline.
    func rewindAfterPlaybackEnd(for endingPlayer: AVPlayer) async {
        guard player === endingPlayer else { return }

        pause()

        let zero = CMTime.zero
        pendingResumePTS = nil
        pendingExplicitSeekPTS = zero
        seekGeneration &+= 1
        let requestGeneration = seekGeneration
        lastPublishedCurrentTime = 0
        currentTime = 0
        lastRenderedPTS = .zero
        lastPulledTime = .zero
        resetPresentationClock(at: 0)
        lockCache { clearProcessedFrameCache() }
        await activeCoordinator?.clearHistory()

        let completed = await endingPlayer.seek(
            to: zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        guard completed,
              requestGeneration == seekGeneration,
              player === endingPlayer else { return }

        pendingExplicitSeekPTS = nil
        startPlaybackLoop()
    }

    func handleTimeJump() {
        guard let player = player else { return }
        if let deadline = ignoreAutomaticTimeJumpsUntil,
           DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
            return
        }
        let currentTime = player.currentTime()
        if let pendingExplicitSeekPTS {
            let expectedSeconds = CMTimeGetSeconds(pendingExplicitSeekPTS)
            let currentSeconds = CMTimeGetSeconds(currentTime)
            guard expectedSeconds.isFinite, currentSeconds.isFinite,
                  abs(currentSeconds - expectedSeconds) <= 0.25 else {
                return
            }
            self.pendingExplicitSeekPTS = nil
            return
        } else if pendingResumePTS == nil {
            // Do not let an unsolicited AVPlayer time jump rewrite the
            // enhanced decoder timeline. Explicit seek/scrub paths register
            // their target above; startup resume is tracked separately.
            return
        }
        if let pendingResumePTS {
            let expectedSeconds = CMTimeGetSeconds(pendingResumePTS)
            let currentSeconds = CMTimeGetSeconds(currentTime)
            if expectedSeconds.isFinite, currentSeconds.isFinite,
               abs(currentSeconds - expectedSeconds) > 0.25 {
                return
            }
            self.pendingResumePTS = nil
        }
        enhancedAudioPlayer?.awaitRenderedFrameAnchor(shouldPlay: isPlaying && !isPaused)
        
        lockCache { self.clearProcessedFrameCache() }
        self.lastPulledTime = currentTime
        self.lastRenderedPTS = currentTime
        resetPresentationClock(at: CMTimeGetSeconds(currentTime))
        Task { @MainActor in
            await self.activeCoordinator?.clearHistory()
        }
        
        // If paused (e.g. scrubbing), read and draw a single frame immediately
        // at the new seek position so the screen updates in real time.
        if self.isPaused, let url = videoURL {
            let requestGeneration = seekGeneration
            Task { @MainActor in
                if let frame = await self.readSingleFrame(from: url, at: currentTime),
                   requestGeneration == self.seekGeneration, self.player === player,
                   self.isPaused {
                    self.renderer.render(pixelBuffer: frame.buffer)
                }
            }
        }
    }

    #if os(macOS)
    func beginScrub() {
        scrubPreviewTask?.cancel()
        wasPlayingBeforeScrub = isPlaying && !isPaused
        if wasPlayingBeforeScrub {
            pause()
        }
    }

    func finishScrub(to seconds: Double) {
        scrubPreviewTask?.cancel()
        scrubPreviewTask = nil
        let shouldResume = wasPlayingBeforeScrub
        wasPlayingBeforeScrub = false
        performScrub(to: seconds, shouldResume: shouldResume)
    }
    #endif

    /// Updates a scrub preview without starting a decoder seek for every
    /// slider tick. The final value is committed by finishScrub.
    func scrub(to seconds: Double) {
        #if os(macOS)
        let clampedSeconds = max(0, min(duration, seconds))
        currentTime = clampedSeconds
        scrubPreviewTask?.cancel()
        scrubPreviewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, let self else { return }
            self.performScrub(to: clampedSeconds, shouldResume: false)
        }
        #else
        performScrub(to: seconds, shouldResume: false)
        #endif
    }

    private func performScrub(to seconds: Double, shouldResume: Bool) {
        enhancedAudioPlayer?.awaitRenderedFrameAnchor(shouldPlay: shouldResume)
        ignoreAutomaticTimeJumpsUntil = nil
        pendingResumePTS = nil
        pendingExplicitSeekPTS = CMTime(seconds: seconds, preferredTimescale: 600)
        seekGeneration &+= 1
        let requestGeneration = seekGeneration
        self.lastPublishedCurrentTime = seconds
        self.currentTime = seconds
        self.saveProgress()
        self.lastRenderedPTS = .zero
        resetPresentationClock(at: seconds)
        lockCache { self.clearProcessedFrameCache() }
        self.lastPulledTime = CMTime(seconds: seconds, preferredTimescale: 600)
        Task { @MainActor in
            await self.activeCoordinator?.clearHistory()
        }
        guard let player = player else { return }
#if os(macOS)
        suppressNativeTimeObserverDuringSeek = true
        suppressRateObserver = true
#endif
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            guard let self = self else { return }
            Task { @MainActor in
                guard requestGeneration == self.seekGeneration,
                      self.player === player,
                      let url = self.videoURL else { return }
#if os(macOS)
                self.suppressNativeTimeObserverDuringSeek = false
                self.suppressRateObserver = false
#endif
                guard completed else { return }
                self.pendingExplicitSeekPTS = nil

                // Read a single frame via AVAssetReader (video track is
                // disabled on AVPlayer, so copyPixelBuffer won't work).
                if let frame = await self.readSingleFrame(from: url, at: time),
                   requestGeneration == self.seekGeneration, self.player === player,
                   self.isPaused || !self.isPlaying {
                    self.renderer.render(pixelBuffer: frame.buffer)
                }
                if shouldResume, requestGeneration == self.seekGeneration, self.player === player {
                    self.play()
                }
            }
        }
    }

    /// Seeks forward or backward by the given relative offset in seconds.
    func seekRelative(_ delta: Double) {
        let target = max(0, min(duration, currentTime + delta))
        seek(to: target)
    }

    func triggerSingleFrameUpdate(
        at time: CMTime,
        for player: AVPlayer,
        requestGeneration: UInt64
    ) async {
        guard let url = videoURL else { return }
        // Small delay to let the seek settle
        try? await Task.sleep(nanoseconds: 10_000_000)
        guard requestGeneration == seekGeneration, self.player === player,
              isPaused || !isPlaying else { return }
        if let frame = await readSingleFrame(from: url, at: time),
           requestGeneration == seekGeneration, self.player === player,
           isPaused || !isPlaying {
            self.renderer.render(pixelBuffer: frame.buffer)
        }
    }

    /// Decodes a single frame away from the main actor so seeking remains responsive.
    func readSingleFrame(from url: URL, at time: CMTime) async -> VTFrame? {
        await Task.detached(priority: .userInitiated) {
            await Self.decodeSingleFrame(from: url, at: time)
        }.value
    }

    nonisolated static func decodeSingleFrame(from url: URL, at time: CMTime) async -> VTFrame? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: time, duration: CMTime(value: 1, timescale: 30))
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        return VTFrame(
            buffer: pixelBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample)
        )
    }
    
}
