import Foundation

#if os(macOS)
import CoreVideo
import Synchronization
import os

nonisolated enum MacPresentationSignposts {
    private static let isEnabled = ProcessInfo.processInfo.environment[
        "VTPLAYER_ENABLE_PRESENTATION_SIGNPOSTS"
    ] == "1"
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vtplayer.app",
        category: "EnhancedPresentation"
    )

    static func begin(_ name: StaticString) -> OSSignpostID {
        let identifier = OSSignpostID(log: log)
        if isEnabled {
            os_signpost(.begin, log: log, name: name, signpostID: identifier)
        }
        return identifier
    }

    static func end(_ name: StaticString, identifier: OSSignpostID) {
        if isEnabled {
            os_signpost(.end, log: log, name: name, signpostID: identifier)
        }
    }
}

struct PhysicalDisplayCadenceSnapshot: Sendable {
    let callbacks: Int
    let averageIntervalMilliseconds: Double

    var framesPerSecond: Double {
        guard averageIntervalMilliseconds > 0 else { return 0 }
        return 1_000.0 / averageIntervalMilliseconds
    }
}

private struct PhysicalDisplayCadenceState: Sendable {
    var callbacks = 0
    var previousSeconds: Double?
    var intervalSeconds = 0.0
    var intervalCount = 0
}

final class MacPhysicalDisplayCadenceMonitor: @unchecked Sendable {
    private let state = Mutex(PhysicalDisplayCadenceState())
    private var displayLink: CVDisplayLink?

    init?(displayID: CGDirectDisplayID?) {
        var link: CVDisplayLink?
        let result: CVReturn
        if let displayID {
            result = CVDisplayLinkCreateWithCGDisplay(displayID, &link)
        } else {
            result = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        }
        guard result == kCVReturnSuccess, let link else { return nil }
        guard CVDisplayLinkSetOutputCallback(
            link,
            Self.callback,
            Unmanaged.passUnretained(self).toOpaque()
        ) == kCVReturnSuccess else {
            return nil
        }
        displayLink = link
    }

    deinit {
        stop()
    }

    func start() {
        guard let displayLink else { return }
        CVDisplayLinkStart(displayLink)
    }

    func stop() {
        guard let displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
    }

    func consumeSnapshot() -> PhysicalDisplayCadenceSnapshot {
        state.withLock { state in
            let averageIntervalMilliseconds = state.intervalCount > 0
                ? state.intervalSeconds / Double(state.intervalCount) * 1_000.0
                : 0
            let snapshot = PhysicalDisplayCadenceSnapshot(
                callbacks: state.callbacks,
                averageIntervalMilliseconds: averageIntervalMilliseconds
            )
            state.callbacks = 0
            state.intervalSeconds = 0
            state.intervalCount = 0
            return snapshot
        }
    }

    private static let callback: CVDisplayLinkOutputCallback = {
        _, now, _, _, _, userInfo in
        guard let userInfo else { return kCVReturnError }
        let monitor = Unmanaged<MacPhysicalDisplayCadenceMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        let timeStamp = now.pointee
        guard timeStamp.videoTimeScale > 0 else { return kCVReturnSuccess }
        let seconds = Double(timeStamp.videoTime) / Double(timeStamp.videoTimeScale)
        monitor.state.withLock { state in
            state.callbacks += 1
            if let previousSeconds = state.previousSeconds, seconds >= previousSeconds {
                state.intervalSeconds += seconds - previousSeconds
                state.intervalCount += 1
            }
            state.previousSeconds = seconds
        }
        return kCVReturnSuccess
    }
}
#endif
