import SwiftUI
import AVFoundation
import VideoToolbox
import CoreVideo
import MetalKit
#if os(macOS)
import AppKit
import Synchronization
import CoreFoundation

struct EnhancedDisplaySchedulingPolicy {
    nonisolated static func shouldStart(
        isPlaying: Bool,
        isPaused: Bool,
        isBuffering: Bool,
        isInitializingPipeline: Bool,
        requiresFullCachePreroll: Bool,
        fullCacheFrameCount: Int?
    ) -> Bool {
        guard isPlaying, !isPaused, !isBuffering, !isInitializingPipeline else {
            return false
        }
        if requiresFullCachePreroll {
            return fullCacheFrameCount.map { $0 > 0 } ?? false
        }
        return true
    }
}

struct DisplayTargetClock {
    nonisolated static func presentationSeconds(
        currentPresentationSeconds: Double,
        targetHostTime: CFTimeInterval?,
        currentHostTime: CFTimeInterval,
        playbackRate: Double
    ) -> Double {
        guard let targetHostTime,
              targetHostTime.isFinite,
              currentHostTime.isFinite,
              targetHostTime > currentHostTime else {
            return currentPresentationSeconds
        }
        return currentPresentationSeconds +
            (targetHostTime - currentHostTime) * max(0, playbackRate)
    }
}

struct FullCachePresentationGeneration {
    nonisolated static func accepts(
        driverGeneration: UInt64,
        activeGeneration: UInt64,
        isPlaying: Bool,
        isPaused: Bool,
        isBuffering: Bool
    ) -> Bool {
        driverGeneration == activeGeneration && isPlaying && !isPaused && !isBuffering
    }
}

nonisolated struct MacDisplayTickDriverSnapshot: Sendable {
    var callbacks: Int = 0
    var scheduled: Int = 0
    var coalesced: Int = 0
    var executed: Int = 0
    var totalMainQueueDelayNanoseconds: UInt64 = 0
    var callbackIntervalSamples = 0
    var totalCallbackIntervalNanoseconds: UInt64 = 0
    var deadlineMarginSamples = 0
    var totalDeadlineMarginSeconds = 0.0
    var renderedFrames = 0
    var renderedInterpolatedFrames = 0
    var renderedSourceFrames = 0
    var droppedInterpolatedFrames = 0

    var averageMainQueueDelayMilliseconds: Double {
        guard executed > 0 else { return 0 }
        return Double(totalMainQueueDelayNanoseconds) / Double(executed) / 1_000_000
    }

    var averageCallbackIntervalMilliseconds: Double {
        guard callbackIntervalSamples > 0 else { return 0 }
        return Double(totalCallbackIntervalNanoseconds) /
            Double(callbackIntervalSamples) / 1_000_000
    }

    var averageDeadlineMarginMilliseconds: Double {
        guard deadlineMarginSamples > 0 else { return 0 }
        return totalDeadlineMarginSeconds / Double(deadlineMarginSamples) * 1_000
    }
}

final class MacDisplayTickDriver: @unchecked Sendable {
    weak var viewModel: VTPlayerViewModel?
    private let isTickPending = Mutex(false)
    private let metrics = Mutex(MacDisplayTickDriverSnapshot())
    private let pendingDispatchUptimeNanoseconds = Mutex<UInt64?>(nil)

    init(viewModel: VTPlayerViewModel) {
        self.viewModel = viewModel
    }

    func scheduleTick() {
        let callbackUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let shouldSchedule = isTickPending.withLock { pending in
            metrics.withLock { $0.callbacks += 1 }
            guard !pending else { return false }
            pending = true
            metrics.withLock { $0.scheduled += 1 }
            return true
        }
        guard shouldSchedule else {
            metrics.withLock { $0.coalesced += 1 }
            return
        }
        pendingDispatchUptimeNanoseconds.withLock { $0 = callbackUptimeNanoseconds }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer {
                    self.isTickPending.withLock { $0 = false }
                }
                let mainQueueDelayNanoseconds = self.pendingDispatchUptimeNanoseconds.withLock { dispatchedAt in
                    defer { dispatchedAt = nil }
                    guard let dispatchedAt else { return UInt64.zero }
                    return DispatchTime.now().uptimeNanoseconds &- dispatchedAt
                }
                self.metrics.withLock { metrics in
                    metrics.executed += 1
                    metrics.totalMainQueueDelayNanoseconds &+= mainQueueDelayNanoseconds
                }
                guard let viewModel = self.viewModel else { return }
                viewModel.tickDisplayLink()
                viewModel.renderer.draw()
            }
        }
    }

    func consumeSnapshot() -> MacDisplayTickDriverSnapshot {
        metrics.withLock { metrics in
            defer { metrics = MacDisplayTickDriverSnapshot() }
            return metrics
        }
    }
}

