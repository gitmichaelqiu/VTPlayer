import SwiftUI
import AVFoundation
import VideoToolbox
import CoreVideo
import MetalKit
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

    nonisolated static func shouldFallbackFromDedicatedDriver(
        callbacks: Int,
        queuedFrames: Int,
        submittedFrames: Int,
        presentedFrames _: Int
    ) -> Bool {
        callbacks == 0 || (queuedFrames > 0 && submittedFrames == 0)
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

struct MacDedicatedPresentationPolicy {
    nonisolated static func shouldUseLiveQueue(
        sourceFramesPerSecond: Double,
        frameInterpolationLevel: Int,
        screenMaximumFramesPerSecond: Int
    ) -> Bool {
        guard sourceFramesPerSecond > 0,
              frameInterpolationLevel > 1,
              screenMaximumFramesPerSecond > 60 else { return false }
        return sourceFramesPerSecond * Double(frameInterpolationLevel) >= 50
    }
}

struct EnhancedPresentationGate {
    nonisolated static func canUseProcessedFrameCache(for configuration: AppliedPipelineConfiguration) -> Bool {
        configuration != .disabled
    }

    /// The display rate is an upper bound, not a requirement that every
    /// refresh interval present a unique video frame. Keep modest scheduling
    /// jitter from interrupting playback; substantially under-rate output
    /// still triggers the cache fallback or a user-visible recovery.
    nonisolated static let minimumAcceptedTargetRatio = 0.90

    nonisolated static func passes(
        measuredFramesPerSecond: Double,
        physicalFramesPerSecond: Double,
        requestedFramesPerSecond: Double,
        renderedTimelineRatio: Double = 1
    ) -> Bool {
        guard measuredFramesPerSecond.isFinite,
              requestedFramesPerSecond > 0 else { return false }
        let physicalCeiling = physicalFramesPerSecond > 0
            ? physicalFramesPerSecond
            : requestedFramesPerSecond
        let target = min(requestedFramesPerSecond, physicalCeiling)
        guard measuredFramesPerSecond >= target * minimumAcceptedTargetRatio else { return false }
        // The short timeline sample can vary by a frame at either boundary.
        return renderedTimelineRatio == 0 || (0.95...1.05).contains(renderedTimelineRatio)
    }
}

nonisolated struct EnhancedPresentationFailureTracker {
    static let windowSeconds = 2.0
    static let healthyWindowsToResetRetry = 5
    private var consecutiveFailures = 0
    private var consecutiveHealthyWindows = 0
    private(set) var canRetry = true

    mutating func markRetry() {
        consecutiveFailures = 0
        consecutiveHealthyWindows = 0
        canRetry = false
    }

    mutating func shouldRecover(passes: Bool) -> Bool {
        if passes {
            consecutiveFailures = 0
            consecutiveHealthyWindows = min(consecutiveHealthyWindows + 1, Self.healthyWindowsToResetRetry)
            if consecutiveHealthyWindows == Self.healthyWindowsToResetRetry {
                canRetry = true
            }
            return false
        }
        consecutiveHealthyWindows = 0
        consecutiveFailures += 1
        return consecutiveFailures >= 2
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
    var emptyQueueCallbacks = 0
    var drawableAcquisitionFailures = 0
    var encodingFailures = 0

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

nonisolated final class MacDedicatedMetalDisplayTickDriver: NSObject, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var isRunning = false
        var displayLink: CADisplayLink?
        var metrics = MacDisplayTickDriverSnapshot()
        var previousCallbackHostTime: CFTimeInterval?
        var lastRenderedPTS: CMTime
        var lastRenderedFrame: VTFrame?
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
    private let tickQueue = DispatchQueue(label: "VTPlayer.presentation", qos: .userInteractive)
    private let tickPending = Mutex(false)
    private let runLoop = Mutex<CFRunLoop?>(nil)

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
        super.init()
    }

    @MainActor
    func start() -> Bool {
        guard !state.withLock({ $0.isRunning }) else { return true }
        guard let screen = viewModel?.renderer.window?.screen ?? NSScreen.main else { return false }
        let displayLink = screen.displayLink(target: self, selector: #selector(displayLinkCallback(_:)))
        state.withLock { state in
            state.isRunning = true
            state.displayLink = displayLink
        }
        let thread = Thread { [weak self] in
            guard let self else { return }
            guard let displayLink = self.state.withLock({ $0.displayLink }) else { return }
            let loop = CFRunLoopGetCurrent()
            self.runLoop.withLock { $0 = loop }
            displayLink.add(to: .current, forMode: .common)
            while self.state.withLock({ $0.isRunning }) {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
            displayLink.invalidate()
            self.runLoop.withLock { $0 = nil }
        }
        thread.name = "VTPlayer presentation"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    @MainActor
    func stop() {
        let displayLink = state.withLock { state in
            state.isRunning = false
            defer { state.displayLink = nil }
            return state.displayLink
        }
        if displayLink != nil {
            runLoop.withLock { if let loop = $0 { CFRunLoopWakeUp(loop) } }
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
                state.metrics.emptyQueueCallbacks += 1
                return
            }
            let drawableAcquisitionStart = DispatchTime.now()
            guard let drawable = metalLayer.nextDrawable(), state.isRunning else {
                state.metrics.drawableAcquisitionFailures += 1
                return
            }
            guard encoder.encode(
                pixelBuffer: selection.frame.buffer,
                to: drawable,
                drawableAcquisitionStart: drawableAcquisitionStart,
                targetPresentationTime: targetHostTime
              ) else {
                state.metrics.encodingFailures += 1
                return
            }

            let frame = selection.frame
            state.lastRenderedPTS = frame.presentationTimeStamp
            state.lastRenderedFrame = frame
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

    func lastRenderedFrame() -> VTFrame? {
        state.withLock { $0.lastRenderedFrame }
    }

    @objc private func displayLinkCallback(_ link: CADisplayLink) {
        let shouldSchedule = tickPending.withLock { pending in
            guard !pending else { return false }
            pending = true
            return true
        }
        guard shouldSchedule else { return }
        let target = link.targetTimestamp
        tickQueue.async { [weak self] in
            guard let self else { return }
            self.displayLinkTick(targetHostTime: target)
            self.tickPending.withLock { $0 = false }
        }
    }

    nonisolated func consumeSnapshot() -> MacDisplayTickDriverSnapshot {
        state.withLock { state in
            let snapshot = state.metrics
            state.metrics = MacDisplayTickDriverSnapshot()
            state.previousCallbackHostTime = nil
            return snapshot
        }
    }

    nonisolated func startupSnapshot() -> MacDisplayTickDriverSnapshot {
        state.withLock { $0.metrics }
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

    func startupCallbackCount() -> Int {
        callbackCount
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

#endif
