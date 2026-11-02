import SwiftUI
import AVFoundation
import VideoToolbox
import CoreVideo
import MetalKit
#if os(macOS)
import AppKit
import Synchronization
import CoreFoundation
#endif
#if os(iOS)
import MediaPlayer
#endif

extension VTPlayerViewModel {
    #if os(macOS)
    private func logPlaybackBaseline() {
        let video = CMTimeGetSeconds(lastRenderedPTS)
        let audio = enhancedAudioPlayer?.currentTime.map(CMTimeGetSeconds)
        let valid = audio.map { $0.isFinite && video.isFinite } ?? false
        let offset = valid ? (audio ?? 0) - video : 0
        NSLog("PLAYBACK-METRICS: timelineRatio=%.4f timelineSampleSeconds=%.2f audioClockAvailable=%d audioVideoOffsetSeconds=%.4f", renderedTimelineRatio, renderedTimelineSampleDuration, valid ? 1 : 0, offset)
    }
    func resetActualPresentedFrameMetrics() {
        actualPresentedFrameBaseline = renderer.totalPresentedFrameCount()
        actualPresentedMetricWindowStart = .now()
        actualPresentedFrameRate = 0
        actualPresented1PercentLow = 0
        actualPresentedRateSamples.removeAll(keepingCapacity: true)
    }

    func refreshActualPresentedFrameMetrics(at now: DispatchTime = .now()) {
        let elapsed = elapsedUptimeSeconds(since: actualPresentedMetricWindowStart, until: now)
        guard elapsed >= 1 else { return }
        let currentTotal = renderer.totalPresentedFrameCount()
        let presentedFrames = max(0, currentTotal - actualPresentedFrameBaseline)
        actualPresentedFrameRate = Double(presentedFrames) / elapsed
        actualPresentedRateSamples.append(actualPresentedFrameRate)
        if actualPresentedRateSamples.count > 5 {
            actualPresentedRateSamples.removeFirst(actualPresentedRateSamples.count - 5)
        }
        actualPresented1PercentLow = actualPresentedRateSamples.min() ?? actualPresentedFrameRate
        actualPresentedFrameBaseline = currentTotal
        actualPresentedMetricWindowStart = now
    }

    func applyDedicatedPresentationUpdate(_ update: DedicatedPresentationUpdate) {
        guard FullCachePresentationGeneration.accepts(
            driverGeneration: update.generation,
            activeGeneration: playbackGeneration,
            isPlaying: isPlaying,
            isPaused: isPaused,
            isBuffering: isBuffering
        ) else { return }

        if update.isFirstFrame {
            if !pipelinePresentationReady {
                pipelinePresentationReady = true
                setNativeVideoEnabled(false)
            }
            if playbackPhase == .prerollingEnhanced {
                if preparedEnhancedFrameCacheMode == nil {
                    transitionPlayback(to: .monitoringEnhanced)
                    enhancedCachePreparationState = .monitoring
                } else {
                    transitionPlayback(to: .playingEnhanced)
                    enhancedCachePreparationState = .ready
                }
            }
        }
        enhancedAudioPlayer?.frameRendered(at: update.presentationTimeStamp, synchronizeToFrame: true)
        lastRenderedPTS = update.presentationTimeStamp
        lastPresentationWall = .now()
        displayLinkTickCount += update.callbacks
        presentedFramesCount += update.presented
        diagnosticPresentedFramesCount += update.presented
        diagnosticPresentedInterpolatedCount += update.interpolated
        diagnosticPresentedSourceCount += update.source
        if update.droppedInterpolatedFrames > 0 {
            pendingDroppedFrames += update.droppedInterpolatedFrames
            publishProcessingDiagnostics()
        }
        recordRenderedTimeline(at: update.presentationTimeStamp)
        publishCurrentTime(min(update.presentationSeconds, duration))
        if let measuredFPS = update.measuredFPS {
            fps = measuredFPS
            if displayRateSamples.count >= 5 {
                displayRateSamples.removeFirst(displayRateSamples.count - 4)
            }
            displayRateSamples.append(measuredFPS)
            displayRate1PercentLow = displayRateSamples.min() ?? measuredFPS
        }
        refreshActualPresentedFrameMetrics()
        logDedicatedPresentationDiagnosticsIfNeeded()
    }