nonisolated final class MacDedicatedMetalDisplayTickDriver: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var isRunning = false
        var displayLink: CVDisplayLink?
        var metrics = MacDisplayTickDriverSnapshot()
        var previousCallbackHostTime: CFTimeInterval?
        var lastRenderedPTS: CMTime
        var didPresentFirstFrame = false
        var lastUIUpdateHostTime: CFTimeInterval
        var pendingCallbacks = 0
        var pendingPresented = 0
        var pendingInterpolated = 0
        var pendingSource = 0
        var pendingDrops = 0
        var fpsWindowStartHostTime: CFTimeInterval
        var fpsWindowFrames = 0
    }

    weak var viewModel: VTPlayerViewModel?
    private let metalLayer: CAMetalLayer
    private let displayID: CGDirectDisplayID?
    private let presentationQueue: EnhancedPresentationFrameQueue
    private let encoder: MacFullCacheMetalEncoder
    private let generation: UInt64
    private let anchorPresentationSeconds: Double
    private let anchorHostTime: CFTimeInterval
    private let playbackRate: Double
    private let catchesUpInterpolation: Bool
    private let state: Mutex<State>

    @MainActor
    init(
        viewModel: VTPlayerViewModel,
        metalLayer: CAMetalLayer,
        displayID: CGDirectDisplayID?,
        presentationQueue: EnhancedPresentationFrameQueue,
        encoder: MacFullCacheMetalEncoder,
        generation: UInt64,
        anchorPresentationSeconds: Double,
        playbackRate: Double,
        lastRenderedPTS: CMTime,
        catchesUpInterpolation: Bool
    ) {
        self.viewModel = viewModel
        self.metalLayer = metalLayer
        self.displayID = displayID
        self.presentationQueue = presentationQueue
        self.encoder = encoder
        self.generation = generation
        self.anchorPresentationSeconds = anchorPresentationSeconds
        self.anchorHostTime = CACurrentMediaTime()
        self.playbackRate = playbackRate
        self.catchesUpInterpolation = catchesUpInterpolation
        self.state = Mutex(State(
            lastRenderedPTS: lastRenderedPTS,
            lastUIUpdateHostTime: self.anchorHostTime,
            fpsWindowStartHostTime: self.anchorHostTime
        ))
    }

    @MainActor
    func start() {
        guard !state.withLock({ $0.isRunning }) else { return }
        var displayLink: CVDisplayLink?
        let result: CVReturn
        if let displayID {
            result = CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink)
        } else {
            result = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        }
        guard result == kCVReturnSuccess, let displayLink,
              CVDisplayLinkSetOutputCallback(
                displayLink,
                Self.displayLinkCallback,
                Unmanaged.passUnretained(self).toOpaque()
              ) == kCVReturnSuccess else { return }
        state.withLock { state in
            state.isRunning = true
            state.displayLink = displayLink
        }
        CVDisplayLinkStart(displayLink)
    }

    @MainActor
    func stop() {
        let displayLink = state.withLock { state in
            state.isRunning = false
            defer { state.displayLink = nil }
            return state.displayLink
        }
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    nonisolated private func displayLinkTick(targetHostTime: CFTimeInterval) {
        let callbackHostTime = CACurrentMediaTime()
        let dispatchedAt = DispatchTime.now().uptimeNanoseconds
        state.withLock { state in
            state.metrics.callbacks += 1
            state.metrics.scheduled += 1
            if let previous = state.previousCallbackHostTime,
               callbackHostTime >= previous {
                let interval = (callbackHostTime - previous) * 1_000_000_000
                if interval <= Double(UInt64.max) {
                    state.metrics.totalCallbackIntervalNanoseconds &+= UInt64(interval)
                    state.metrics.callbackIntervalSamples += 1
                }
            }
            state.previousCallbackHostTime = callbackHostTime
            if targetHostTime.isFinite {
                state.metrics.totalDeadlineMarginSeconds += targetHostTime - callbackHostTime
                state.metrics.deadlineMarginSamples += 1
            }
        }

        let presentationSeconds = anchorPresentationSeconds + max(
            0,
            targetHostTime - anchorHostTime
        ) * playbackRate
        var updateForMain: DedicatedPresentationUpdate?
        state.withLock { state in
            guard state.isRunning else { return }
            state.metrics.executed += 1
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= dispatchedAt {
                state.metrics.totalMainQueueDelayNanoseconds &+= now - dispatchedAt
            }
            state.pendingCallbacks += 1
            guard let selection = presentationQueue.dequeueNewestDue(
                at: presentationSeconds,
                after: state.lastRenderedPTS,
                catchesUpInterpolation: catchesUpInterpolation
            ), state.isRunning else {
                return
            }
            let drawableAcquisitionStart = DispatchTime.now()
            guard let drawable = metalLayer.nextDrawable(), state.isRunning,
              encoder.encode(
                pixelBuffer: selection.frame.buffer,
                to: drawable,
                drawableAcquisitionStart: drawableAcquisitionStart,
                targetPresentationTime: targetHostTime
              ) else {
                return
            }

            let frame = selection.frame
            state.lastRenderedPTS = frame.presentationTimeStamp
            state.metrics.renderedFrames += 1
            state.metrics.droppedInterpolatedFrames += selection.droppedInterpolatedFrames
            state.pendingPresented += 1
            state.pendingDrops += selection.droppedInterpolatedFrames
            state.fpsWindowFrames += 1
            if frame.isInterpolated {
                state.metrics.renderedInterpolatedFrames += 1
                state.pendingInterpolated += 1
            } else {
                state.metrics.renderedSourceFrames += 1
                state.pendingSource += 1
            }

            let isFirstFrame = !state.didPresentFirstFrame
            state.didPresentFirstFrame = true
            let shouldPublish = isFirstFrame ||
                callbackHostTime - state.lastUIUpdateHostTime >= (1.0 / 15.0)
            guard shouldPublish else { return }
            let fpsElapsed = callbackHostTime - state.fpsWindowStartHostTime
            let measuredFPS: Double?
            if fpsElapsed >= 1 {
                measuredFPS = Double(state.fpsWindowFrames) / fpsElapsed
                state.fpsWindowFrames = 0
                state.fpsWindowStartHostTime = callbackHostTime
            } else {
                measuredFPS = nil
            }
            updateForMain = DedicatedPresentationUpdate(
                generation: generation,
                presentationTimeStamp: frame.presentationTimeStamp,
                presentationSeconds: presentationSeconds,
                callbacks: state.pendingCallbacks,
                presented: state.pendingPresented,
                interpolated: state.pendingInterpolated,
                source: state.pendingSource,
                droppedInterpolatedFrames: state.pendingDrops,
                isFirstFrame: isFirstFrame,
                measuredFPS: measuredFPS
            )
            state.pendingCallbacks = 0
            state.pendingPresented = 0
            state.pendingInterpolated = 0
            state.pendingSource = 0
            state.pendingDrops = 0
            state.lastUIUpdateHostTime = callbackHostTime
        }
        if let updateForMain {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let viewModel = self.viewModel,
                          viewModel.macDedicatedMetalDisplayTickDriver === self else { return }
                    viewModel.applyDedicatedPresentationUpdate(updateForMain)
                }
            }
        }
    }

    private static let displayLinkCallback: CVDisplayLinkOutputCallback = {
        _, _, outputTime, _, _, userInfo in
        guard let userInfo else { return kCVReturnError }
        let driver = Unmanaged<MacDedicatedMetalDisplayTickDriver>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        let timestamp = outputTime.pointee
        let refreshInterval = timestamp.videoTimeScale > 0
            ? Double(timestamp.videoRefreshPeriod) / Double(timestamp.videoTimeScale)
            : 0
        let targetHostTime = CACurrentMediaTime() + max(0, refreshInterval)
        driver.displayLinkTick(targetHostTime: targetHostTime)
        return kCVReturnSuccess
    }

    nonisolated func consumeSnapshot() -> MacDisplayTickDriverSnapshot {
        state.withLock { state in
            let snapshot = state.metrics
            state.metrics = MacDisplayTickDriverSnapshot()
            state.previousCallbackHostTime = nil
            return snapshot
        }
    }
}

