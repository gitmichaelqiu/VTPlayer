import Foundation

enum ContinueVideoPlaybackPreference: Int {
    case `default`
    case on
    case off
}

enum EnhancedCachePreparationState: Equatable {
    case idle
    case benchmarking
    case prerolling
    case monitoring
    case preparing(
        progress: Double,
        bytesWritten: Int64,
        estimatedTotalBytes: Int64,
        estimatedRemainingSeconds: Double?
    )
    case ready
    case failed(String)
}

#if os(macOS)
/// The user-visible lifecycle for the macOS player. The legacy playback
/// booleans remain available to the rendering code, but all user actions use
/// this phase to avoid contradictory states such as “paused” and “preparing”
/// at the same time.
enum PlaybackPhase: Equatable {
    case empty
    case loading
    case readyPaused
    case playingNative
    case benchmarking
    case prerollingEnhanced
    case monitoringEnhanced
    case preparingCache
    case playingEnhanced
    case paused
    case ended
    case failed

    var label: String {
        switch self {
        case .empty: return "No video"
        case .loading: return "Loading"
        case .readyPaused: return "Ready · Paused"
        case .playingNative: return "Playing · Native"
        case .benchmarking: return "Preparing enhancements · Measuring"
        case .prerollingEnhanced: return "Warming enhanced playback"
        case .monitoringEnhanced: return "Playing · Checking smoothness"
        case .preparingCache: return "Preparing enhancements · Caching"
        case .playingEnhanced: return "Playing · Enhanced"
        case .paused: return "Paused"
        case .ended: return "Ended"
        case .failed: return "Playback issue"
        }
    }
}

enum PlaybackIssueStage: String, Equatable {
    case loading
    case permissions
    case capabilities
    case preparation
    case qualitySRPreparation
    case pipeline
}

struct PlaybackIssue: Identifiable, Equatable {
    let id: String
    let stage: PlaybackIssueStage
    let message: String

    init(stage: PlaybackIssueStage, message: String) {
        self.stage = stage
        self.message = message
        self.id = "\(stage.rawValue):\(message)"
    }
}
#endif