    private func logDedicatedPresentationDiagnosticsIfNeeded() {
        let now = DispatchTime.now()
        let elapsed = elapsedUptimeSeconds(since: diagTimer, until: now)
        guard elapsed >= 5,
              let driver = macDedicatedMetalDisplayTickDriver,
              let presentationQueue = fullCachePresentationQueue else { return }
        logPlaybackBaseline()

        let queue = presentationQueue.snapshot(consumeActivity: true)
        let rendererPerformance = renderer.consumePerformanceSnapshot()
        let driverSnapshot = driver.consumeSnapshot()
        let physicalCadence = macPhysicalDisplayCadenceMonitor?.consumeSnapshot()
        let scheduling = renderer.schedulingSnapshot()
        let actualPresentationRate = actualPresentedFrameRate
        let submittedRate = Double(driverSnapshot.renderedFrames) / elapsed
        let cacheMode = preparedEnhancedFrameCacheMode?.rawValue ?? "realTime"
        let hitRate = queue.cacheHitGroups > 0 ? 100.0 : 0.0

        NSLog(
            "DIAG: cache=%d currentSecs=%.3f nextPTS=%.3f rate=%.1f produced5s=%d callbacks5s=%d presented5s=%d interp5s=%d source5s=%d rendered=%.1f",
            queue.frameCount,
            currentTime,
            queue.nextPresentationSeconds ?? duration,
            playbackSpeed,
            queue.enqueuedFrames,
            driverSnapshot.callbacks,
            driverSnapshot.renderedFrames,
            driverSnapshot.renderedInterpolatedFrames,
            driverSnapshot.renderedSourceFrames,
            fps
        )
        NSLog(
            "CACHE: mode=%@ coverage=%d hits5s=%d misses5s=%d hitRate=%.1f",
            cacheMode,
            enhancedCacheCoveragePercent,
            queue.cacheHitGroups,
            enhancedCacheMissGroupCount,
            hitRate
        )
        NSLog(
            "CACHE-PRESENTATION: dequeues5s=%d starved5s=%d sampledOut5s=%d lateInterpDrops5s=%d",
            queue.dequeueAttempts,
            queue.starvationCount,
            queue.intentionallySampledOutFrames,
            queue.lateInterpolatedDrops
        )
        NSLog(
            "PRODUCER: timingSamples=%d decodeWaitTotalMs=%.2f admissionWaitTotalMs=%.2f insertionTotalMs=%.2f processSamples=%d processTotalMs=%.2f processMaxMs=%.2f deadlineMisses=%d outputShortfalls=%d emptyCallbacks=%d drawableFailures=%d encodeFailures=%d",
            producerTimingSampleCount,
            producerDecodeWaitMilliseconds,
            producerCacheAdmissionMilliseconds,
            producerCacheInsertionMilliseconds,
            fiProcessingSampleCount,
            fiProcessingMilliseconds,
            fiProcessingMaximumMilliseconds,
            fiDeadlineMissCount,
            fiOutputShortfallCount,
            driverSnapshot.emptyQueueCallbacks,
            driverSnapshot.drawableAcquisitionFailures,
            driverSnapshot.encodingFailures
        )
        NSLog(
            "PRODUCER-GAPS: samples=%d totalMs=%.2f maxMs=%.2f deliveryTotalMs=%.2f admissionExecutionTotalMs=%.2f",
            producerBetweenGroupsSampleCount,
            producerBetweenGroupsMilliseconds,
            producerBetweenGroupsMaximumMilliseconds,
            producerDeliveryMilliseconds,
            producerAdmissionExecutionMilliseconds
        )
        NSLog(
            "RENDER-CADENCE: physicalHz=%.1f callbacks=%d driverHz=%.1f callbackIntervalMs=%.2f scheduledHz=%.1f coalesced=%d mainQueueDelayMs=%.2f deadlineMarginMs=%.2f submitHz=%.1f actualHz=%.1f actualIntervalMs=%.2f intervalP50Ms=%.2f intervalP95Ms=%.2f intervalStdDevMs=%.2f maxGapMs=%.2f minRefreshMs=%.2f maxRefreshMs=%.2f displayModeHz=%.1f",
            physicalCadence?.framesPerSecond ?? 0,
            physicalCadence?.callbacks ?? 0,
            Double(driverSnapshot.callbacks) / elapsed,
            driverSnapshot.averageCallbackIntervalMilliseconds,
            Double(driverSnapshot.scheduled) / elapsed,
            driverSnapshot.coalesced,
            driverSnapshot.averageMainQueueDelayMilliseconds,
            driverSnapshot.averageDeadlineMarginMilliseconds,
            submittedRate,
            actualPresentationRate,
            rendererPerformance.averagePresentationIntervalMilliseconds,
            rendererPerformance.p50PresentationIntervalMilliseconds,
            rendererPerformance.p95PresentationIntervalMilliseconds,
            rendererPerformance.presentationIntervalStandardDeviationMilliseconds,
            rendererPerformance.maximumPresentationGapMilliseconds,
            scheduling.screenMinimumRefreshInterval * 1_000,
            scheduling.screenMaximumRefreshInterval * 1_000,
            scheduling.displayModeRefreshRate
        )
        NSLog(
            "RENDER-INTERVALS: p50Ms=%.2f p95Ms=%.2f stdDevMs=%.2f maxGapMs=%.2f duplicates=%d drops=%d samples=%d",
            rendererPerformance.p50PresentationIntervalMilliseconds,
            rendererPerformance.p95PresentationIntervalMilliseconds,
            rendererPerformance.presentationIntervalStandardDeviationMilliseconds,
            rendererPerformance.maximumPresentationGapMilliseconds,
            rendererPerformance.duplicatePresentations,
            rendererPerformance.droppedPresentations,
            rendererPerformance.presentationIntervalSamples
        )
        NSLog(
            "RENDER: drawsHz=%.1f drawableHz=%.1f drawableFailures=%d drawableWaitMs=%.2f encodeMs=%.2f gpuMs=%.2f gpuFrames=%d presented=%d presentationDrops=%d drawable=%dx%d requestHz=%d screenMaxHz=%d transaction=%@ vsync=%@ encodes=%d",
            Double(rendererPerformance.drawAttempts) / elapsed,
            Double(rendererPerformance.drawableAcquisitions) / elapsed,
            rendererPerformance.drawableAcquisitionFailures,
            rendererPerformance.averageDrawableAcquisitionMilliseconds,
            rendererPerformance.averageCPUEncodeMilliseconds,
            rendererPerformance.averageGPUMilliseconds,
            rendererPerformance.completedGPUFrames,
            rendererPerformance.presentedFrames,
            rendererPerformance.droppedPresentations,
            Int(renderer.drawableSize.width),
            Int(renderer.drawableSize.height),
            scheduling.preferredFramesPerSecond,
            scheduling.screenMaximumFramesPerSecond,
            scheduling.presentsWithTransaction.description,
            scheduling.displaySyncEnabled.description,
            rendererPerformance.encodedFrames
        )
        resetProducerTiming()
        producedFramesCount = 0
        diagTimer = now
    }
    #endif