nonisolated struct DedicatedPresentationUpdate: Sendable {
    let generation: UInt64
    let presentationTimeStamp: CMTime
    let presentationSeconds: Double
    let callbacks: Int
    let presented: Int
    let interpolated: Int
    let source: Int
    let droppedInterpolatedFrames: Int
    let isFirstFrame: Bool
    let measuredFPS: Double?
}

@available(macOS 14.0, *)
@MainActor
final class MacMetalDisplayTickDriver: NSObject, CAMetalDisplayLinkDelegate {
    weak var viewModel: VTPlayerViewModel?
    private var callbackCount = 0
    private var previousCallbackHostTime: CFTimeInterval?
    private var callbackIntervalSamples = 0
    private var totalCallbackIntervalNanoseconds: UInt64 = 0
    private var deadlineMarginSamples = 0
    private var totalDeadlineMarginSeconds = 0.0

    init(viewModel: VTPlayerViewModel) {
        self.viewModel = viewModel
    }

    func metalDisplayLink(_: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let callbackHostTime = CACurrentMediaTime()
        callbackCount += 1
        if let previousCallbackHostTime,
           callbackHostTime >= previousCallbackHostTime {
            let interval = (callbackHostTime - previousCallbackHostTime) * 1_000_000_000
            if interval <= Double(UInt64.max) {
                totalCallbackIntervalNanoseconds += UInt64(interval)
                callbackIntervalSamples += 1
            }
        }
        previousCallbackHostTime = callbackHostTime
        if update.targetTimestamp.isFinite {
            totalDeadlineMarginSeconds += update.targetTimestamp - callbackHostTime
            deadlineMarginSamples += 1
        }
        guard let viewModel else { return }
        viewModel.tickDisplayLink(targetPresentationHostTime: update.targetPresentationTimestamp)
        viewModel.renderer.draw(to: update.drawable)
    }

