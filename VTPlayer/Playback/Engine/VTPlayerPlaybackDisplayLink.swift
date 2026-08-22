import SwiftUI
import AVFoundation
import VideoToolbox
import CoreVideo
import MetalKit
#if os(iOS)
import MediaPlayer
#endif

extension VTPlayerViewModel {
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
            #if os(macOS)
            let rendererPerformance = renderer.consumePerformanceSnapshot()
            let drawRate = Double(rendererPerformance.drawAttempts) / diagElapsed
            let drawableRate = Double(rendererPerformance.drawableAcquisitions) / diagElapsed
            let drawableSize = renderer.drawableSize
            let rendererScheduling = renderer.schedulingSnapshot()
            #endif
            if let first = firstFrame {
                let ft = CMTimeGetSeconds(first.presentationTimeStamp)
                NSLog("DIAG: cache=\(cacheCount) currentSecs=\(String(format: "%.3f", currentSecs)) nextPTS=\(String(format: "%.3f", ft)) rate=\(curRate) produced5s=\(produced) callbacks5s=\(callbacks) presented5s=\(presented) interp5s=\(interpolated) source5s=\(source) rendered=\(curFPS)")
            } else {
                NSLog("DIAG: cache=0 currentSecs=\(String(format: "%.3f", currentSecs)) rate=\(curRate) produced5s=\(produced) callbacks5s=\(callbacks) presented5s=\(presented) interp5s=\(interpolated) source5s=\(source) rendered=\(curFPS)")
            }
            NSLog("PERF: cacheMB=\(cacheBytes / (1024 * 1024)) decodeWaitMs=\(String(format: "%.2f", decodeWait)) cacheWaitMs=\(String(format: "%.2f", cacheAdmission)) cacheInsertMs=\(String(format: "%.2f", cacheInsertion)) samples=\(producerTimingSampleCount)")
            #if os(macOS)
            NSLog("RENDER: drawsHz=\(String(format: "%.1f", drawRate)) drawableHz=\(String(format: "%.1f", drawableRate)) drawableWaitMs=\(String(format: "%.2f", rendererPerformance.averageDrawableAcquisitionMilliseconds)) encodeMs=\(String(format: "%.2f", rendererPerformance.averageCPUEncodeMilliseconds)) gpuMs=\(String(format: "%.2f", rendererPerformance.averageGPUMilliseconds)) gpuFrames=\(rendererPerformance.completedGPUFrames) drawable=\(Int(drawableSize.width))x\(Int(drawableSize.height)) requestHz=\(rendererScheduling.preferredFramesPerSecond) screenMaxHz=\(rendererScheduling.screenMaximumFramesPerSecond) transaction=\(rendererScheduling.presentsWithTransaction) vsync=\(rendererScheduling.displaySyncEnabled) encodes=\(rendererPerformance.encodedFrames)")
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