    func startDisplayLinkIfNeeded() {
        #if os(iOS)
        if let displayLink {
            configureDisplayLinkFrameRate(displayLink)
            return
        }
        #else
        let fullCacheFrameCount = fullCachePresentationQueue?.snapshot().frameCount
        guard EnhancedDisplaySchedulingPolicy.shouldStart(
            isPlaying: isPlaying,
            isPaused: isPaused,
            isBuffering: isBuffering,
            isInitializingPipeline: isInitializingPipeline,
            requiresFullCachePreroll: preparedEnhancedFrameCacheMode == .full,
            fullCacheFrameCount: fullCacheFrameCount
        ) else { return }
        guard displayLink == nil else { return }
        #endif

        // Use the same display-link scheduler on both platforms.
        #if os(macOS)
        guard macMetalDisplayLink == nil,
              macDedicatedMetalDisplayTickDriver == nil else { return }
        let displayID = renderer.window?.screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ].flatMap { ($0 as? NSNumber).map(CGDirectDisplayID.init(truncating:)) }
        // NSView's display link runs on the AppKit main run loop at the
        // attached display cadence. This avoids cross-thread dispatch
        // coalescing between a CVDisplayLink callback and MTKView.draw().
        renderer.setExternalDisplayScheduling(true)
        renderer.onDisplayTick = nil
        if #available(macOS 14.0, *),
           let metalLayer = renderer.layer as? CAMetalLayer {
            let maximumFramesPerSecond = max(
                1,
                renderer.schedulingSnapshot().screenMaximumFramesPerSecond
            )
            let usingKnownFallback = dedicatedPresentationFallbackURL == videoURL &&
                dedicatedPresentationFallbackConfiguration == appliedPipelineConfiguration
            if let presentationQueue = fullCachePresentationQueue,
               let encoder = renderer.makeFullCacheMetalEncoder(),
               let player,
               !usingKnownFallback {
                // The display-link timestamp is the sole presentation clock.
                // Layer sync otherwise caps external drawable acquisition at
                // 60 Hz even when the attached display is running at 120 Hz.
                metalLayer.displaySyncEnabled = false
                let observedSeconds = CMTimeGetSeconds(player.currentTime())
                let anchorSeconds = presentationClockSeconds(
                    playerSeconds: observedSeconds
                )
                let driver = MacDedicatedMetalDisplayTickDriver(
                    viewModel: self,
                    metalLayer: metalLayer,
                    displayID: displayID,
                    presentationQueue: presentationQueue,
                    encoder: encoder,
                    generation: playbackGeneration,
                    anchorPresentationSeconds: anchorSeconds,
                    playbackRate: playbackSpeed,
                    lastRenderedPTS: lastRenderedPTS,
                    catchesUpInterpolation: true
                )
                macDedicatedMetalDisplayTickDriver = driver
                let presentedFrameBaseline = renderer.totalPresentedFrameCount()
                if driver.start() {
                    if macPhysicalDisplayCadenceMonitor == nil {
                        let monitor = MacPhysicalDisplayCadenceMonitor(displayID: displayID)
                        monitor?.start()
                        macPhysicalDisplayCadenceMonitor = monitor
                    }
                    let generation = playbackGeneration
                    Task { @MainActor [weak self, weak driver] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard let self, let driver,
                              self.playbackGeneration == generation,
                              self.macDedicatedMetalDisplayTickDriver === driver,
                              self.isPlaying, !self.isPaused else { return }
                        let driverSnapshot = driver.startupSnapshot()
                        let queueSnapshot = presentationQueue.snapshot()
                        let presentedFrames = max(
                            0,
                            self.renderer.totalPresentedFrameCount() - presentedFrameBaseline
                        )
                        guard EnhancedDisplaySchedulingPolicy.shouldFallbackFromDedicatedDriver(
                            callbacks: driverSnapshot.callbacks,
                            queuedFrames: queueSnapshot.frameCount,
                            submittedFrames: driverSnapshot.renderedFrames,
                            presentedFrames: presentedFrames
                        ) else { return }

                        let summary = "callbacks=\(driverSnapshot.callbacks), queued=\(queueSnapshot.frameCount), submitted=\(driverSnapshot.renderedFrames), presented=\(presentedFrames), emptyQueue=\(driverSnapshot.emptyQueueCallbacks), drawableFailures=\(driverSnapshot.drawableAcquisitionFailures), encodeFailures=\(driverSnapshot.encodingFailures)"
                        self.dedicatedPresentationFallbackURL = self.videoURL
                        self.dedicatedPresentationFallbackConfiguration = self.appliedPipelineConfiguration
                        self.dedicatedPresentationFallbackSummary = summary
                        NSLog("RENDER: dedicated full-cache startup stalled; switching scheduler (%@)", summary)
                        driver.stop()
                        self.macDedicatedMetalDisplayTickDriver = nil
                        self.renderer.setExternalDisplayScheduling(false)
                        self.startDisplayLinkIfNeeded()
                    }
                    NSLog(
                        "RENDER: scheduling=dedicatedScreenDisplayLink requestedHz=%d offMain=true",
                        maximumFramesPerSecond
                    )
                    return
                }
                macDedicatedMetalDisplayTickDriver = nil
                dedicatedPresentationFallbackURL = videoURL
                dedicatedPresentationFallbackConfiguration = appliedPipelineConfiguration
                dedicatedPresentationFallbackSummary = "display link failed to start"
                NSLog("RENDER: dedicated full-cache display link failed to start; using CAMetalDisplayLink")
                renderer.setExternalDisplayScheduling(false)
                metalLayer.displaySyncEnabled = true
            }
            let driver = MacMetalDisplayTickDriver(viewModel: self)
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            link.preferredFrameLatency = 1
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(maximumFramesPerSecond),
                maximum: Float(maximumFramesPerSecond),
                preferred: Float(maximumFramesPerSecond)
            )
            link.delegate = driver
            link.add(to: .main, forMode: .common)
            link.isPaused = false
            macMetalDisplayLink = link
            macMetalDisplayTickDriver = driver
            if macPhysicalDisplayCadenceMonitor == nil {
                let monitor = MacPhysicalDisplayCadenceMonitor(displayID: displayID)
                monitor?.start()
                macPhysicalDisplayCadenceMonitor = monitor
            }
            NSLog("RENDER: scheduling=metalDisplayLink requestedHz=%d latency=1", maximumFramesPerSecond)
            return
        }
        do {
            let driver = MacAppKitDisplayTickDriver(viewModel: self)
            let link = renderer.displayLink(
                target: driver,
                selector: #selector(MacAppKitDisplayTickDriver.displayLinkTick(_:))
            )
            let maximumFramesPerSecond = max(1, renderer.schedulingSnapshot().screenMaximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(maximumFramesPerSecond),
                maximum: Float(maximumFramesPerSecond),
                preferred: Float(maximumFramesPerSecond)
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
            macAppKitDisplayTickDriver = driver
            if macPhysicalDisplayCadenceMonitor == nil {
                let monitor = MacPhysicalDisplayCadenceMonitor(displayID: displayID)
                monitor?.start()
                macPhysicalDisplayCadenceMonitor = monitor
            }
            NSLog("RENDER: scheduling=nsViewDisplayLink requestedHz=%d", maximumFramesPerSecond)
            return
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
        if appliedPipelineConfiguration.frameInterpolationLevel == 4 {
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

    @MainActor
    func tickDisplayLink(targetPresentationHostTime: CFTimeInterval? = nil) {
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

        // Initial enhanced playback keeps AVPlayer paused while the producer
        // builds a small reserve. Do not advance the extrapolated presentation
        // clock during that interval: consuming those frames would prevent the
        // reserve from completing and leave the transport paused indefinitely.
        guard !isBuffering else { return }

        let currentTime = player.currentTime()
        let observedSecs = CMTimeGetSeconds(currentTime)
        let currentSecs = presentationClockSeconds(playerSeconds: observedSecs)
        let presentationSecs = DisplayTargetClock.presentationSeconds(
            currentPresentationSeconds: currentSecs,
            targetHostTime: targetPresentationHostTime,
            currentHostTime: CACurrentMediaTime(),
            playbackRate: playbackSpeed
        )

        var lastFrameToRender: VTFrame? = nil
        var drained = 0
        var droppedInterpolatedFrames = 0
        let now = DispatchTime.now()

        func dequeueFromMemoryCache() {
            self.lockCache {
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
            self.compactProcessedFrameCacheIfNeeded()
            }
        }
        #if os(macOS)
        if let presentationQueue = fullCachePresentationQueue {
            if let selection = presentationQueue.dequeueNewestDue(
                at: presentationSecs,
                after: lastRenderedPTS,
                catchesUpInterpolation: true
            ) {
                lastFrameToRender = selection.frame
                lastRenderedPTS = selection.frame.presentationTimeStamp
                drained = 1
                droppedInterpolatedFrames = selection.droppedInterpolatedFrames
            }
        } else {
            dequeueFromMemoryCache()
        }
        #else
        dequeueFromMemoryCache()
        #endif

        if let frame = lastFrameToRender {
            #if os(macOS)
            if !self.pipelinePresentationReady {
                self.pipelinePresentationReady = true
                self.setNativeVideoEnabled(false)
                if self.playbackPhase == .prerollingEnhanced {
                    if self.preparedEnhancedFrameCacheMode == nil {
                        self.transitionPlayback(to: .monitoringEnhanced)
                        self.enhancedCachePreparationState = .monitoring
                    } else {
                        self.transitionPlayback(to: .playingEnhanced)
                        self.enhancedCachePreparationState = .ready
                    }
                }
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
            let droppedFrames = max(0, drained - 1) + droppedInterpolatedFrames
            if droppedFrames > 0 {
                self.pendingDroppedFrames += droppedFrames
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

        #if os(macOS)
        refreshActualPresentedFrameMetrics(at: statsNow)
        #endif

        let diagElapsed = elapsedUptimeSeconds(since: diagTimer, until: now)
        if diagElapsed >= 5.0 {
            let curRate = player.rate
            let curFPS = self.fps
            var firstFrame: VTFrame? = nil
            var cacheCount = 0
            var cacheBytes = 0
            var queueNextPresentationSeconds: Double?
            var intentionallySampledOutFrames = 0
            var queueDequeueAttempts = 0
            var queueStarvationCount = 0
            var queueLateInterpolatedDrops = 0
            func snapshotMemoryCache() {
                self.lockCache {
                    if self.processedFrameCacheStart < self.processedFrameCache.count {
                        firstFrame = self.processedFrameCache[self.processedFrameCacheStart]
                    }
                    cacheCount = max(0, self.processedFrameCache.count - self.processedFrameCacheStart)
                    cacheBytes = self.processedFrameCacheByteUsage
                }
            }
            #if os(macOS)
            if let presentationQueue = fullCachePresentationQueue {
                let queueSnapshot = presentationQueue.snapshot(consumeActivity: true)
                cacheCount = queueSnapshot.frameCount
                cacheBytes = queueSnapshot.byteUsage
                queueNextPresentationSeconds = queueSnapshot.nextPresentationSeconds
                producedFramesCount += queueSnapshot.enqueuedFrames
                enhancedCacheHitGroupCount += queueSnapshot.cacheHitGroups
                intentionallySampledOutFrames = queueSnapshot.intentionallySampledOutFrames
                queueDequeueAttempts = queueSnapshot.dequeueAttempts
                queueStarvationCount = queueSnapshot.starvationCount
                queueLateInterpolatedDrops = queueSnapshot.lateInterpolatedDrops
            } else {
                snapshotMemoryCache()
            }
            #else
            snapshotMemoryCache()
            #endif

            let produced = producedFramesCount
            let callbacks = displayLinkTickCount
            let presented = diagnosticPresentedFramesCount
            let interpolated = diagnosticPresentedInterpolatedCount
            let source = diagnosticPresentedSourceCount
            let timingSamples = max(1, producerTimingSampleCount)
            let decodeWait = producerDecodeWaitMilliseconds / Double(timingSamples)
            let cacheAdmission = producerCacheAdmissionMilliseconds / Double(timingSamples)
            let cacheInsertion = producerCacheInsertionMilliseconds / Double(timingSamples)
            let fiProcessingSamples = max(1, fiProcessingSampleCount)
            let averageFIProcessing = fiProcessingMilliseconds / Double(fiProcessingSamples)
            let cacheHits = enhancedCacheHitGroupCount
            let cacheMisses = enhancedCacheMissGroupCount
            #if os(macOS)
            let rendererPerformance = renderer.consumePerformanceSnapshot()
            logPlaybackBaseline()
            let drawRate = Double(rendererPerformance.drawAttempts) / diagElapsed
            let drawableRate = Double(rendererPerformance.drawableAcquisitions) / diagElapsed
            let drawableSize = renderer.drawableSize
            let rendererScheduling = renderer.schedulingSnapshot()
            let physicalCadence = macPhysicalDisplayCadenceMonitor?.consumeSnapshot()
            let displayTickDriver: MacDisplayTickDriverSnapshot?
            if #available(macOS 14.0, *) {
                if let macDedicatedMetalDisplayTickDriver {
                    displayTickDriver = macDedicatedMetalDisplayTickDriver.consumeSnapshot()
                } else if let macMetalDisplayTickDriver {
                    displayTickDriver = macMetalDisplayTickDriver.consumeSnapshot()
                } else {
                    displayTickDriver = macAppKitDisplayTickDriver?.consumeSnapshot()
                }
            } else {
                displayTickDriver = macDisplayTickDriver?.consumeSnapshot()
            }
            #endif
            let nextPresentationSeconds = queueNextPresentationSeconds ?? firstFrame.map {
                CMTimeGetSeconds($0.presentationTimeStamp)
            }
            if let ft = nextPresentationSeconds {
                NSLog("DIAG: cache=\(cacheCount) currentSecs=\(String(format: "%.3f", currentSecs)) nextPTS=\(String(format: "%.3f", ft)) rate=\(curRate) produced5s=\(produced) callbacks5s=\(callbacks) presented5s=\(presented) interp5s=\(interpolated) source5s=\(source) rendered=\(curFPS)")
            } else {
                NSLog("DIAG: cache=\(cacheCount) currentSecs=\(String(format: "%.3f", currentSecs)) rate=\(curRate) produced5s=\(produced) callbacks5s=\(callbacks) presented5s=\(presented) interp5s=\(interpolated) source5s=\(source) rendered=\(curFPS)")
            }
            NSLog("PERF: cacheMB=\(cacheBytes / (1024 * 1024)) decodeWaitMs=\(String(format: "%.2f", decodeWait)) cacheWaitMs=\(String(format: "%.2f", cacheAdmission)) cacheInsertMs=\(String(format: "%.2f", cacheInsertion)) samples=\(producerTimingSampleCount)")
            if let cacheMode = preparedEnhancedFrameCacheMode {
                let totalCacheGroups = cacheHits + cacheMisses
                let hitRate = totalCacheGroups > 0 ? Double(cacheHits) / Double(totalCacheGroups) * 100 : 0
                let hitRateString = String(format: "%.1f", hitRate)
                NSLog("CACHE: mode=\(cacheMode.rawValue) coverage=\(enhancedCacheCoveragePercent)% hits5s=\(cacheHits) misses5s=\(cacheMisses) hitRate=\(hitRateString)")
                if cacheMode == .full {
                    NSLog("CACHE-PRESENTATION: dequeues5s=\(queueDequeueAttempts) starved5s=\(queueStarvationCount) sampledOut5s=\(intentionallySampledOutFrames) lateInterpDrops5s=\(queueLateInterpolatedDrops)")
                }
            }
            if fiProcessingSampleCount > 0 {
                NSLog("FI: processMs=\(String(format: "%.2f", averageFIProcessing)) maxMs=\(String(format: "%.2f", fiProcessingMaximumMilliseconds)) deadlineMisses=\(fiDeadlineMissCount)/\(fiProcessingSampleCount) outputShortfalls=\(fiOutputShortfallCount) budgetMs=\(String(format: "%.2f", sourceFrameRate > 0 ? 1_000.0 / sourceFrameRate : 0))")
            }
            #if os(macOS)
            let actualPresentationRate = actualPresentedFrameRate
            NSLog("RENDER-CADENCE: physicalHz=\(String(format: "%.1f", physicalCadence?.framesPerSecond ?? 0)) callbacks=\(physicalCadence?.callbacks ?? 0) driverHz=\(String(format: "%.1f", Double(displayTickDriver?.callbacks ?? 0) / diagElapsed)) callbackIntervalMs=\(String(format: "%.2f", displayTickDriver?.averageCallbackIntervalMilliseconds ?? 0)) scheduledHz=\(String(format: "%.1f", Double(displayTickDriver?.scheduled ?? 0) / diagElapsed)) coalesced=\(displayTickDriver?.coalesced ?? 0) mainQueueDelayMs=\(String(format: "%.2f", displayTickDriver?.averageMainQueueDelayMilliseconds ?? 0)) deadlineMarginMs=\(String(format: "%.2f", displayTickDriver?.averageDeadlineMarginMilliseconds ?? 0)) submitHz=\(String(format: "%.1f", Double(presented) / diagElapsed)) actualHz=\(String(format: "%.1f", actualPresentationRate)) actualIntervalMs=\(String(format: "%.2f", rendererPerformance.averagePresentationIntervalMilliseconds)) minRefreshMs=\(String(format: "%.2f", rendererScheduling.screenMinimumRefreshInterval * 1_000)) maxRefreshMs=\(String(format: "%.2f", rendererScheduling.screenMaximumRefreshInterval * 1_000)) displayModeHz=\(String(format: "%.1f", rendererScheduling.displayModeRefreshRate))")
            NSLog("RENDER-INTERVALS: p50Ms=\(String(format: "%.2f", rendererPerformance.p50PresentationIntervalMilliseconds)) p95Ms=\(String(format: "%.2f", rendererPerformance.p95PresentationIntervalMilliseconds)) stdDevMs=\(String(format: "%.2f", rendererPerformance.presentationIntervalStandardDeviationMilliseconds)) maxGapMs=\(String(format: "%.2f", rendererPerformance.maximumPresentationGapMilliseconds)) duplicates=\(rendererPerformance.duplicatePresentations) drops=\(rendererPerformance.droppedPresentations) samples=\(rendererPerformance.presentationIntervalSamples)")
            NSLog("RENDER: drawsHz=\(String(format: "%.1f", drawRate)) drawableHz=\(String(format: "%.1f", drawableRate)) drawableFailures=\(rendererPerformance.drawableAcquisitionFailures) drawableWaitMs=\(String(format: "%.2f", rendererPerformance.averageDrawableAcquisitionMilliseconds)) encodeMs=\(String(format: "%.2f", rendererPerformance.averageCPUEncodeMilliseconds)) gpuMs=\(String(format: "%.2f", rendererPerformance.averageGPUMilliseconds)) gpuFrames=\(rendererPerformance.completedGPUFrames) presented=\(rendererPerformance.presentedFrames) presentationDrops=\(rendererPerformance.droppedPresentations) drawable=\(Int(drawableSize.width))x\(Int(drawableSize.height)) requestHz=\(rendererScheduling.preferredFramesPerSecond) screenMaxHz=\(rendererScheduling.screenMaximumFramesPerSecond) transaction=\(rendererScheduling.presentsWithTransaction) vsync=\(rendererScheduling.displaySyncEnabled) encodes=\(rendererPerformance.encodedFrames)")
            #endif
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
}