    func consumeSnapshot() -> MacDisplayTickDriverSnapshot {
        let snapshot = MacDisplayTickDriverSnapshot(
            callbacks: callbackCount,
            scheduled: callbackCount,
            executed: callbackCount,
            callbackIntervalSamples: callbackIntervalSamples,
            totalCallbackIntervalNanoseconds: totalCallbackIntervalNanoseconds,
            deadlineMarginSamples: deadlineMarginSamples,
            totalDeadlineMarginSeconds: totalDeadlineMarginSeconds
        )
        callbackCount = 0
        callbackIntervalSamples = 0
        totalCallbackIntervalNanoseconds = 0
        deadlineMarginSamples = 0
        totalDeadlineMarginSeconds = 0
        return snapshot
    }
}

@available(macOS 14.0, *)
@MainActor
final class MacAppKitDisplayTickDriver: NSObject {
    weak var viewModel: VTPlayerViewModel?
    private var callbackCount = 0

    init(viewModel: VTPlayerViewModel) {
        self.viewModel = viewModel
    }

    @objc func displayLinkTick(_: CADisplayLink) {
        callbackCount += 1
        guard let viewModel else { return }
        viewModel.tickDisplayLink()
        viewModel.renderer.draw()
    }

    func consumeSnapshot() -> MacDisplayTickDriverSnapshot {
        defer { callbackCount = 0 }
        return MacDisplayTickDriverSnapshot(
            callbacks: callbackCount,
            scheduled: callbackCount,
            executed: callbackCount
        )
    }
}

private let macDisplayLinkCallback: CVDisplayLinkOutputCallback = {
    _, _, _, _, _, userInfo in
    guard let userInfo else { return kCVReturnError }
    let driver = Unmanaged<MacDisplayTickDriver>.fromOpaque(userInfo).takeUnretainedValue()
    driver.scheduleTick()
    return kCVReturnSuccess
}
#endif
#if os(iOS)
import MediaPlayer
#endif

