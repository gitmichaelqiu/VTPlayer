import SwiftUI
import AVKit
import AVFoundation
import MetalKit
import VideoToolbox
import CoreVideo

#if canImport(UIKit)
import UIKit
import QuartzCore
#if os(iOS)
import MediaPlayer
#endif
#elseif canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

enum ContinueVideoPlaybackPreference: Int {
    case `default`
    case on
    case off
}

/// The Main ViewModel managing the playback loop, synchronization, and processor pipeline.
@Observable
@MainActor
final class VTPlayerViewModel {
    var videoURL: URL?
    var isPlaying = false
    var isPaused = false
    
    var lastPublishedCurrentTime = -Double.infinity
    @ObservationIgnored var isBuffering = false
    /// macOS keeps native presentation visible until the replacement
    /// VideoToolbox pipeline has produced a frame.
    var pipelinePresentationReady = false

    // Feature Levels (0 = Off; supported Low Latency scales vary by device)
    var superResolutionLevel: Float = 0
    var frameInterpolationLevel: Int = 0
    var frameInterpolationIsSupported = false

    // New API Feature Levels
    var qualitySuperResolutionScaleFactor: Int = 0  // 0=off, 2, 4 (Quality SR)
    var motionBlurStrength: Int = 0 {
        didSet {
            let clamped = min(max(motionBlurStrength, 0), 100)
            if clamped != motionBlurStrength {
                motionBlurStrength = clamped
            }
        }
    }
    var denoiseStrength: Double = 0.0  // 0.0=off, 0.0-1.0
    var qualityPrioritization: Int = 1  // 1=normal, 2=quality
    var continueVideoPlaybackPreference: ContinueVideoPlaybackPreference = .default
    var showSidebar = false
    var showLeftSidebar = true
    
    // Quality Control Parameters
    // Fixed policy for general users. These are intentionally not exposed as
    // settings: stable output takes priority over manual trade-off tuning.
    let useHighQualityDownsampling = true
    let useRealTimePriority = true
    
    // Playback Progress & Stats
    var isPipelineActive: Bool {
        #if os(macOS) || os(iOS)
        return (superResolutionLevel > 0 || 
                frameInterpolationLevel > 0 || 
                qualitySuperResolutionScaleFactor > 0 || 
                denoiseStrength > 0 || 
                motionBlurStrength > 0 ||
                hdrStrength > 0)
        #else
        return true
        #endif
    }
    var currentTime: Double = 0.0
    var duration: Double = 0.0
    var playbackSpeed: Double = 1.0 {
        didSet {
            let clamped = max(0.5, min(2.0, playbackSpeed))
            if clamped != playbackSpeed {
                playbackSpeed = clamped
            }
            if let player = player {
                player.rate = Float(isPaused ? 0.0 : clamped)
                resetPresentationClock(at: CMTimeGetSeconds(player.currentTime()))
            }
        }
    }
    var volume: Double = 1.0 {
        didSet {
            let clamped = max(0.0, min(1.0, volume))
            if clamped != volume {
                volume = clamped
                return
            }
            player?.volume = Float(clamped)
            enhancedAudioPlayer?.setVolume(Float(clamped))
        }
    }

