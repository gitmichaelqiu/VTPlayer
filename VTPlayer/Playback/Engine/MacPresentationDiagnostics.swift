import Foundation

#if os(macOS)
import AppKit
import QuartzCore
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

@MainActor
final class MacPhysicalDisplayCadenceMonitor: NSObject {
    private let state = Mutex(PhysicalDisplayCadenceState())
    private var displayLink: CADisplayLink?
    private let screen: NSScreen

    init?(displayID: CGDirectDisplayID?) {
        let screen = NSScreen.screens.first { screen in
            guard let displayID,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDirectDisplayID(truncating: number) == displayID
        } ?? NSScreen.main
        guard let screen else { return nil }
        self.screen = screen
        super.init()
    }

    func start() {
        guard displayLink == nil else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
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

    @objc private func tick(_ link: CADisplayLink) {
        let seconds = link.timestamp
        state.withLock { state in
            state.callbacks += 1
            if let previous = state.previousSeconds, seconds >= previous {
                state.intervalSeconds += seconds - previous
                state.intervalCount += 1
            }
            state.previousSeconds = seconds
        }
    }
}
#endif