extension VTPlayerViewModel {
    #if os(macOS)
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
            enhancedAudioPlayer?.frameRendered(at: update.presentationTimeStamp)
        }
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
        logDedicatedPresentationDiagnosticsIfNeeded()
    }

    private func logDedicatedPresentationDiagnosticsIfNeeded() {
        let now = DispatchTime.now()
        let elapsed = elapsedUptimeSeconds(since: diagTimer, until: now)
        guard elapsed >= 5,
              let driver = macDedicatedMetalDisplayTickDriver,
              let presentationQueue = fullCachePresentationQueue else { return }

        let queue = presentationQueue.snapshot(consumeActivity: true)
        let rendererPerformance = renderer.consumePerformanceSnapshot()
        let driverSnapshot = driver.consumeSnapshot()
        let physicalCadence = macPhysicalDisplayCadenceMonitor?.consumeSnapshot()
        let scheduling = renderer.schedulingSnapshot()
        let actualPresentationRate = Double(rendererPerformance.presentedFrames) / elapsed
        let submittedRate = Double(driverSnapshot.renderedFrames) / elapsed
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
            "CACHE: mode=full coverage=%d hits5s=%d misses5s=0 hitRate=%.1f",
            enhancedCacheCoveragePercent,
            queue.cacheHitGroups,
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
            "RENDER-CADENCE: physicalHz=%.1f callbacks=%d driverHz=%.1f callbackIntervalMs=%.2f scheduledHz=%.1f coalesced=%d mainQueueDelayMs=%.2f deadlineMarginMs=%.2f submitHz=%.1f actualHz=%.1f actualIntervalMs=%.2f minRefreshMs=%.2f maxRefreshMs=%.2f displayModeHz=%.1f",
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
            scheduling.screenMinimumRefreshInterval * 1_000,
            scheduling.screenMaximumRefreshInterval * 1_000,
            scheduling.displayModeRefreshRate
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
        guard macDisplayLink == nil,
              macMetalDisplayLink == nil,
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
            if preparedEnhancedFrameCacheMode == .full,
               let presentationQueue = fullCachePresentationQueue,
               let encoder = renderer.makeFullCacheMetalEncoder(),
               let player {
                // The CVDisplayLink timestamp is the sole presentation clock.
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
                    catchesUpInterpolation: appliedPipelineConfiguration.frameInterpolationLevel > 0
                )
                macDedicatedMetalDisplayTickDriver = driver
                driver.start()
                if macPhysicalDisplayCadenceMonitor == nil {
                    let monitor = MacPhysicalDisplayCadenceMonitor(displayID: displayID)
                    monitor?.start()
                    macPhysicalDisplayCadenceMonitor = monitor
                }
                NSLog(
                    "RENDER: scheduling=dedicatedCVDisplayLink requestedHz=%d offMain=true",
                    maximumFramesPerSecond
                )
                return
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
        if #available(macOS 14.0, *) {
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

        let driver = MacDisplayTickDriver(viewModel: self)
        var displayLink: CVDisplayLink?
        let createResult: CVReturn
        if let displayID {
            createResult = CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink)
        } else {
            createResult = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        }
        guard createResult == kCVReturnSuccess,
              let displayLink,
              CVDisplayLinkSetOutputCallback(
                displayLink,
                macDisplayLinkCallback,
                Unmanaged.passUnretained(driver).toOpaque()
              ) == kCVReturnSuccess else {
            renderer.setExternalDisplayScheduling(false)
            return
        }
        macDisplayTickDriver = driver
        macDisplayLink = displayLink
        CVDisplayLinkStart(displayLink)
        if macPhysicalDisplayCadenceMonitor == nil {
            let monitor = MacPhysicalDisplayCadenceMonitor(displayID: displayID)
            monitor?.start()
            macPhysicalDisplayCadenceMonitor = monitor
        }
        NSLog("RENDER: scheduling=cvDisplayLink requestedHz=%d", renderer.preferredFramesPerSecond)
        return
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
        let needsTimelineCatchUp = appliedPipelineConfiguration.frameInterpolationLevel > 0 && sourceFrameRate > 0

        func dequeueFromMemoryCache() {
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
        }
        #if os(macOS)
        if let presentationQueue = fullCachePresentationQueue {
            if let selection = presentationQueue.dequeueNewestDue(
                at: presentationSecs,
                after: lastRenderedPTS,
                catchesUpInterpolation: needsTimelineCatchUp
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
            let actualPresentationRate = Double(rendererPerformance.presentedFrames) / diagElapsed
            NSLog("RENDER-CADENCE: physicalHz=\(String(format: "%.1f", physicalCadence?.framesPerSecond ?? 0)) callbacks=\(physicalCadence?.callbacks ?? 0) driverHz=\(String(format: "%.1f", Double(displayTickDriver?.callbacks ?? 0) / diagElapsed)) callbackIntervalMs=\(String(format: "%.2f", displayTickDriver?.averageCallbackIntervalMilliseconds ?? 0)) scheduledHz=\(String(format: "%.1f", Double(displayTickDriver?.scheduled ?? 0) / diagElapsed)) coalesced=\(displayTickDriver?.coalesced ?? 0) mainQueueDelayMs=\(String(format: "%.2f", displayTickDriver?.averageMainQueueDelayMilliseconds ?? 0)) deadlineMarginMs=\(String(format: "%.2f", displayTickDriver?.averageDeadlineMarginMilliseconds ?? 0)) submitHz=\(String(format: "%.1f", Double(presented) / diagElapsed)) actualHz=\(String(format: "%.1f", actualPresentationRate)) actualIntervalMs=\(String(format: "%.2f", rendererPerformance.averagePresentationIntervalMilliseconds)) minRefreshMs=\(String(format: "%.2f", rendererScheduling.screenMinimumRefreshInterval * 1_000)) maxRefreshMs=\(String(format: "%.2f", rendererScheduling.screenMaximumRefreshInterval * 1_000)) displayModeHz=\(String(format: "%.1f", rendererScheduling.displayModeRefreshRate))")
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