    var shouldContinueVideoPlayback: Bool {
        switch continueVideoPlaybackPreference {
        case .default:
            if UserDefaults.standard.object(forKey: "VTDefaultContinueVideoPlayback") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "VTDefaultContinueVideoPlayback")
        case .on:
            return true
        case .off:
            return false
        }
    }

    func setContinueVideoPlaybackPreference(_ preference: ContinueVideoPlaybackPreference) {
        continueVideoPlaybackPreference = preference
        if !shouldContinueVideoPlayback {
            clearSavedProgress()
        }
        saveVideoSettings()
    }

    private func clearSavedProgress() {
        guard let url = videoURL else { return }
        UserDefaults.standard.removeObject(forKey: "VTPlaybackProgress_\(url.lastPathComponent)")
    }
    @ObservationIgnored var volumeBeforeMute: Double?

    func toggleMute() {
        if volume > 0 {
            volumeBeforeMute = volume
            volume = 0
        } else {
            volume = volumeBeforeMute ?? 1.0
            volumeBeforeMute = nil
        }
        userActivityDetected()
    }
    
    // Video Track Specs
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    var sourceFrameRate: Double = 0.0
    var videoFormat: String = "Unknown"
    
    // Debug Stats HUD
    var frameProcessingTime: Double = 0.0
    var fps: Double = 0.0
    var displayRate1PercentLow: Double = 0.0
    var renderedTimelineRate: Double = 0.0
    var renderedTimelineRatio: Double = 0.0
    var renderedTimelineSampleDuration: Double = 0.0
    var displayFrameRate: Double {
        isPipelineActive ? fps : sourceFrameRate * playbackSpeed
    }
    var droppedFrames = 0
    var aneUsagePercent: Double = 0.0
    @ObservationIgnored var pendingDroppedFrames = 0
    @ObservationIgnored var lastDiagnosticsPublish = DispatchTime.now()

    // Internal, cadence-first control loop for the macOS SR2 + FI path.
    // These deliberately stay out of persisted settings: a tier describes
    // transient device/video headroom, not a user quality preference.
    @ObservationIgnored var adaptiveSRFITiers: [CGSize] = []
    @ObservationIgnored var adaptiveSRFITierIndex = 0
    @ObservationIgnored var adaptiveSRFIDeadlineMisses = 0
    @ObservationIgnored var adaptiveSRFIHeadroomFrames = 0
    @ObservationIgnored var adaptiveSRFICacheStarvations = 0
    @ObservationIgnored var adaptiveSRFIHasPresentedFrame = false
    @ObservationIgnored var adaptiveSRFILastTransition = DispatchTime(uptimeNanoseconds: 0)
    /// Set only after the combined LL2 SR/FI processor rejects this video.
    @ObservationIgnored var useSequentialSRFIFallback = false

    // Detailed SR Diagnostics
    var srIsSupported: Bool = false
    var srSupportedScales: String = "None"
    /// Scale choices supported for the currently loaded video's dimensions.
    /// These are intentionally separate from the display string so menus can
    /// keep unsupported choices visible but disabled.
    var availableSuperResolutionScales: Set<Float> = []
    var availableQualitySuperResolutionScales: Set<Int> = []
    var readyQualitySuperResolutionScales: Set<Int> = []
    var srInitializationError: String? = nil
    
    // Recents List
    var recentVideos: [URL] = []
    
    // Fullscreen and Auto-hide HUD controls state
    var isFullScreen = false
    var showControls = true
    var isHoveringControlBar = false
    var isHoveringVideo = false
    var showAdjustmentsPopover = false
    var isConfigurationPopoverPresented = false
    
    var currentBackgroundColor: Color {
        if isFullScreen {
            return Color.black
        } else if videoURL != nil {
            return Color.black
        } else {
            #if os(macOS)
            return Color(nsColor: .windowBackgroundColor)
            #else
            return Color(uiColor: .systemBackground)
            #endif
        }
    }
    
    var qualitySuperResolutionIsActive: Bool { qualitySuperResolutionScaleFactor > 0 }
    var motionBlurIsActive: Bool { motionBlurStrength > 0 }
    var denoiseIsActive: Bool { denoiseStrength > 0 }
    var sharpnessIsActive: Bool { sharpness > 0 }
    var hdrIsActive: Bool { hdrStrength > 0 }
    var hdrColorfulnessIsActive: Bool { hdrColorfulness > 0 }
    /// Number of processed frames waiting to be displayed (observable by SwiftUI).
    var frameCacheCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return max(0, processedFrameCache.count - processedFrameCacheStart)
    }

    // Sharpness Control (0.0 = off, >0 applies CIUnsharpMask)
    var sharpness: Double = 0.0 {
        didSet {
            renderer.sharpness = Float(sharpness)
        }
    }

    // HDR Tone Mapping (0.0 = off, >0 maps SDR into EDR headroom)
    var hdrStrength: Double = 0.0 {
        didSet {
            renderer.hdrStrength = Float(hdrStrength)
            // HDR-only playback must use the decoded-frame renderer; otherwise
            // the native AVPlayer layer remains on top and no EDR content can
            // reach the display. Rebuild only when crossing the activation
            // boundary so ordinary slider adjustments stay immediate.
            if (oldValue > 0) != (hdrStrength > 0), player != nil {
                updateEnhancements()
            }
        }
    }

    /// Perceptual chroma compensation for SDR-to-EDR presentation. This is a
    /// creative preference, separate from the neutral HDR luminance mapping.
    var hdrColorfulness: Double = 0.0 {
        didSet {
            let clamped = min(max(hdrColorfulness, 0), 1)
            if clamped != hdrColorfulness {
                hdrColorfulness = clamped
                return
            }
            renderer.hdrColorfulness = Float(clamped)
        }
    }

    @ObservationIgnored nonisolated(unsafe) var cursorHidden = false
    var inactivityTask: Task<Void, Never>?
    
    // AVPlayer components
    var player: AVPlayer?
    @ObservationIgnored var producerTask: Task<Void, Never>?
    @ObservationIgnored var consumerTask: Task<Void, Never>?
    @ObservationIgnored var pipelineRestartTask: Task<Void, Never>?
    @ObservationIgnored var coordinatorTeardownTask: Task<Void, Never>?
    @ObservationIgnored var qualityModelRetryTask: Task<Void, Never>?
    @ObservationIgnored var displayLink: CADisplayLink?
    @ObservationIgnored var presentedFramesCount = 0
    @ObservationIgnored var diagnosticPresentedFramesCount = 0
    @ObservationIgnored var diagnosticPresentedInterpolatedCount = 0
    @ObservationIgnored var diagnosticPresentedSourceCount = 0
    @ObservationIgnored var producedFramesCount = 0
    @ObservationIgnored var displayLinkTickCount = 0
    @ObservationIgnored var displayRateSamples: [Double] = []
    @ObservationIgnored var displayRateMeasurementStart = DispatchTime.now()
    @ObservationIgnored var fpsTimer = DispatchTime.now()
    @ObservationIgnored var diagTimer = DispatchTime.now()
    @ObservationIgnored var processedFrameCache: [VTFrame] = []
    @ObservationIgnored var processedFrameCacheStart = 0
    @ObservationIgnored var processedFrameByteEstimate = 0
    @ObservationIgnored let cacheLock = NSRecursiveLock()
    /// Limit retained presentation frames by bytes, not a fixed frame count.
    /// 4x SR can turn a single 1080p frame into a 33 MP image.
    var frameCacheMemoryBudget: Int {
        #if os(iOS)
        let defaultMegabytes = 256
        let maximumMegabytes = 1_024
        #else
        let defaultMegabytes = 1_024
        let maximumMegabytes = 4_096
        #endif
        let configured = UserDefaults.standard.integer(forKey: "VTEnhancedFrameCacheMemoryMB")
        let megabytes = configured > 0 ? configured : defaultMegabytes
        return min(maximumMegabytes, max(128, megabytes)) * 1024 * 1024
    }
    /// The memory budget is the cache limit. A frame-count cap would make
    /// low-resolution videos start with only a few seconds of reserve.
    let maximumFrameCacheCount = Int.max
    func lockCache<T>(_ block: () -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return block()
    }

    func clearProcessedFrameCache() {
        processedFrameCache.removeAll(keepingCapacity: true)
        processedFrameCacheStart = 0
    }

    func publishCurrentTime(_ seconds: Double, immediately: Bool = false) {
        guard seconds.isFinite else { return }
        guard immediately || abs(seconds - lastPublishedCurrentTime) >= (1.0 / 15.0) else { return }
        lastPublishedCurrentTime = seconds
        currentTime = seconds
        #if os(iOS)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = seconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : playbackSpeed
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    #if os(iOS)
    func publishNowPlayingArtwork(for url: URL, duration: Double) {
        let title = UserDefaults.standard.bool(forKey: "VTShowFileExtensions")
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : playbackSpeed
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let image = await VideoPreviewGenerator.image(for: asset, maximumSize: CGSize(width: 600, height: 600))
            guard let image else { return }
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: image.width, height: image.height)) { _ in
                UIImage(cgImage: image)
            }
            guard let self, self.videoURL == url else { return }
            var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
            updated[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
        }
    }

    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    #endif

    func publishProcessingDiagnostics(_ processingTime: Double? = nil) {
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastDiagnosticsPublish.uptimeNanoseconds) / 1_000_000_000.0
        guard elapsed >= 0.1 else { return }

        if let processingTime {
            frameProcessingTime = processingTime
        }
        droppedFrames += pendingDroppedFrames
        pendingDroppedFrames = 0
        aneUsagePercent = 0.0
        lastDiagnosticsPublish = now
    }

    func compactProcessedFrameCacheIfNeeded(force: Bool = false) {
        guard processedFrameCacheStart > 0 else { return }
        let totalCount = processedFrameCache.count
        if force || processedFrameCacheStart >= 64 || processedFrameCacheStart * 2 >= totalCount {
            processedFrameCache = Array(processedFrameCache[processedFrameCacheStart...])
            processedFrameCacheStart = 0
        }
    }

    func processedFrameCacheMemoryUsage() -> Int {
        processedFrameCache.reduce(into: 0) { total, frame in
            total += CVPixelBufferGetDataSize(frame.buffer)
        }
    }

    var bufferedFrameLimit: Int {
        let scale = max(1, max(superResolutionLevel, Float(qualitySuperResolutionScaleFactor)))
        let outputPixels = Double(videoWidth) * Double(videoHeight) * Double(scale * scale)
        guard outputPixels > 0 else { return maximumFrameCacheCount }

        // VideoToolbox normally returns YUV. Refine this fallback from the
        // actual processed buffers as soon as the producer has one, avoiding
        // an unnecessarily shallow cache for 4:2:0 output.
        let estimatedBytesPerFrame = processedFrameByteEstimate > 0
            ? Double(processedFrameByteEstimate)
            : max(1.0, outputPixels * 2.0)
        let budgetedFrames = Int(Double(frameCacheMemoryBudget) / estimatedBytesPerFrame)
        return min(maximumFrameCacheCount, max(2, budgetedFrames))
    }

    var resumeBufferFrameCount: Int {
        min(8, max(2, bufferedFrameLimit / 2))
    }

    var initialPrerollFrameCount: Int {
        #if os(iOS)
        let multiplier = frameInterpolationLevel > 0 ? Double(frameInterpolationLevel) : 1.0
        let outputRate = max(sourceFrameRate * multiplier, 1.0)
        return min(bufferedFrameLimit, max(2, Int((outputRate * 0.75).rounded(.up))))
        #else
        return bufferedFrameLimit
        #endif
    }

    var outputPresentationInterval: Double {
        guard sourceFrameRate > 0 else { return 1.0 / 30.0 }
        let multiplier: Double
        switch frameInterpolationLevel {
        case 4: multiplier = 4.0
        case 2: multiplier = 2.0
        default: multiplier = 1.0
        }
        return 1.0 / (sourceFrameRate * multiplier)
    }
    var securityScopedURL: URL?
    var lastPulledTime: CMTime = .zero
    var playerItemObserver: Any?
    var timeJumpedObserver: Any?
    var rateObserver: NSKeyValueObservation?
    var timeObserverToken: Any?
    var playbackGeneration: UInt64 = 0
    var seekGeneration: UInt64 = 0
    var isInitializingPipeline = false

    // Audio sync monitoring (diagnostic only — never pauses player)
    var lastRenderedPTS: CMTime = .zero
    // AVPlayer can expose a frame-quantized currentTime for silent or low-rate
    // assets.  Interpolated output must be paced by a monotonic clock between
    // those observations, otherwise two generated frames are drained at once
    // and only one is rendered.
    @ObservationIgnored var presentationClockAnchorPTS = 0.0
    @ObservationIgnored var presentationClockAnchorWall = DispatchTime.now()
    @ObservationIgnored var presentationClockLastPlayerPTS = -Double.infinity
    @ObservationIgnored var presentationClockInitialized = false
    @ObservationIgnored var lastPresentationWall = DispatchTime.now()
    @ObservationIgnored var renderedTimelineAnchorPTS: CMTime?
    @ObservationIgnored var renderedTimelineAnchorWall = DispatchTime.now()

    func resetPresentationClock(at seconds: Double) {
        guard seconds.isFinite else { return }
        presentationClockAnchorPTS = seconds
        presentationClockAnchorWall = .now()
        presentationClockLastPlayerPTS = seconds
        presentationClockInitialized = true
        lastPresentationWall = .now()
        resetRenderedTimelineMetrics()
    }

    func resetRenderedTimelineMetrics() {
        renderedTimelineRate = 0
        renderedTimelineRatio = 0
        renderedTimelineSampleDuration = 0
        renderedTimelineAnchorPTS = nil
        renderedTimelineAnchorWall = .now()
    }

    func recordRenderedTimeline(at pts: CMTime, wallTime: DispatchTime = .now()) {
        let seconds = CMTimeGetSeconds(pts)
        guard seconds.isFinite else { return }
        guard let anchorPTS = renderedTimelineAnchorPTS else {
            renderedTimelineAnchorPTS = pts
            renderedTimelineAnchorWall = wallTime
            return
        }

        let wallNanoseconds = wallTime.uptimeNanoseconds >= renderedTimelineAnchorWall.uptimeNanoseconds
            ? wallTime.uptimeNanoseconds - renderedTimelineAnchorWall.uptimeNanoseconds
            : 0
        let wallSeconds = Double(wallNanoseconds) / 1_000_000_000.0
        let mediaSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, anchorPTS))
        guard mediaSeconds > 0, wallSeconds >= 1.0 else { return }

        renderedTimelineRate = mediaSeconds / wallSeconds
        renderedTimelineRatio = renderedTimelineRate / max(playbackSpeed, 0.001)
        renderedTimelineSampleDuration = wallSeconds
        renderedTimelineAnchorPTS = pts
        renderedTimelineAnchorWall = wallTime
    }

    func presentationClockSeconds(playerSeconds: Double) -> Double {
        guard playerSeconds.isFinite else { return playerSeconds }
        let now = DispatchTime.now()
        if !presentationClockInitialized {
            resetPresentationClock(at: playerSeconds)
            return playerSeconds
        }

        // A discontinuity is a seek/restart.  Normal frame-quantized progress
        // simply moves the anchor forward and is extrapolated until the next
        // AVPlayer observation arrives.
        let observedDelta = playerSeconds - presentationClockLastPlayerPTS
        if observedDelta < -0.25 || observedDelta > 0.25 {
            resetPresentationClock(at: playerSeconds)
        } else if observedDelta > 0.0005 {
            presentationClockAnchorPTS = playerSeconds
            presentationClockAnchorWall = now
            presentationClockLastPlayerPTS = playerSeconds
        }

        // The anchor can be reset after `now` is sampled (for example during
        // a seek). Never subtract UInt64 timestamps without checking their
        // order: an inverted pair traps with Swift's arithmetic-overflow
        // runtime failure on iOS.
        let elapsedNanoseconds = now.uptimeNanoseconds >= presentationClockAnchorWall.uptimeNanoseconds
            ? now.uptimeNanoseconds - presentationClockAnchorWall.uptimeNanoseconds
            : 0
        let elapsed = Double(elapsedNanoseconds) / 1_000_000_000.0
        return max(playerSeconds, presentationClockAnchorPTS + elapsed * playbackSpeed)
    }

    var audioSyncLatency: Double = 0
    var audioSyncTask: Task<Void, Never>?
    @ObservationIgnored var enhancedAudioPlayer: EnhancedAudioPlayer?

    func retryAfterQualityModelDownload(generation: UInt64) {
        qualityModelRetryTask?.cancel()
        qualityModelRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, generation == self.playbackGeneration {
                switch self.modelManager.status {
                case .ready:
                    self.qualityModelRetryTask = nil
                    self.startPlaybackLoop()
                    return
                case .failed:
                    self.qualityModelRetryTask = nil
                    return
                case .notChecked, .downloadRequired, .downloading:
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
    }
    let audioSyncLatencyThreshold: Double = 0.1
    
    let renderer: VTMetalRenderer
    let modelManager = VTModelManager()
    var activeCoordinator: VTFrameProcessorCoordinator?

    var appIcon: Image? {
        #if os(iOS)
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
           let lastIcon = iconFiles.last,
           let uiImage = UIImage(named: lastIcon) {
            return Image(uiImage: uiImage)
        }
        #elseif os(macOS)
        if let nsImage = NSApp?.applicationIconImage {
            return Image(nsImage: nsImage)
        }
        #endif
        return nil
    }

    init() {
        self.renderer = VTMetalRenderer(frame: .zero, device: nil)
        #if os(macOS)
        // Allows a reproducible headless/open-with diagnostic run without
        // changing persisted user preferences.
        if CommandLine.arguments.contains("--vtplayer-fi2-sr2") {
            self.superResolutionLevel = 2
            self.frameInterpolationLevel = 2
        }
        #endif
        #if os(macOS)
        self.reloadRecentVideos()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadRecentVideos),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: nil
        )
        #else
        self.recentVideos = []
        loadRecentVideosIOS()
        self.showSidebar = false
        #endif
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        #if os(macOS)
        for scopedURL in recentSecurityScopedURLs {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        recentSecurityScopedURLs.removeAll()
        if cursorHidden {
            NSCursor.unhide()
        }
        #endif
    }
    
    #if os(iOS)
    func configureAudioSessionForPlayback() {
        // Audio-session activation can block while negotiating the route. Do
        // not perform it on the main actor during video setup.
        DispatchQueue.global(qos: .userInitiated).async {
            let audioSession = AVAudioSession.sharedInstance()

            do {
                try audioSession.setCategory(.playback, mode: .moviePlayback, options: [])

                if #available(iOS 27.0, *) {
                    audioSession.activate(options: [], completionHandler: { activated, error in
                        if !activated, let error {
                            print("Failed to activate playback audio session: \(error.localizedDescription)")
                        }
                    })
                } else {
                    try audioSession.setActive(true)
                }
            } catch {
                print("Failed to configure playback audio session: \(error.localizedDescription)")
            }
        }
    }
    #endif

    func saveProgress() {
        guard let url = videoURL else { return }
        guard shouldContinueVideoPlayback else {
            UserDefaults.standard.removeObject(forKey: "VTPlaybackProgress_\(url.lastPathComponent)")
            return
        }
        UserDefaults.standard.set(self.currentTime, forKey: "VTPlaybackProgress_\(url.lastPathComponent)")
    }
    
    #if os(macOS)
    @ObservationIgnored private var recentSecurityScopedURLs: [URL] = []

    private func securityBookmarkKey(for url: URL) -> String {
        "VTSecurityScopedBookmarkMac.\(url.standardizedFileURL.path)"
    }

    func saveSecurityScopedBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: securityBookmarkKey(for: url))
            // Ensure the grant is on disk before the app is rebuilt or
            // terminated immediately after opening a file.
            UserDefaults.standard.synchronize()
            NSLog("SECURITY: saved bookmark for %@", url.path)
        } catch {
            print("Failed to save security-scoped bookmark: \(error.localizedDescription)")
        }
    }

    func resolveSecurityScopedBookmark(for url: URL) -> URL {
        let path = url.standardizedFileURL.path
        let legacyBookmarks = UserDefaults.standard.dictionary(forKey: "VTSecurityScopedBookmarksMac")
        let legacyBookmark = legacyBookmarks?[path] as? Data
        guard let bookmark = UserDefaults.standard.data(forKey: securityBookmarkKey(for: url)) ?? legacyBookmark else { return url }
        var isStale = false
        do {
            let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale { saveSecurityScopedBookmark(for: resolved) }
            NSLog("SECURITY: resolved bookmark for %@ (stale=%@)", path, isStale ? "YES" : "NO")
            return resolved
        } catch {
            print("Failed to resolve security-scoped bookmark: \(error.localizedDescription)")
            return url
        }
    }

    func removeSecurityScopedBookmark(for url: URL) {
        UserDefaults.standard.removeObject(forKey: securityBookmarkKey(for: url))
    }

    @objc func reloadRecentVideos() {
        for scopedURL in recentSecurityScopedURLs {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        recentSecurityScopedURLs.removeAll(keepingCapacity: true)
        let paths = UserDefaults.standard.stringArray(forKey: "VTRecentVideosMac")
        if let paths = paths {
            var urls: [URL] = []
            for path in paths {
                if let url = URL(string: path) {
                    let resolved = resolveSecurityScopedBookmark(for: url)
                    if resolved.startAccessingSecurityScopedResource() {
                        recentSecurityScopedURLs.append(resolved)
                    }
                    urls.append(resolved)
                }
            }
            self.recentVideos = urls
        } else {
            // First-run migration from NSDocumentController if available
            let removed = UserDefaults.standard.stringArray(forKey: "VTRemovedRecentVideos") ?? []
            let urls = NSDocumentController.shared.recentDocumentURLs.filter { url in
                !removed.contains(url.path)
            }
            self.recentVideos = urls
            let paths = urls.map { $0.absoluteString }
            UserDefaults.standard.set(paths, forKey: "VTRecentVideosMac")
        }
    }

    func recordRecentDateIfNeeded(for url: URL) {
        var addedDates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDatesMac") as? [String: Double] ?? [:]
        if addedDates[url.path] == nil {
            addedDates[url.path] = Date().timeIntervalSince1970
            UserDefaults.standard.set(addedDates, forKey: "VTRecentVideosDatesMac")
        }
        var openedDates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDatesMac") as? [String: Double] ?? [:]
        openedDates[url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(openedDates, forKey: "VTRecentVideosOpenedDatesMac")
    }

    func addRecentVideoMac(_ url: URL) {
        var list = self.recentVideos.filter { $0 != url }
        list.insert(url, at: 0)
        if list.count > 50 {
            list = Array(list.prefix(50))
        }
        self.recentVideos = list
        
        let paths = list.map { $0.absoluteString }
        UserDefaults.standard.set(paths, forKey: "VTRecentVideosMac")

        #if os(macOS)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        #endif
    }
    
    func deleteRecentVideoMac(at url: URL) {
        let wasSelected = videoURL == url
        self.recentVideos.removeAll { $0 == url }
        
        let paths = self.recentVideos.map { $0.absoluteString }
        UserDefaults.standard.set(paths, forKey: "VTRecentVideosMac")

        var dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDatesMac") as? [String: Double] ?? [:]
        dates.removeValue(forKey: url.path)
        UserDefaults.standard.set(dates, forKey: "VTRecentVideosDatesMac")
        removeSecurityScopedBookmark(for: url)
        
        var openedDates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDatesMac") as? [String: Double] ?? [:]
        openedDates.removeValue(forKey: url.path)
        UserDefaults.standard.set(openedDates, forKey: "VTRecentVideosOpenedDatesMac")

        if wasSelected {
            stop()
            videoURL = nil
        }
    }

    func clearRecentVideosMac() {
        let hadSelectedVideo = videoURL != nil
        #if os(macOS)
        NSDocumentController.shared.clearRecentDocuments(nil)
        #endif
        withAnimation(.easeInOut(duration: 0.25)) {
            self.recentVideos.removeAll()
        }
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosMac")
        UserDefaults.standard.removeObject(forKey: "VTRemovedRecentVideos")
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosDatesMac")
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosOpenedDatesMac")

        if hadSelectedVideo {
            stop()
            videoURL = nil
        }

        clearPersistedVideoHistory()
    }
    #endif
    
    func openVideo(_ url: URL) {
        openVideo(url, importIdentifier: nil)
    }

    func openVideo(_ url: URL, importIdentifier: String?) {
        self.stop()

        #if os(macOS)
        let targetURL = resolveSecurityScopedBookmark(for: url)
        #else
        var targetURL = url
        #endif
        
        if let prev = securityScopedURL {
            prev.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }

        let isSecurityScoped = targetURL.startAccessingSecurityScopedResource()
        if isSecurityScoped {
            self.securityScopedURL = targetURL
        }

        #if os(macOS)
        // Persist the grant independently of the boolean return value. A
        // URL may already be scoped by the importer, in which case starting
        // it again can return false even though bookmark creation is valid.
        saveSecurityScopedBookmark(for: targetURL)
        #endif
        
        #if os(iOS)
        if !isManagedImportedVideo(targetURL) {
            let sourceIdentifier = importIdentifier ?? targetURL.resolvingSymlinksInPath().standardizedFileURL.absoluteString
            if let existingURL = existingImportedVideo(forIdentifier: sourceIdentifier) ?? existingImportedVideo(matching: targetURL) {
                if isSecurityScoped {
                    targetURL.stopAccessingSecurityScopedResource()
                    self.securityScopedURL = nil
                }
                deleteTempFile(for: url)
                targetURL = existingURL
            } else {
                let importedDirectory = importedVideosDirectoryURL()
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let filename = targetURL.lastPathComponent.isEmpty ? "Video.mov" : targetURL.lastPathComponent
                let destinationURL = importedDirectory.appendingPathComponent(filename)

                do {
                    try FileManager.default.createDirectory(
                        at: importedDirectory,
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: targetURL, to: destinationURL)
                    if isSecurityScoped {
                        targetURL.stopAccessingSecurityScopedResource()
                        self.securityScopedURL = nil
                    }
                    deleteTempFile(for: url)
                    targetURL = destinationURL
                } catch {
                    if isSecurityScoped {
                        targetURL.stopAccessingSecurityScopedResource()
                        self.securityScopedURL = nil
                    }
                    print("Failed to import video into the app: \(error.localizedDescription)")
                    return
                }
            }
        }

        let sourceIdentifier: String? = {
            if let importIdentifier { return importIdentifier }
            guard !isManagedImportedVideo(url) else { return nil }
            return url.resolvingSymlinksInPath().standardizedFileURL.absoluteString
        }()
        self.addToRecentVideosIOS(targetURL, importIdentifier: sourceIdentifier)
        #endif
        
        self.videoURL = targetURL
        self.setupPlayer(with: targetURL)
    }

    func openRecentVideo(_ url: URL) {
        #if os(macOS)
        let resolvedURL = resolveSecurityScopedBookmark(for: url)
        // A security-scoped bookmark is only effective while its URL is
        // actively being accessed. Start the scope before probing the file;
        // probing first makes every relaunch look like a missing permission.
        let hasScope = resolvedURL.startAccessingSecurityScopedResource()
        let isReadable = FileManager.default.isReadableFile(atPath: resolvedURL.path)
        if hasScope {
            resolvedURL.stopAccessingSecurityScopedResource()
        }
        if !isReadable {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
            panel.message = "Select this video again to restore access."
            if panel.runModal() == .OK, let selectedURL = panel.url {
                openVideo(selectedURL)
            }
            return
        }
        openVideo(resolvedURL)
        return
        #elseif os(iOS)
        let hasScope = url.startAccessingSecurityScopedResource()
        let isReadable = FileManager.default.isReadableFile(atPath: url.path)
        if hasScope {
            url.stopAccessingSecurityScopedResource()
        }

        guard isReadable else {
            if isManagedImportedVideo(url),
               let idx = recentVideos.firstIndex(of: url) {
                deleteRecentVideoIOS(at: IndexSet(integer: idx))
            }
            return
        }
        openVideo(url)
        #else
        self.openVideo(url)
        #endif
    }
    
    #if os(macOS)
    @objc func windowDidEnterFullScreen() {
        self.isFullScreen = true
        self.userActivityDetected()
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            window.backgroundColor = .black
        }
    }
    
    @objc func windowDidExitFullScreen() {
        self.isFullScreen = false
        self.showControls = true
        if self.cursorHidden {
            NSCursor.unhide()
            self.cursorHidden = false
        }
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            window.backgroundColor = .windowBackgroundColor
        }
    }
    #endif
    
    func userActivityDetected() {
        let shouldAutoHide = isPlaying && !isPaused
        
        if shouldAutoHide {
            self.showControls = true
            #if os(macOS)
            if self.cursorHidden {
                NSCursor.unhide()
                self.cursorHidden = false
            }
            #endif
            startInactivityTimer()
        } else {
            self.showControls = true
            #if os(macOS)
            if self.cursorHidden {
                NSCursor.unhide()
                self.cursorHidden = false
            }
            #endif
            inactivityTask?.cancel()
        }
    }
    
    /// Toggles controls visibility — used on iOS to keep the navigation bar
    /// in sync with VideoPlayer's native transport controls which also toggle on tap.
    func toggleControls() {
        if showControls {
            showControls = false
            inactivityTask?.cancel()
        } else {
            showControls = true
            startInactivityTimer()
        }
    }
    
    func startInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            guard !Task.isCancelled, let self = self else { return }
            #if os(iOS)
            let shouldHide = self.isPlaying && !self.isPaused
            #else
            let shouldHide = self.isPlaying && !self.isPaused && !self.isHoveringControlBar && !self.isConfigurationPopoverPresented
            #endif
            if shouldHide {
                self.showControls = false
                 #if os(macOS)
                 if !self.cursorHidden && self.isHoveringVideo {
                     NSCursor.hide()
                     self.cursorHidden = true
                 }
                 #endif
            }
        }
    }

    /// Seeks to a specific timestamp in seconds.
    func seek(to seconds: Double) {
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
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            guard completed, let self = self else { return }
            Task { @MainActor in
                guard requestGeneration == self.seekGeneration,
                      self.player === player else { return }

                // Re-assert player rate — AVPlayer can transiently drop
                // rate to 0 during seek, causing arrow-key seeks to
                // unexpectedly pause playback.
                if shouldPlay && self.isPlaying && !self.isPaused {
                    player.rate = targetRate
                }
                await self.triggerSingleFrameUpdate(
                    at: time,
                    for: player,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    func handleTimeJump() {
        guard let player = player else { return }
        let currentTime = player.currentTime()
        enhancedAudioPlayer?.seek(to: currentTime, shouldPlay: isPlaying && !isPaused)
        
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
            Task { @MainActor in
                if let frame = await self.readSingleFrame(from: url, at: currentTime) {
                    self.renderer.render(pixelBuffer: frame.buffer)
                }
            }
        }
    }

    /// Seeks and draws the frame immediately during continuous scrubbing.
    func scrub(to seconds: Double) {
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
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            guard completed, let self = self else { return }
            Task { @MainActor in
                guard requestGeneration == self.seekGeneration,
                      self.player === player,
                      let url = self.videoURL else { return }

                // Read a single frame via AVAssetReader (video track is
                // disabled on AVPlayer, so copyPixelBuffer won't work).
                if let frame = await self.readSingleFrame(from: url, at: time) {
                    self.renderer.render(pixelBuffer: frame.buffer)
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
        guard requestGeneration == seekGeneration, self.player === player else { return }
        if let frame = await readSingleFrame(from: url, at: time) {
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
    
    /// Whether the pipeline needs to be rebuilt on the next resume.
    var enhancementsPendingRestart = false

}
