import SwiftUI
import AVFoundation
import VideoToolbox
import CoreVideo
import MetalKit
#if os(iOS)
import MediaPlayer
#endif

@MainActor
struct PlaybackPipelineSnapshot {
    let generation: UInt64
    let videoURL: URL?
    let player: AVPlayer?

    func matches(
        activeGeneration: UInt64,
        activeVideoURL: URL?,
        activePlayer: AVPlayer?
    ) -> Bool {
        generation == activeGeneration &&
            videoURL == activeVideoURL &&
            player === activePlayer
    }
}

extension VTPlayerViewModel {
    internal func startPlaybackLoopNow() {
        guard coordinatorTeardownTask == nil else {
            startPlaybackLoop()
            return
        }
        let shouldResumePlayback = isPlaying && !isPaused
        let restartAnchorPTS = pipelineRestartAnchorPTS
        let pipelineURL = videoURL
        let pipelinePlayer = player
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
        let pipelineSnapshot = PlaybackPipelineSnapshot(
            generation: gen,
            videoURL: pipelineURL,
            player: pipelinePlayer
        )
        let oldProducer = producerTask
        producerTask?.cancel()
        producerTask = nil
        #if os(macOS)
        fullCacheReaderControl = nil
        fullCachePresentationQueue = nil
        #endif
        consumerTask?.cancel()
        consumerTask = nil
        endActiveCoordinator(after: oldProducer)

        let sourceFPS = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30.0
        // AVAssetReader may begin at the first keyframe after a requested
        // restart time. Decode a short lead-in so the cache always contains
        // a frame at the presentation anchor instead of leaving a gap.
        let decodePreroll = CMTime(seconds: 4, preferredTimescale: 600)
        let pipelineWidth = videoWidth
        let pipelineHeight = videoHeight
        let configuration = appliedPipelineConfiguration
        let preparedFrameCacheKey = preparedEnhancedFrameCacheKey
        let preparedFrameCacheMode = preparedEnhancedFrameCacheMode
        let diskCache = enhancedFrameDiskCache
        let targetFrameRate = sourceFrameRate * (configuration.frameInterpolationLevel > 0 ? Double(configuration.frameInterpolationLevel) : 1.0)
        #if os(macOS)
        // Request callback headroom for near-60 fps enhanced streams. The
        // renderer still encodes only when a frame is due, and macOS clamps
        // this request to the display's supported cadence.
        renderer.preferredFramesPerSecond = configuration.frameInterpolationLevel > 0 || sourceFrameRate >= 50 ? 120 : 60
        #endif
        NSLog("PIPELINE: source=\(videoWidth)x\(videoHeight) input=\(pipelineWidth)x\(pipelineHeight) fi=\(configuration.frameInterpolationLevel)x sr=\(configuration.superResolutionLevel)x qsr=\(configuration.qualitySuperResolutionScaleFactor)x sourceFPS=\(String(format: "%.3f", sourceFrameRate)) targetFPS=\(String(format: "%.3f", targetFrameRate))")

        lockCache { clearProcessedFrameCache() }
        let restartStartTime: CMTime?
        if let player {
            var candidate = restartAnchorPTS ?? player.currentTime()
            let currentTime = player.currentTime()
            if currentTime.isValid, currentTime.seconds.isFinite,
               CMTimeCompare(currentTime, candidate) > 0 {
                candidate = currentTime
            }
            if lastRenderedPTS.isValid, lastRenderedPTS.seconds.isFinite,
               CMTimeCompare(lastRenderedPTS, candidate) > 0 {
                candidate = lastRenderedPTS
            }
            restartStartTime = candidate
        } else {
            restartStartTime = restartAnchorPTS
        }
        if let player = player {
            let startTime = restartStartTime ?? player.currentTime()
            let adjusted = CMTimeSubtract(startTime, decodePreroll)
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

        let srLevel = configuration.superResolutionLevel
        let fiLevel = configuration.frameInterpolationLevel
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
        let qualitySR = configuration.qualitySuperResolutionScaleFactor
        let mbStrength = configuration.motionBlurStrength
        let dnStrength = configuration.denoiseStrength
        let qualPrior = self.qualityPrioritization

        producerTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let preparedFrameCacheKey {
                await diskCache.beginPlayback(for: preparedFrameCacheKey)
            }
            defer {
                if let preparedFrameCacheKey {
                    Task {
                        await diskCache.endPlayback(for: preparedFrameCacheKey)
                    }
                }
            }
            var pausedForInitialization = false

            @MainActor
            func isCurrentPipeline() -> Bool {
                !Task.isCancelled &&
                    pipelineSnapshot.matches(
                        activeGeneration: self.playbackGeneration,
                        activeVideoURL: self.videoURL,
                        activePlayer: self.player
                    )
            }

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

            guard isCurrentPipeline() else { return }

            // Pause before any capability or model work suspends. A low
            // latency support probe can take long enough for native video to
            // advance before the pipeline restores its captured anchor.
            self.isInitializingPipeline = true
            let wasRate = self.player?.rate ?? 0
            self.player?.pause()
            pausedForInitialization = true

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
                guard isCurrentPipeline() else { return }
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
            guard isCurrentPipeline() else { return }
            self.activeCoordinator = coordinator

            do {
                if (effectiveSRLevel > 0 || effectiveQualitySR > 0 || (srLevel == 0 && qualitySR == 0)),
                   self.srInitializationError == nil {
                    self.srInitializationError = nil
                }
                try await coordinator.startSession(width: pipelineWidth, height: pipelineHeight)
            } catch {
                guard isCurrentPipeline() else {
                    await coordinator.endSession()
                    return
                }
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
                        guard isCurrentPipeline() else {
                            await coordinator.endSession()
                            return
                        }
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

            guard isCurrentPipeline(), let videoURL = pipelineURL else {
                if self.activeCoordinator === coordinator {
                    self.activeCoordinator = nil
                }
                await coordinator.endSession()
                return
            }

            // Re-sync after coordinator setup, then keep audio and video
            // paused until the entire safe processed-frame cache is ready.
            var waitingForFramePreroll = false
            if let player = pipelinePlayer {
                let resumeTime = restartStartTime ?? player.currentTime()
                if restartStartTime != nil {
                    _ = await player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                guard isCurrentPipeline() else {
                    await coordinator.endSession()
                    return
                }
                let readerStart = CMTimeSubtract(resumeTime, decodePreroll)
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
                    if await audioPlayer.prepare(url: videoURL, initialRate: self.playbackSpeed) {
                        guard isCurrentPipeline() else {
                            audioPlayer.stop()
                            await coordinator.endSession()
                            return
                        }
                        audioPlayer.setVolume(Float(self.volume))
                        self.enhancedAudioPlayer = audioPlayer
                        self.setPrimaryAudioMuted(true)
                    }
                } else {
                    player.pause()
                    if resumeTime <= .zero, let firstFrame = await self.readSingleFrame(from: videoURL, at: .zero) {
                        guard isCurrentPipeline() else {
                            await coordinator.endSession()
                            return
                        }
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
            guard isCurrentPipeline() else {
                await coordinator.endSession()
                return
            }
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
                #if os(macOS)
                let cachedFrameCount = self.fullCachePresentationQueue?.snapshot().frameCount ??
                    self.lockCache {
                        max(0, self.processedFrameCache.count - self.processedFrameCacheStart)
                    }
                #else
                let cachedFrameCount = self.lockCache {
                    max(0, self.processedFrameCache.count - self.processedFrameCacheStart)
                }
                #endif
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
                guard !Task.isCancelled, gen == self.playbackGeneration else { return false }
                let inserted = self.lockCache {
                    guard gen == self.playbackGeneration else { return false }
                    return self.insertProcessedFrameIntoCache(frame)
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

            if let preparedFrameCacheKey, preparedFrameCacheMode == .full {
                #if os(macOS)
                let screenMaximumFrameRate = renderer.schedulingSnapshot().screenMaximumFramesPerSecond
                let maximumCachedFramesPerGroup: Int? = {
                    guard screenMaximumFrameRate > 0, sourceFPS > 0 else { return nil }
                    let count = Int((Double(screenMaximumFrameRate) / sourceFPS).rounded(.down))
                    guard count > 0,
                          fiLevel > count else { return nil }
                    return count
                }()
                NSLog(
                    "CACHE: playback mode=full displayCap=%d groupFrameLimit=%d",
                    screenMaximumFrameRate,
                    maximumCachedFramesPerGroup ?? 0
                )
                #else
                let maximumCachedFramesPerGroup: Int? = nil
                NSLog("CACHE: playback mode=full")
                #endif
                // A full cache is persistent. Keeping the entire title's raw
                // pixel buffers resident only competes with presentation for
                // memory bandwidth and main-actor time. Retain one display
                // second of frames, with enough headroom for startup.
                #if os(macOS)
                let presentationReserveTarget = max(60, screenMaximumFrameRate)
                #else
                let presentationReserveTarget = 60
                #endif
                let maximumPresentationReserveFrames = max(
                    initialPrerollFrameCount * 4,
                    presentationReserveTarget
                )
                let readerControl = EnhancedPresentationReaderControl(
                    startTime: self.lastPulledTime,
                    generation: 1
                )
                let presentationQueue = EnhancedPresentationFrameQueue(
                    capacityBytes: frameCacheMemoryBudget,
                    capacityFrames: maximumPresentationReserveFrames,
                    generation: 1
                )
                self.fullCacheReaderControl = readerControl
                self.fullCachePresentationQueue = presentationQueue
                let prerollFrameCount = initialPrerollFrameCount

                let readerTask = Task.detached(priority: .userInitiated) {
                    var handledGeneration: UInt64 = 0
                    var notifiedPrerollGeneration: UInt64?

                    while !Task.isCancelled {
                        let request = readerControl.request()
                        guard request.generation != handledGeneration else {
                            try? await Task.sleep(nanoseconds: 8_000_000)
                            continue
                        }
                        handledGeneration = request.generation
                        notifiedPrerollGeneration = nil
                        presentationQueue.reset(generation: handledGeneration)
                        let startTime = CMTime(
                            seconds: request.seconds,
                            preferredTimescale: 600
                        )
                        guard var groupIndex = try? await diskCache.groupIndex(
                            atOrAfter: startTime,
                            for: preparedFrameCacheKey
                        ) else {
                            return
                        }

                        while !Task.isCancelled {
                            let latestRequest = readerControl.request()
                            guard latestRequest.generation == handledGeneration else { break }
                            let queueSnapshot = presentationQueue.snapshot()
                            guard queueSnapshot.frameCount <
                                maximumPresentationReserveFrames - (maximumCachedFramesPerGroup ?? 1) else {
                                try? await Task.sleep(nanoseconds: 8_000_000)
                                continue
                            }

                            let readSignpost = MacPresentationSignposts.begin("FullCacheDecode")
                            let frames: [VTFrame]?
                            do {
                                let url = try await diskCache.groupFileURL(
                                    groupIndex,
                                    for: preparedFrameCacheKey
                                )
                                if let url {
                                    frames = try EnhancedFrameDiskCache.readFrames(
                                        at: url,
                                        maximumFrameCount: maximumCachedFramesPerGroup
                                    )
                                } else {
                                    frames = nil
                                }
                            } catch {
                                frames = nil
                            }
                            MacPresentationSignposts.end("FullCacheDecode", identifier: readSignpost)

                            guard !Task.isCancelled,
                                  readerControl.request().generation == handledGeneration,
                                  let frames else {
                                break
                            }
                            let admissionSignpost = MacPresentationSignposts.begin("FullCacheAdmission")
                            let admitted = presentationQueue.enqueue(
                                contentsOf: frames,
                                generation: handledGeneration
                            )
                            MacPresentationSignposts.end(
                                "FullCacheAdmission",
                                identifier: admissionSignpost
                            )
                            guard admitted else { continue }
                            presentationQueue.recordCacheHitGroup(generation: handledGeneration)
                            if notifiedPrerollGeneration != handledGeneration,
                               presentationQueue.snapshot().frameCount >= prerollFrameCount {
                                notifiedPrerollGeneration = handledGeneration
                                Task { @MainActor [weak self] in
                                    guard let self,
                                          self.playbackGeneration == gen,
                                          self.fullCacheReaderControl === readerControl else {
                                        return
                                    }
                                    resumeAfterFramePrerollIfReady()
                                }
                            }
                            groupIndex += 1
                        }
                    }
                }
                await withTaskCancellationHandler {
                    await readerTask.value
                } onCancel: {
                    readerTask.cancel()
                }
                if self.fullCacheReaderControl === readerControl {
                    self.fullCacheReaderControl = nil
                    self.fullCachePresentationQueue = nil
                }
                resumeAfterFramePrerollIfReady(force: true)
                await coordinator.endSession()
                return
            }

            let sparseCacheStatus: EnhancedFrameCacheStatus?
            if let preparedFrameCacheKey, preparedFrameCacheMode == .sparse {
                sparseCacheStatus = try? await self.enhancedFrameDiskCache.cachedStatus(for: preparedFrameCacheKey)
                let coveragePercent: Int
                if let bitmap = sparseCacheStatus?.coverageBitmap, !bitmap.isEmpty {
                    coveragePercent = Int((Double(bitmap.filter { $0 }.count) / Double(bitmap.count) * 100).rounded())
                } else {
                    coveragePercent = 0
                }
                NSLog("CACHE: playback mode=sparse coverage=%d%%", coveragePercent)
            } else {
                sparseCacheStatus = nil
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

                if let preparedFrameCacheKey,
                   preparedFrameCacheMode == .sparse,
                   let sparseCacheStatus,
                   let groupIndex = try? await self.enhancedFrameDiskCache.groupIndex(
                       closestTo: vtFrame.presentationTimeStamp,
                       for: preparedFrameCacheKey
                   ),
                   sparseCacheStatus.coverageBitmap.indices.contains(groupIndex),
                   sparseCacheStatus.coverageBitmap[groupIndex] {
                    guard await coordinator.advanceSourceHistory(forCachedGroup: vtFrame),
                          let cachedFrames = try? await self.enhancedFrameDiskCache.readGroup(
                              groupIndex,
                              for: preparedFrameCacheKey
                          ) else {
                        self.srInitializationError = "Enhanced cache could not restore a required frame group."
                        break
                    }
                    for cachedFrame in cachedFrames {
                        guard await admitStreamedFrame(cachedFrame) else { break }
                    }
                    self.enhancedCacheHitGroupCount += 1
                    continue
                }

                if preparedFrameCacheMode == .sparse {
                    self.enhancedCacheMissGroupCount += 1
                }

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
                    self.recordFIProcessingTiming(
                        milliseconds: processingMilliseconds,
                        budgetMilliseconds: sourceFrameBudgetMilliseconds,
                        outputFrameCount: outputFrameCount,
                        expectsInterpolation: sourceFrameOrdinal > 1
                    )

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
                    guard !Task.isCancelled, gen == self.playbackGeneration else { break }
                    let insertedFrameCount = self.lockCache {
                        guard gen == self.playbackGeneration else { return 0 }
                        return outputFrames.reduce(into: 0) { count, frame in
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
                    guard !Task.isCancelled, gen == self.playbackGeneration else { break }
                    let inserted = self.lockCache {
                        guard gen == self.playbackGeneration else { return false }
                        return self.insertProcessedFrameIntoCache(vtFrame)
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

        guard pipelineSnapshot.matches(
            activeGeneration: playbackGeneration,
            activeVideoURL: videoURL,
            activePlayer: player
        ) else { return }
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

}
