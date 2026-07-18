//
//  VTPlayerView.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import SwiftUI
import AVKit
import AVFoundation
import MetalKit
import VideoToolbox
import CoreVideo

#if canImport(UIKit)
import UIKit
import QuartzCore
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(PhotosUI)
import PhotosUI
import UniformTypeIdentifiers
#endif

#if os(macOS)
typealias PlatformVisualEffectMaterial = NSVisualEffectView.Material
typealias PlatformVisualEffectBlendingMode = NSVisualEffectView.BlendingMode
#else
enum PlatformVisualEffectMaterial {
    case hudWindow
}
enum PlatformVisualEffectBlendingMode {
    case withinWindow
}
#endif

#if canImport(UIKit)
struct VTMetalRendererView: UIViewRepresentable {
    let renderer: VTMetalRenderer
    
    func makeUIView(context: Context) -> VTMetalRenderer {
        renderer.isUserInteractionEnabled = false
        return renderer
    }
    
    func updateUIView(_ uiView: VTMetalRenderer, context: Context) {
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }
}
#elseif canImport(AppKit)
struct VTMetalRendererView: NSViewRepresentable {
    let renderer: VTMetalRenderer
    
    func makeNSView(context: Context) -> VTMetalRenderer {
        return renderer
    }
    
    func updateNSView(_ nsView: VTMetalRenderer, context: Context) {}
}
#endif

#if os(macOS)
private struct MacNativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> MacNativeVideoPlayerView {
        MacNativeVideoPlayerView(player: player)
    }

    func updateNSView(_ nsView: MacNativeVideoPlayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

private final class MacNativeVideoPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#endif

/// The Main ViewModel managing the playback loop, synchronization, and processor pipeline.
@Observable
@MainActor
final class VTPlayerViewModel {
    var videoURL: URL?
    var isPlaying = false
    var isPaused = false
    
    private var lastPublishedCurrentTime = -Double.infinity
    @ObservationIgnored private var isBuffering = false

    // Feature Levels (0 = Off, 2 = 2x, 4 = 4x)
    var superResolutionLevel: Int = 0
    var frameInterpolationLevel: Int = 0

    // New API Feature Levels
    var qualitySuperResolutionScaleFactor: Int = 0  // 0=off, 2, 4 (Quality SR)
    var motionBlurStrength: Int = 0  // 0=off, 1-100
    var denoiseStrength: Double = 0.0  // 0.0=off, 0.0-1.0
    var qualityPrioritization: Int = 1  // 1=normal, 2=quality
    var showSidebar = false
    var showLeftSidebar = true
    
    // Quality Control Parameters
    // Fixed policy for general users. These are intentionally not exposed as
    // settings: stable output takes priority over manual trade-off tuning.
    private let useHighQualityDownsampling = true
    private let useRealTimePriority = true
    
    // Playback Progress & Stats
    var isPipelineActive: Bool {
        #if os(macOS) || os(iOS)
        return (superResolutionLevel > 0 || 
                frameInterpolationLevel > 0 || 
                qualitySuperResolutionScaleFactor > 0 || 
                denoiseStrength > 0 || 
                motionBlurStrength > 0)
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
    
    // Video Track Specs
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    var sourceFrameRate: Double = 0.0
    var videoFormat: String = "Unknown"
    
    // Debug Stats HUD
    var frameProcessingTime: Double = 0.0
    var fps: Double = 0.0
    var displayRate1PercentLow: Double = 0.0
    var displayFrameRate: Double {
        isPipelineActive ? fps : sourceFrameRate * playbackSpeed
    }
    var droppedFrames = 0
    var aneUsagePercent: Double = 0.0
    @ObservationIgnored private var pendingDroppedFrames = 0
    @ObservationIgnored private var lastDiagnosticsPublish = DispatchTime.now()
    
    // Detailed SR Diagnostics
    var srIsSupported: Bool = false
    var srSupportedScales: String = "None"
    /// Scale choices supported for the currently loaded video's dimensions.
    /// These are intentionally separate from the display string so menus can
    /// keep unsupported choices visible but disabled.
    var availableSuperResolutionScales: Set<Int> = []
    var availableQualitySuperResolutionScales: Set<Int> = []
    var srInitializationError: String? = nil
    
    // Recents List
    var recentVideos: [URL] = []
    
    // Fullscreen and Auto-hide HUD controls state
    var isFullScreen = false
    var showControls = true
    var isHoveringControlBar = false
    var showAdjustmentsPopover = false
    
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

    // HDR Tone Mapping (0.0 = off, >0 applies exposure/saturation boost into EDR headroom)
    var hdrStrength: Double = 0.0 {
        didSet {
            renderer.hdrStrength = Float(hdrStrength)
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var cursorHidden = false
    private var inactivityTask: Task<Void, Never>?
    
    // AVPlayer components
    private(set) var player: AVPlayer?
    @ObservationIgnored private var producerTask: Task<Void, Never>?
    @ObservationIgnored private var consumerTask: Task<Void, Never>?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var presentedFramesCount = 0
    @ObservationIgnored private var diagnosticPresentedFramesCount = 0
    @ObservationIgnored private var diagnosticPresentedInterpolatedCount = 0
    @ObservationIgnored private var diagnosticPresentedSourceCount = 0
    @ObservationIgnored private var producedFramesCount = 0
    @ObservationIgnored private var displayLinkTickCount = 0
    @ObservationIgnored private var displayRateSamples: [Double] = []
    @ObservationIgnored private var displayRateMeasurementStart = DispatchTime.now()
    @ObservationIgnored private var fpsTimer = DispatchTime.now()
    @ObservationIgnored private var diagTimer = DispatchTime.now()
    @ObservationIgnored private var processedFrameCache: [VTFrame] = []
    @ObservationIgnored private var processedFrameCacheStart = 0
    @ObservationIgnored private let cacheLock = NSRecursiveLock()
    /// Limit retained presentation frames by bytes, not a fixed frame count.
    /// 4x SR can turn a single 1080p frame into a 33 MP image.
    private let frameCacheMemoryBudget = 512 * 1024 * 1024
    private let maximumFrameCacheCount = 120
    private func lockCache<T>(_ block: () -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return block()
    }

    private func clearProcessedFrameCache() {
        processedFrameCache.removeAll(keepingCapacity: true)
        processedFrameCacheStart = 0
    }

    private func publishCurrentTime(_ seconds: Double, immediately: Bool = false) {
        guard seconds.isFinite else { return }
        guard immediately || abs(seconds - lastPublishedCurrentTime) >= (1.0 / 15.0) else { return }
        lastPublishedCurrentTime = seconds
        currentTime = seconds
    }

    private func publishProcessingDiagnostics(_ processingTime: Double? = nil) {
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

    private func compactProcessedFrameCacheIfNeeded() {
        guard processedFrameCacheStart > 0 else { return }
        let totalCount = processedFrameCache.count
        if processedFrameCacheStart >= 64 || processedFrameCacheStart * 2 >= totalCount {
            processedFrameCache = Array(processedFrameCache[processedFrameCacheStart...])
            processedFrameCacheStart = 0
        }
    }

    private var bufferedFrameLimit: Int {
        let scale = max(1, max(superResolutionLevel, qualitySuperResolutionScaleFactor))
        let outputPixels = Double(videoWidth) * Double(videoHeight) * Double(scale * scale)
        guard outputPixels > 0 else { return maximumFrameCacheCount }

        // The processors normally use YUV, but a four-byte estimate keeps
        // the cache safe if VideoToolbox selects a packed destination format.
        let estimatedBytesPerFrame = max(1.0, outputPixels * 4.0)
        let budgetedFrames = Int(Double(frameCacheMemoryBudget) / estimatedBytesPerFrame)
        return min(maximumFrameCacheCount, max(2, budgetedFrames))
    }

    private var resumeBufferFrameCount: Int {
        min(8, max(2, bufferedFrameLimit / 2))
    }

    /// FI generates frames between adjacent source timestamps. Keeping one
    /// source interval in the presentation queue prevents a late processor
    /// completion from collapsing the interpolated and source frames into one
    /// display refresh.
    private var interpolationPresentationDelay: Double {
        guard frameInterpolationLevel > 0, sourceFrameRate > 0 else { return 0 }
        return 1.0 / sourceFrameRate
    }
    private var outputPresentationInterval: Double {
        guard sourceFrameRate > 0 else { return 1.0 / 30.0 }
        let multiplier: Double
        switch frameInterpolationLevel {
        case 4: multiplier = 4.0
        case 2: multiplier = 2.0
        default: multiplier = 1.0
        }
        return 1.0 / (sourceFrameRate * multiplier)
    }
    private var securityScopedURL: URL?
    #if os(iOS)
    private var tempLocalURL: URL?
    #endif
    private var lastPulledTime: CMTime = .zero
    private var playerItemObserver: Any?
    private var timeJumpedObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var timeObserverToken: Any?
    private var playbackGeneration: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var isInitializingPipeline = false

    // Audio sync monitoring (diagnostic only — never pauses player)
    private var lastRenderedPTS: CMTime = .zero
    // AVPlayer can expose a frame-quantized currentTime for silent or low-rate
    // assets.  Interpolated output must be paced by a monotonic clock between
    // those observations, otherwise two generated frames are drained at once
    // and only one is rendered.
    @ObservationIgnored private var presentationClockAnchorPTS = 0.0
    @ObservationIgnored private var presentationClockAnchorWall = DispatchTime.now()
    @ObservationIgnored private var presentationClockLastPlayerPTS = -Double.infinity
    @ObservationIgnored private var presentationClockInitialized = false
    @ObservationIgnored private var lastPresentationWall = DispatchTime.now()

    private func resetPresentationClock(at seconds: Double) {
        guard seconds.isFinite else { return }
        presentationClockAnchorPTS = seconds
        presentationClockAnchorWall = .now()
        presentationClockLastPlayerPTS = seconds
        presentationClockInitialized = true
        lastPresentationWall = .now()
    }

    private func presentationClockSeconds(playerSeconds: Double) -> Double {
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
    private var audioSyncTask: Task<Void, Never>?
    private let audioSyncLatencyThreshold: Double = 0.1
    
    let renderer: VTMetalRenderer
    let modelManager = VTModelManager()
    private var activeCoordinator: VTFrameProcessorCoordinator?

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
        if cursorHidden {
            NSCursor.unhide()
        }
        #endif
    }
    

    
    private func setupPlayer(with url: URL) {
        // Capability probing is asynchronous. Clear the previous video's
        // scale set immediately so its enabled menu items cannot leak into
        // the new video's loading window.
        availableSuperResolutionScales.removeAll()
        availableQualitySuperResolutionScales.removeAll()
        let asset = AVAsset(url: url)
        let setupGeneration = playbackGeneration
        
        Task {
            do {
                // Load metadata asynchronously using Swift 6 friendly API
                let durationTime = try await asset.load(.duration)
                let durationSecs = CMTimeGetSeconds(durationTime)
                
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    return
                }
                
                // Get video dimensions
                let naturalSize = try await videoTrack.load(.naturalSize)
                let width = Int(naturalSize.width)
                let height = Int(naturalSize.height)
                
                // Get framerate
                let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
                let frameRate = Double(nominalFrameRate)
                
                // Get format description
                var formatStr = "Unknown"
                let descriptions = try await videoTrack.load(.formatDescriptions)
                if let firstDesc = descriptions.first {
                    let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
                    formatStr = "\(fourCharCodeString(subType))"
                }
                
                // Perform SR support checks
                let supported = await VTFrameProcessorCoordinator.isSuperResolutionSupported()
                let scales = await VTFrameProcessorCoordinator.supportedSuperResolutionScaleFactors(width: width, height: height)
                let scalesStr = scales.isEmpty ? "None" : scales.map { String(format: "%.1fx", $0) }.joined(separator: ", ")
                // The app's 4x LL SR mode is a two-stage 2x cascade, so a
                // 2x-capable configuration also makes the 4x menu choice
                // valid. A device that cannot do 2x cannot do our 4x mode.
                #if os(macOS)
                let availableSRScales: Set<Int> = scales.contains(2.0) ? [2, 4] : []
                #else
                // iOS previously relied on the configuration/session
                // boundary rather than this macOS resolution probe. Keep SR
                // choices available when the processor is globally present;
                // the coordinator will report a real session error if it
                // cannot initialize the requested dimensions.
                let availableSRScales: Set<Int> = supported ? [2, 4] : []
                #endif
                var availableQualityScales: Set<Int> = []
                #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
                if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
                   VTSuperResolutionScalerConfiguration.isSupported {
                    // Check both the global scale list and this video's
                    // dimensions. A machine can expose the processor while a
                    // particular resolution still cannot create a session.
                    for scale in VTSuperResolutionScalerConfiguration.supportedScaleFactors where scale == 2 || scale == 4 {
                        if await VTFrameProcessorCoordinator.isQualitySuperResolutionSupported(
                            width: width, height: height, scale: scale
                        ) {
                            availableQualityScales.insert(scale)
                        }
                    }
                }
                #endif

                // Quality SR has a second availability dimension: the
                // per-resolution configuration may exist while its neural
                // network weights are still unavailable. Check the model for
                // this video's first supported quality scale so the main
                // enhancement menu cannot start a guaranteed fallback.
                if let modelScale = availableQualityScales.sorted().first,
                   #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
                   let modelConfig = VTSuperResolutionScalerConfiguration(
                       frameWidth: width, frameHeight: height,
                       scaleFactor: modelScale, inputType: .video,
                       usePrecomputedFlow: false, qualityPrioritization: .normal,
                       revision: .revision1
                   ) {
                    self.modelManager.checkStatus(for: modelConfig)
                }
                
                // AVPlayer owns audio and native fallback presentation. Enhanced
                // video frames are decoded independently by VTFrameSequence.
                let item = AVPlayerItem(asset: asset)

                let newPlayer = AVPlayer(playerItem: item)
                newPlayer.automaticallyWaitsToMinimizeStalling = false
                
                // Update properties on @MainActor
                await MainActor.run {
                    guard setupGeneration == self.playbackGeneration,
                          self.videoURL == url else { return }

                    #if os(macOS)
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    self.recordRecentDateIfNeeded(for: url)
                    self.addRecentVideoMac(url)
                    #endif
                    
                    self.duration = durationSecs
                    self.videoWidth = width
                    self.videoHeight = height
                    self.sourceFrameRate = frameRate
                    self.videoFormat = formatStr
                    self.srIsSupported = supported
                    self.srSupportedScales = scalesStr
                    self.availableSuperResolutionScales = availableSRScales
                    self.availableQualitySuperResolutionScales = availableQualityScales
                    
                    self.player = newPlayer

                    let timeObserver = newPlayer.addPeriodicTimeObserver(
                        forInterval: CMTime(value: 1, timescale: 30),
                        queue: .main
                    ) { [weak self] time in
                        guard let self else { return }
                        let seconds = CMTimeGetSeconds(time)
                        guard seconds.isFinite else { return }
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.videoURL == url else { return }
                            self.publishCurrentTime(seconds)
                        }
                    }
                    self.timeObserverToken = timeObserver
                    
                    // Observe play ending to auto-rewind
                    let observer = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: item,
                        queue: .main
                    ) { [weak self] _ in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.pause()
                            self.seek(to: 0)
                        }
                    }
                    self.playerItemObserver = observer
                    
                    // Observe time jumps (seeks) to sync pipeline iterator
                    let jumpObserver = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemTimeJumped,
                        object: item,
                        queue: .main
                    ) { [weak self] _ in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.handleTimeJump()
                        }
                    }
                    self.timeJumpedObserver = jumpObserver
                    
                    // Observe AVPlayer's timeControlStatus to sync player state with isPaused
                    self.rateObserver = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, change in
                        guard let self = self else { return }
                        Task { @MainActor in
                            switch player.timeControlStatus {
                            case .paused:
                                if !self.isInitializingPipeline {
                                    if !self.isBuffering {
                                        self.isPaused = true
                                    }
                                }
                            case .playing:
                                if !self.isInitializingPipeline {
                                    self.isPaused = false
                                }
                            case .waitingToPlayAtSpecifiedRate:
                                break
                            @unknown default:
                                break
                            }
                        }
                    }
                    
                    // Retrieve and apply saved playback progress
                    let savedProgress = UserDefaults.standard.double(forKey: "VTPlaybackProgress_\(url.lastPathComponent)")
                    if savedProgress > 0 && savedProgress < durationSecs {
                        self.currentTime = savedProgress
                        let cmTime = CMTime(seconds: savedProgress, preferredTimescale: 600)
                        newPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    } else {
                        self.currentTime = 0.0
                    }
                    
                    // Restore per-video enhancement settings
                    self.loadVideoSettings(for: url)
                    self.validateEnhancementSelections()
                    #if os(macOS)
                    self.setNativeVideoEnabled(!self.isPipelineActive)
                    #endif

                    // Start rendering/processing loop
                    self.play()
                }
            } catch {
                print("Error loading video properties: \(error.localizedDescription)")
                #if os(iOS)
                // Remove stale URL from recents so it won't be retried
                if let idx = self.recentVideos.firstIndex(of: url) {
                    self.deleteRecentVideoIOS(at: IndexSet(integer: idx))
                }
                #endif
            }
        }
    }
    
    func saveProgress() {
        guard let url = videoURL else { return }
        UserDefaults.standard.set(self.currentTime, forKey: "VTPlaybackProgress_\(url.lastPathComponent)")
    }
    
    #if os(macOS)
    @objc func reloadRecentVideos() {
        let removed = UserDefaults.standard.stringArray(forKey: "VTRemovedRecentVideos") ?? []
        let urls = NSDocumentController.shared.recentDocumentURLs.filter { url in
            !removed.contains(url.path)
        }

        // NSDocumentController orders these by most recently opened, while
        // the sidebar's default sort is the date the item was added.
        var dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDatesMac") as? [String: Double] ?? [:]
        let migrationNow = Date().timeIntervalSince1970
        for (index, url) in urls.enumerated() where dates[url.path] == nil {
            dates[url.path] = migrationNow - Double(index)
        }
        UserDefaults.standard.set(dates, forKey: "VTRecentVideosDatesMac")
        self.recentVideos = urls
    }

    private func recordRecentDateIfNeeded(for url: URL) {
        var dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDatesMac") as? [String: Double] ?? [:]
        guard dates[url.path] == nil else { return }
        dates[url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dates, forKey: "VTRecentVideosDatesMac")
    }

    private func addRecentVideoMac(_ url: URL) {
        var removed = UserDefaults.standard.stringArray(forKey: "VTRemovedRecentVideos") ?? []
        removed.removeAll { $0 == url.path }
        if removed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "VTRemovedRecentVideos")
        } else {
            UserDefaults.standard.set(removed, forKey: "VTRemovedRecentVideos")
        }

        var urls = NSDocumentController.shared.recentDocumentURLs.filter { recentURL in
            !removed.contains(recentURL.path)
        }
        if !urls.contains(url) {
            urls.insert(url, at: 0)
        }
        recentVideos = urls
    }
    
    func deleteRecentVideoMac(at url: URL) {
        let wasSelected = videoURL == url

        var dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDatesMac") as? [String: Double] ?? [:]
        dates.removeValue(forKey: url.path)
        UserDefaults.standard.set(dates, forKey: "VTRecentVideosDatesMac")

        var removed = UserDefaults.standard.stringArray(forKey: "VTRemovedRecentVideos") ?? []
        if !removed.contains(url.path) {
            removed.append(url.path)
            UserDefaults.standard.set(removed, forKey: "VTRemovedRecentVideos")
        }
        reloadRecentVideos()

        if wasSelected {
            stop()
            videoURL = nil
        }
    }

    func clearRecentVideosMac() {
        let hadSelectedVideo = videoURL != nil
        NSDocumentController.shared.clearRecentDocuments(nil)
        UserDefaults.standard.removeObject(forKey: "VTRemovedRecentVideos")
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosDatesMac")
        reloadRecentVideos()

        if hadSelectedVideo {
            stop()
            videoURL = nil
        }
    }
    #endif
    
    func openVideo(_ url: URL) {
        self.stop()
        
        var targetURL = url
        
        // Release any previously held security-scoped resource
        if let prev = securityScopedURL {
            prev.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
        
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        if isSecurityScoped {
            self.securityScopedURL = url
        }
        
        #if os(iOS)
        self.tempLocalURL = nil
        
        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent(url.lastPathComponent)
        
        // Copy to sandbox temp so the file remains readable after any
        // security-scoped grant is released.  When the URL already points
        // to the temp directory (e.g. from Photos Library), skip the copy
        // to avoid deleting the source file.
        do {
            if url.standardizedFileURL != destinationURL.standardizedFileURL {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: url, to: destinationURL)
            }
            self.tempLocalURL = destinationURL
            targetURL = destinationURL
            print("Video ready at: \(targetURL.path)")
        } catch {
            print("Failed to copy video to sandbox: \(error.localizedDescription)")
            // Fall back to using the original URL directly
            targetURL = url
        }
        
        // Release security-scoped access now that the copy is complete,
        // UNLESS we failed to copy and fell back to the original URL.
        if isSecurityScoped {
            if targetURL.standardizedFileURL != url.standardizedFileURL {
                url.stopAccessingSecurityScopedResource()
                self.securityScopedURL = nil
            }
        }
        
        self.addToRecentVideosIOS(targetURL)
        #endif
        
        self.videoURL = targetURL
        self.setupPlayer(with: targetURL)
    }
    
    func openRecentVideo(_ url: URL) {
        #if os(iOS)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let idx = recentVideos.firstIndex(of: url) {
                deleteRecentVideoIOS(at: IndexSet(integer: idx))
            }
            return
        }
        #endif
        self.openVideo(url)
    }
    
    #if os(macOS)
    @objc private func windowDidEnterFullScreen() {
        self.isFullScreen = true
        self.userActivityDetected()
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            window.backgroundColor = .black
        }
    }
    
    @objc private func windowDidExitFullScreen() {
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
    
    private func startInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            guard !Task.isCancelled, let self = self else { return }
            #if os(iOS)
            let shouldHide = self.isPlaying && !self.isPaused
            #else
            let shouldHide = self.isPlaying && !self.isPaused && !self.isHoveringControlBar && !self.showAdjustmentsPopover
            #endif
            if shouldHide {
                self.showControls = false
                #if os(macOS)
                if self.isFullScreen && !self.cursorHidden {
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

    private func handleTimeJump() {
        guard let player = player else { return }
        let currentTime = player.currentTime()
        
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

    private func triggerSingleFrameUpdate(
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
    private func readSingleFrame(from url: URL, at time: CMTime) async -> VTFrame? {
        await Task.detached(priority: .userInitiated) {
            Self.decodeSingleFrame(from: url, at: time)
        }.value
    }

    nonisolated private static func decodeSingleFrame(from url: URL, at time: CMTime) -> VTFrame? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
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
    private var enhancementsPendingRestart = false

    /// Updates coordinator when features are toggled without changing playback state.
    func updateEnhancements() {
        validateEnhancementSelections()
        #if os(macOS)
        setNativeVideoEnabled(!isPipelineActive)
        #endif
        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        if isPlaying && !isPaused {
            if isPipelineActive {
                startPlaybackLoop()
            } else {
                stopPlaybackLoopOnly()
                if let player {
                    player.play()
                    player.rate = Float(playbackSpeed)
                    self.isPaused = false
                }
            }
        } else if isPlaying && isPaused {
            // Don't restart the pipeline while paused — the cache clear
            // would cause a visible freeze on resume.  Flag it so play()
            // rebuilds the pipeline when the user unpauses.
            enhancementsPendingRestart = true
        }
        #endif
    }
    
    /// Toggles play and pause state.
    func togglePlayPause() {
        guard player != nil else { return }
        if isPaused || !isPlaying {
            play()
        } else {
            pause()
        }
    }
    
    /// Starts playback and the VideoToolbox processing loop.
    func play() {
        guard let player = player else { return }

        self.isPlaying = true
        self.isPaused = false

        #if os(macOS)
        renderer.setRenderingActive(true)
        #endif

        player.rate = Float(self.playbackSpeed)

        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        // Rebuild the pipeline if enhancements were changed while paused,
        // or if the loop has not yet been initialized. Otherwise, the existing
        // active loop will automatically resume processing when isPaused is false.
        if isPipelineActive {
            if enhancementsPendingRestart || producerTask == nil {
                enhancementsPendingRestart = false
                startPlaybackLoop()
            } else {
                startDisplayLinkIfNeeded()
            }
        } else {
            #if os(macOS)
            setNativeVideoEnabled(true)
            #endif
            stopPlaybackLoopOnly()
        }
        #endif
        self.userActivityDetected()
    }

    /// Drop persisted or programmatically assigned enhancement values that
    /// the current machine/video cannot actually run. Menu disabling is only
    /// a UI affordance; this guard protects the pipeline from stale state.
    private func validateEnhancementSelections() {
        var disabledSelection = false
        if superResolutionLevel > 0,
           !availableSuperResolutionScales.contains(superResolutionLevel) {
            superResolutionLevel = 0
            disabledSelection = true
        }
        if qualitySuperResolutionScaleFactor > 0,
           !availableQualitySuperResolutionScales.contains(qualitySuperResolutionScaleFactor) {
            qualitySuperResolutionScaleFactor = 0
            disabledSelection = true
        }
        if disabledSelection {
            srInitializationError = "Selected super-resolution mode is unavailable for this video on this device."
        }
    }
    
    /// Pauses player
    func pause() {
        guard let player = player else { return }
        player.pause()
        resetPresentationClock(at: CMTimeGetSeconds(player.currentTime()))
        self.isPaused = true
        self.isBuffering = false
        #if os(macOS)
        renderer.setRenderingActive(false)
        stopDisplayLinkIfNeeded()
        #else
        if let link = displayLink {
            link.invalidate()
            self.displayLink = nil
        }
        #endif
        self.saveProgress()
        self.saveVideoSettings()
        self.userActivityDetected()
    }
    
    #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
    private func endActiveCoordinator(after producer: Task<Void, Never>? = nil) {
        let coordinator = activeCoordinator
        activeCoordinator = nil
        guard let coordinator else { return }

        let producer = producer ?? producerTask
        producer?.cancel()
        Task {
            if let producer {
                await producer.value
            }
            await coordinator.endSession()
        }
    }

    private func stopDisplayLinkIfNeeded() {
        #if os(macOS)
        renderer.onDisplayTick = nil
        #endif
        if let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    #if os(macOS)
    private func setNativeVideoEnabled(_ enabled: Bool) {
        guard let tracks = player?.currentItem?.tracks else { return }
        for track in tracks where track.assetTrack?.mediaType == .video {
            track.isEnabled = enabled
        }
        // Keep audio explicitly enabled across pipeline restarts. AVPlayer
        // owns the audio clock even while native video is hidden.
        for track in tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = true
        }
    }
    #endif

    private func stopPlaybackLoopOnly() {
        #if os(macOS)
        renderer.setRenderingActive(false)
        setNativeVideoEnabled(true)
        stopDisplayLinkIfNeeded()
        #endif
        playbackGeneration += 1
        let producer = producerTask
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        endActiveCoordinator(after: producer)

        #if !os(macOS)
        if let link = displayLink {
            link.invalidate()
            self.displayLink = nil
        }
        #endif
        
        audioSyncTask?.cancel()
        audioSyncTask = nil
        audioSyncLatency = 0
        presentedFramesCount = 0
        diagnosticPresentedFramesCount = 0
        diagnosticPresentedInterpolatedCount = 0
        diagnosticPresentedSourceCount = 0
        producedFramesCount = 0
        displayLinkTickCount = 0
        displayRateSamples.removeAll(keepingCapacity: true)
        displayRate1PercentLow = 0
        displayRateMeasurementStart = .now()
        isBuffering = false
        lockCache { clearProcessedFrameCache() }
    }

    private func startPlaybackLoop() {
        let shouldResumePlayback = isPlaying && !isPaused
        #if os(macOS)
        setNativeVideoEnabled(false)
        #endif
        isBuffering = false
        playbackGeneration += 1
        let gen = playbackGeneration
        let oldProducer = producerTask
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        endActiveCoordinator(after: oldProducer)

        let sourceFPS = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30.0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(sourceFPS))
        #if os(macOS)
        let adaptiveFISize: CGSize? = {
            guard frameInterpolationLevel > 0 else { return nil }
            let combinedMode = superResolutionLevel == 2 && frameInterpolationLevel == 2
            guard combinedMode || videoWidth > 1280 || videoHeight > 720 else { return nil }
            // Combined 2x SR + 2x FI is the heaviest real-time mode. When
            // possible, feed it a smaller source so the processor has enough
            // headroom to produce every output phase on time. Keep the normal
            // FI cap for pure interpolation.
            if combinedMode {
                // Probe the actual temporal-first configuration. A combined
                // FI+spatial initializer may accept 480×270 while the pure
                // FI configuration used by the stable sequential path
                // rejects it at processing time on this Mac.
                func alignedDimension(_ value: Double, maximum: Int) -> Int {
                    // VideoToolbox's SR/FI implementations commonly require
                    // macroblock-friendly heights. Flooring 266.7 to 266
                    // made the 960x400 path fail, while the equivalent 272
                    // pixel input is supported. Round up within the probe
                    // bound so we preserve aspect ratio without selecting a
                    // known-invalid odd-size surface.
                    let rounded = Int(ceil(value / 16.0) * 16.0)
                    return min(maximum, max(2, rounded & ~1))
                }
                for (maxWidth, maxHeight) in [(640.0, 360.0), (960.0, 540.0)] {
                    let scale = min(1.0, maxWidth / Double(videoWidth), maxHeight / Double(videoHeight))
                    let candidateWidth = alignedDimension(Double(videoWidth) * scale, maximum: Int(maxWidth))
                    let candidateHeight = alignedDimension(Double(videoHeight) * scale, maximum: Int(maxHeight))
                    guard candidateWidth > 0, candidateHeight > 0 else { continue }
                    if VTLowLatencySuperResolutionScalerConfiguration
                        .supportedScaleFactors(frameWidth: candidateWidth, frameHeight: candidateHeight)
                        .contains(2.0),
                       VTLowLatencyFrameInterpolationConfiguration(
                           frameWidth: candidateWidth,
                           frameHeight: candidateHeight,
                           numberOfInterpolatedFrames: 1
                       ) != nil {
                        return CGSize(width: candidateWidth, height: candidateHeight)
                    }
                }
                return nil
            }
            let scale = min(1280.0 / Double(videoWidth), 720.0 / Double(videoHeight))
            let candidate = CGSize(width: ceil(Double(videoWidth) * scale / 16) * 16,
                                   height: ceil(Double(videoHeight) * scale / 16) * 16)
            return candidate
        }()
        #else
        // Keep the pre-existing iOS path: decode at the source dimensions and
        // let CADisplayLink/VideoToolbox choose the native playback cadence.
        let adaptiveFISize: CGSize? = nil
        #endif
        let pipelineWidth = Int(adaptiveFISize?.width ?? CGFloat(videoWidth))
        let pipelineHeight = Int(adaptiveFISize?.height ?? CGFloat(videoHeight))
        let targetFrameRate = sourceFrameRate * (frameInterpolationLevel > 0 ? Double(frameInterpolationLevel) : 1.0)
        NSLog("PIPELINE: source=\(videoWidth)x\(videoHeight) input=\(pipelineWidth)x\(pipelineHeight) fi=\(frameInterpolationLevel)x sr=\(superResolutionLevel)x qsr=\(qualitySuperResolutionScaleFactor)x sourceFPS=\(String(format: "%.3f", sourceFrameRate)) targetFPS=\(String(format: "%.3f", targetFrameRate))")

        lockCache { clearProcessedFrameCache() }
        if let player = player {
            let adjusted = CMTimeSubtract(player.currentTime(), frameDuration)
            lastPulledTime = adjusted > .zero ? adjusted : .zero
            lastRenderedPTS = player.currentTime()
            resetPresentationClock(at: CMTimeGetSeconds(player.currentTime()))
        } else {
            lastPulledTime = .zero
            lastRenderedPTS = .zero
            resetPresentationClock(at: 0)
        }
        audioSyncLatency = 0

        // Re-assert player rate so audio keeps playing after a pipeline
        // restart triggered by updateEnhancements().  Without this, a
        // rate that dropped to 0 (AVPlayer internal stall) stays silent
        // because the old audioSyncTask was already cancelled and the new
        // one won't check for 200 ms.
        if let player = player, !isPaused {
            player.rate = Float(playbackSpeed)
        }

        let srLevel = self.superResolutionLevel
        let fiLevel = self.frameInterpolationLevel
        let highQuality = self.useHighQualityDownsampling
        let realTime = self.useRealTimePriority
        let qualitySR = self.qualitySuperResolutionScaleFactor
        let mbStrength = self.motionBlurStrength
        let dnStrength = self.denoiseStrength
        let qualPrior = self.qualityPrioritization

        producerTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            defer {
                // A replacement loop has a newer generation. Never let a
                // cancelled predecessor erase its producer handle.
                if self.playbackGeneration == gen {
                    self.producerTask = nil
                }
            }

            // Check Quality SR model availability before starting (macOS only)
            var effectiveQualitySR = qualitySR
            var effectiveSRLevel = srLevel
            
            #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
            @MainActor func fallBackFromQualitySR() {
                effectiveQualitySR = 0
                let requestedFallback = qualitySR == 4 ? 4 : 2
                if self.availableSuperResolutionScales.contains(requestedFallback) {
                    effectiveSRLevel = requestedFallback
                } else if self.availableSuperResolutionScales.contains(2) {
                    effectiveSRLevel = 2
                } else {
                    effectiveSRLevel = 0
                }

                // Keep the controls truthful: the visible selection must
                // match the processor that will actually run.
                self.qualitySuperResolutionScaleFactor = 0
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
                    await self.modelManager.checkStatus(for: checkConfig)
                    switch self.modelManager.status {
                    case .ready:
                        break
                    case .downloadRequired:
                        print("Quality SR model download required, starting download")
                        self.modelManager.downloadModel(for: checkConfig)
                        fallBackFromQualitySR()
                    case .downloading:
                        fallBackFromQualitySR()
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
                let supportedScales = VTLowLatencySuperResolutionScalerConfiguration
                    .supportedScaleFactors(frameWidth: videoWidth, frameHeight: videoHeight)
                if !supportedScales.contains(2.0) {
                    self.srInitializationError = "Low Latency SR does not support \(videoWidth)x\(videoHeight) on this device; enhancement disabled."
                    effectiveSRLevel = 0
                    print("Low Latency SR unavailable for \(videoWidth)x\(videoHeight): \(supportedScales)")
                }
            }
            #endif
            #endif
            var coordinator = VTFrameProcessorCoordinator(
                superResolutionLevel: effectiveSRLevel,
                frameInterpolationLevel: fiLevel,
                useHighQualityDownsampling: highQuality,
                useRealTimePriority: realTime,
                qualitySuperResolutionScaleFactor: effectiveQualitySR,
                motionBlurStrength: mbStrength,
                denoiseStrength: dnStrength,
                qualityPrioritization: qualPrior
            )
            guard !Task.isCancelled, gen == self.playbackGeneration else { return }
            self.activeCoordinator = coordinator

            // Pause the player during coordinator init so the audio clock
            // doesn't advance while the cache is empty.  Without this, the
            // consumer stalls (empty cache) while audio keeps running,
            // creating an audible gap followed by a video jump.
            self.isInitializingPipeline = true
            let wasRate = self.player?.rate ?? 0
            self.player?.pause()

            do {
                if (effectiveSRLevel > 0 || effectiveQualitySR > 0 || (srLevel == 0 && qualitySR == 0)),
                   self.srInitializationError == nil {
                    self.srInitializationError = nil
                }
                try await coordinator.startSession(width: pipelineWidth, height: pipelineHeight)
            } catch {
                guard gen == self.playbackGeneration else { return }
                await coordinator.endSession()

                // The combined VideoToolbox processor is capability- and
                // resolution-dependent.  Its configuration initializer can
                // succeed while session creation still rejects the actual
                // pixel-buffer requirements.  Do not reset playback to time
                // zero in that case: retry as FI-only at the same adaptive
                // input size and make the fallback visible in diagnostics.
                if effectiveSRLevel == 2 && fiLevel == 2 && effectiveQualitySR == 0 {
                    let message = "Combined 2x SR + 2x FI unavailable at \(pipelineWidth)x\(pipelineHeight); using FI-only."
                    self.srInitializationError = message
                    print("Failed to initialize combined SR/FI session: \(error.localizedDescription). Retrying FI-only.")

                    effectiveSRLevel = 0
                    self.superResolutionLevel = 0
                    coordinator = VTFrameProcessorCoordinator(
                        superResolutionLevel: 0,
                        frameInterpolationLevel: fiLevel,
                        useHighQualityDownsampling: highQuality,
                        useRealTimePriority: realTime,
                        qualitySuperResolutionScaleFactor: 0,
                        motionBlurStrength: mbStrength,
                        denoiseStrength: dnStrength,
                        qualityPrioritization: qualPrior
                    )
                    self.activeCoordinator = coordinator
                    do {
                        try await coordinator.startSession(width: pipelineWidth, height: pipelineHeight)
                    } catch {
                        self.srInitializationError = "FI fallback unavailable: \(error.localizedDescription)"
                        print("Failed to initialize FI fallback session: \(error.localizedDescription)")
                        self.activeCoordinator = nil
                        await coordinator.endSession()
                        self.stop()
                        return
                    }
                } else {
                    self.srInitializationError = error.localizedDescription
                    print("Failed to initialize coordinator session: \(error.localizedDescription)")
                    self.activeCoordinator = nil
                    self.stop()
                    return
                }
            }

            // Re-sync lastPulledTime after potentially slow coordinator setup
            // and resume the player from the same position.
            if let player = self.player {
                let resumeTime = player.currentTime()
                self.lastPulledTime = resumeTime
                self.lastRenderedPTS = resumeTime
                self.resetPresentationClock(at: CMTimeGetSeconds(resumeTime))
                await player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
                let shouldResume = shouldResumePlayback && gen == self.playbackGeneration
                self.isInitializingPipeline = false
                if shouldResume {
                    self.isPlaying = true
                    self.isPaused = false
                    player.rate = wasRate != 0 ? wasRate : Float(self.playbackSpeed)
                } else {
                    player.pause()
                }
            } else {
                self.isInitializingPipeline = false
            }

            // Create VTFrameSequence to decode frames faster-than-real-time
            guard let videoURL = self.videoURL else {
                self.activeCoordinator = nil
                await coordinator.endSession()
                return
            }
            var iteratorStartTime = self.lastPulledTime
            let frameSequence = VTFrameSequence(url: videoURL, startTime: iteratorStartTime, outputSize: adaptiveFISize)
            var frameIterator = frameSequence.makeAsyncIterator()
            var combinedProcessFallbackAttempted = false

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
                    iteratorStartTime = self.lastPulledTime
                    let newSequence = VTFrameSequence(url: videoURL, startTime: iteratorStartTime, outputSize: adaptiveFISize)
                    frameIterator = newSequence.makeAsyncIterator()
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
                do {
                    guard let next = try await frameIterator.next() else {
                        break  // EOF
                    }
                    vtFrame = next
                } catch {
                    print("VTFrameSequence error: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                // Drop late frames to maintain real-time audio-video synchronization.
                // Do not drop frames if the cache is completely empty (e.g. after seek or startup),
                // to avoid getting stuck in a dropping loop before the rendering loop recovers.
                if let player = self.player, !self.isPaused, player.rate > 0 {
                    let currentSecs = self.presentationClockSeconds(
                        playerSeconds: CMTimeGetSeconds(player.currentTime())
                    )
                    let frameSecs = CMTimeGetSeconds(vtFrame.presentationTimeStamp)
                    // If the frame is late by more than 100ms, skip processing it
                    let isEmpty = self.lockCache {
                        self.processedFrameCacheStart >= self.processedFrameCache.count
                    }
                    if !isEmpty && frameSecs < currentSecs - 0.10 {
                        self.pendingDroppedFrames += 1
                        self.publishProcessingDiagnostics()
                        continue
                    }
                }

                // Process through the VideoToolbox pipeline
                let processStart = DispatchTime.now()
                do {
                    let outputFrames = try await coordinator.processFrame(vtFrame)
                    let processEnd = DispatchTime.now()

                    guard gen == self.playbackGeneration else { break }

                    self.publishProcessingDiagnostics(
                        Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000.0
                    )
                    let processingMilliseconds = Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000.0
                    let sourceFrameBudgetMilliseconds = sourceFPS > 0 ? 1_000.0 / sourceFPS : 0
                    if frameInterpolationLevel > 0,
                       processingMilliseconds > sourceFrameBudgetMilliseconds {
                        let processingText = String(format: "%.1f", processingMilliseconds)
                        let budgetText = String(format: "%.1f", sourceFrameBudgetMilliseconds)
                        print("PERF: FI deadline miss processing=\(processingText)ms budget=\(budgetText)ms outputs=\(outputFrames.count) sr=\(effectiveSRLevel) qsr=\(effectiveQualitySR) size=\(pipelineWidth)x\(pipelineHeight)")
                    }

                    if outputFrames.count < 2 && self.frameInterpolationLevel > 0 {
                        print("⚠️ FI: expected >=2 output frames, got \(outputFrames.count) for frame at \(CMTimeGetSeconds(vtFrame.presentationTimeStamp))")
                    }

                    // Insert output frames in PTS-sorted order using binary
                    // search.  The cache is already sorted and output frames
                    // arrive roughly in order, so this is O(log n) per frame
                    // instead of re-sorting the entire array every time.
                    self.lockCache {
                        for outFrame in outputFrames {
                            let pts = outFrame.presentationTimeStamp
                            var lo = self.processedFrameCacheStart
                            var hi = self.processedFrameCache.count
                            while lo < hi {
                                let mid = (lo + hi) / 2
                                if self.processedFrameCache[mid].presentationTimeStamp < pts {
                                    lo = mid + 1
                                } else {
                                    hi = mid
                                }
                            }
                            self.processedFrameCache.insert(outFrame, at: lo)
                        }
                        self.compactProcessedFrameCacheIfNeeded()
                    }
                    self.producedFramesCount += outputFrames.count
                } catch {
                    guard gen == self.playbackGeneration else { break }
                    if effectiveSRLevel == 2 && fiLevel == 2 && effectiveQualitySR == 0 && !combinedProcessFallbackAttempted {
                        combinedProcessFallbackAttempted = true
                        self.superResolutionLevel = 0
                        self.srInitializationError = "Combined 2x SR + 2x FI failed during processing (\(error.localizedDescription)); using FI-only."
                        print("⚠️ Combined SR/FI processing failed: \(error.localizedDescription). Restarting as FI-only.")
                        self.startPlaybackLoop()
                        break
                    }
                    print("⚠️ Pipeline processing error: \(error) — preserving source frame; fi=\(fiLevel) sr=\(effectiveSRLevel) qsr=\(effectiveQualitySR) size=\(pipelineWidth)x\(pipelineHeight)")
                    self.lockCache { self.processedFrameCache.append(vtFrame) }
                    self.producedFramesCount += 1
                }
            }

            await coordinator.endSession()
            if self.playbackGeneration == gen {
                self.activeCoordinator = nil
            }
        }
        
        startDisplayLinkIfNeeded()

        audioSyncTask?.cancel()
        audioSyncTask = Task {
            let myGen = gen
            while !Task.isCancelled {
                guard myGen == self.playbackGeneration else { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !self.isPaused, let player = self.player else { continue }
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

                // AVPlayer may stop playback (rate → 0) if its audio decoder fails
                // on certain file formats. Periodically re-assert the desired rate
                // to kickstart the decoder. This does NOT pause — it only recovers.
                if player.rate == 0 && self.isPlaying && !self.isPaused && !self.isInitializingPipeline {
                    player.rate = Float(self.playbackSpeed)
                }
            }
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }

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
        #endif
        #if !os(macOS)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
        #endif
    }
    #endif

    @MainActor
    private func tickDisplayLink() {
        guard isPlaying && !isPaused, let player = self.player else { return }
        displayLinkTickCount += 1
        
        let currentTime = player.currentTime()
        let observedSecs = CMTimeGetSeconds(currentTime)
        let currentSecs = presentationClockSeconds(playerSeconds: observedSecs)
        let presentationSecs = currentSecs - interpolationPresentationDelay
        
        var lastFrameToRender: VTFrame? = nil
        var drained = 0
        let now = DispatchTime.now()
        let wallElapsed = Double(now.uptimeNanoseconds - lastPresentationWall.uptimeNanoseconds) / 1_000_000_000.0
        // MTKView callbacks may arrive around 48 Hz on a 60 Hz display.
        // Requiring 90% of the 33 ms FI2 interval then presents every other
        // callback (~24 Hz). A bounded 60% threshold lets the scheduler
        // alternate one- and two-callback gaps, converging on the requested
        // 30 Hz without allowing an unbounded burst.
        let canForceNextFrame = wallElapsed >= outputPresentationInterval * 0.6
        #if os(macOS)
        let useWallClockPacing = frameInterpolationLevel > 0 && sourceFrameRate > 0
        #else
        // iOS uses CADisplayLink plus immediate MTKView rendering. Preserve
        // its established timestamp pacing instead of adding the macOS
        // wall-clock gate to every display callback.
        let useWallClockPacing = false
        #endif
        
        self.lockCache {
            if useWallClockPacing {
                // FI output has a fixed cadence independent of the display
                // callback cadence. Present at most one queued frame per
                // wall-clock deadline; draining every PTS-eligible frame can
                // turn 2x output into source-rate output when callbacks are
                // delivered at an uneven ~45 Hz cadence.
                guard canForceNextFrame else { return }

                // Discard frames that are already behind the last visible
                // timestamp, but never consume two eligible frames in one
                // display callback.
                while self.processedFrameCacheStart < self.processedFrameCache.count,
                      self.processedFrameCache[self.processedFrameCacheStart].presentationTimeStamp <= self.lastRenderedPTS {
                    self.processedFrameCacheStart += 1
                    drained += 1
                }

                guard self.processedFrameCacheStart < self.processedFrameCache.count else { return }
                let firstFrame = self.processedFrameCache[self.processedFrameCacheStart]
                let frameTime = CMTimeGetSeconds(firstFrame.presentationTimeStamp)
                // Keep audio/video bounded: a frame may lead the audio clock
                // by at most 80 ms while the wall-clock cadence is restored.
                guard frameTime <= presentationSecs + 0.08 else { return }
                lastFrameToRender = firstFrame
                self.lastRenderedPTS = firstFrame.presentationTimeStamp
                drained += 1
                self.processedFrameCacheStart += 1
            } else {
                while self.processedFrameCacheStart < self.processedFrameCache.count {
                    let firstFrame = self.processedFrameCache[self.processedFrameCacheStart]
                    let frameTime = CMTimeGetSeconds(firstFrame.presentationTimeStamp)
                    if frameTime > presentationSecs + 0.005 {
                        break
                    }

                    lastFrameToRender = firstFrame
                    self.lastRenderedPTS = firstFrame.presentationTimeStamp
                    drained += 1
                    self.processedFrameCacheStart += 1
                }
            }
            self.compactProcessedFrameCacheIfNeeded()
        }
        
        if let frame = lastFrameToRender {
            self.renderer.render(pixelBuffer: frame.buffer, isInterpolated: frame.isInterpolated)
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
        let elapsedFPSTime = Double(statsNow.uptimeNanoseconds - fpsTimer.uptimeNanoseconds) / 1_000_000_000.0
        if elapsedFPSTime >= 1.0 {
            let measuredRate = Double(presentedFramesCount) / elapsedFPSTime
            self.fps = measuredRate
            let measurementAge = Double(statsNow.uptimeNanoseconds - displayRateMeasurementStart.uptimeNanoseconds) / 1_000_000_000.0
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
        
        let diagElapsed = Double(now.uptimeNanoseconds - diagTimer.uptimeNanoseconds) / 1_000_000_000.0
        if diagElapsed >= 5.0 {
            let curRate = player.rate
            let curFPS = self.fps
            var firstFrame: VTFrame? = nil
            var cacheCount = 0
            self.lockCache {
                if self.processedFrameCacheStart < self.processedFrameCache.count {
                    firstFrame = self.processedFrameCache[self.processedFrameCacheStart]
                }
                cacheCount = max(0, self.processedFrameCache.count - self.processedFrameCacheStart)
            }
            
            let produced = producedFramesCount
            let callbacks = displayLinkTickCount
            let presented = diagnosticPresentedFramesCount
            let interpolated = diagnosticPresentedInterpolatedCount
            let source = diagnosticPresentedSourceCount
            if let first = firstFrame {
                let ft = CMTimeGetSeconds(first.presentationTimeStamp)
                NSLog("DIAG: cache=\(cacheCount) currentSecs=\(String(format: "%.3f", currentSecs)) nextPTS=\(String(format: "%.3f", ft)) rate=\(curRate) produced5s=\(produced) callbacks5s=\(callbacks) presented5s=\(presented) interp5s=\(interpolated) source5s=\(source) rendered=\(curFPS)")
            } else {
                NSLog("DIAG: cache=0 currentSecs=\(String(format: "%.3f", currentSecs)) rate=\(curRate) produced5s=\(produced) callbacks5s=\(callbacks) presented5s=\(presented) interp5s=\(interpolated) source5s=\(source) rendered=\(curFPS)")
            }
            producedFramesCount = 0
            displayLinkTickCount = 0
            diagnosticPresentedFramesCount = 0
            diagnosticPresentedInterpolatedCount = 0
            diagnosticPresentedSourceCount = 0
            diagTimer = now
        }
    }

    @objc private func caDisplayLinkTick() {
        self.tickDisplayLink()
    }

    /// Pauses/stops playback entirely.
    func stop() {
        #if os(macOS)
        renderer.setRenderingActive(false)
        setNativeVideoEnabled(false)
        stopDisplayLinkIfNeeded()
        #endif
        playbackGeneration += 1
        seekGeneration &+= 1
        if self.currentTime > 0 {
            self.saveProgress()
        }
        saveVideoSettings()
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        let producer = producerTask
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        endActiveCoordinator(after: producer)
        #if os(macOS)
        stopDisplayLinkIfNeeded()
        #else
        if let link = displayLink {
            link.invalidate()
            self.displayLink = nil
        }
        #endif
        #if os(iOS)
        self.tempLocalURL = nil
        #endif
        if let scoped = securityScopedURL {
            scoped.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
        audioSyncTask?.cancel()
        audioSyncTask = nil
        audioSyncLatency = 0
        lastRenderedPTS = .zero
        lockCache { clearProcessedFrameCache() }
        
        if let observer = playerItemObserver {
            NotificationCenter.default.removeObserver(observer)
            playerItemObserver = nil
        }
        if let observer = timeJumpedObserver {
            NotificationCenter.default.removeObserver(observer)
            timeJumpedObserver = nil
        }
        rateObserver?.invalidate()
        rateObserver = nil
        player?.pause()
        player = nil
        
        self.isPlaying = false
        self.isPaused = false
        self.isBuffering = false
        self.currentTime = 0.0
        self.lastPublishedCurrentTime = -Double.infinity
        self.duration = 0.0
        self.fps = 0.0
        self.displayRate1PercentLow = 0.0
        self.presentedFramesCount = 0
        self.diagnosticPresentedFramesCount = 0
        self.diagnosticPresentedInterpolatedCount = 0
        self.diagnosticPresentedSourceCount = 0
        self.producedFramesCount = 0
        self.displayLinkTickCount = 0
        self.displayRateSamples.removeAll(keepingCapacity: true)
        self.displayRateMeasurementStart = .now()
        self.frameProcessingTime = 0.0
        self.aneUsagePercent = 0.0
        self.srInitializationError = nil
        self.isInitializingPipeline = false
        self.enhancementsPendingRestart = false
        self.renderer.clear()
        self.userActivityDetected()
    }

    // MARK: - Per-Video Settings Persistence

    private static func videoSettingsKey(for path: String) -> String {
        return "VTSettings_\(path)"
    }

    private func saveVideoSettings() {
        guard let url = videoURL else { return }
        let settings: [String: Any] = [
            "superResolutionLevel": superResolutionLevel,
            "frameInterpolationLevel": frameInterpolationLevel,
            "playbackSpeed": playbackSpeed,
            "sharpness": sharpness,
            "hdrStrength": hdrStrength,
            "qualitySuperResolutionScaleFactor": qualitySuperResolutionScaleFactor,
            "motionBlurStrength": motionBlurStrength,
            "denoiseStrength": denoiseStrength,
            "qualityPrioritization": qualityPrioritization,
        ]
        UserDefaults.standard.set(settings, forKey: Self.videoSettingsKey(for: url.lastPathComponent))
    }

    private func loadVideoSettings(for url: URL) {
        guard let settings = UserDefaults.standard.dictionary(forKey: Self.videoSettingsKey(for: url.lastPathComponent)) else {
            applyDefaultPlaybackSettings()
            return
        }
        superResolutionLevel = settings["superResolutionLevel"] as? Int ?? 0
        frameInterpolationLevel = settings["frameInterpolationLevel"] as? Int ?? 0
        playbackSpeed = settings["playbackSpeed"] as? Double ?? 1.0
        let loadedSharpness = settings["sharpness"] as? Double ?? 0.0
        if loadedSharpness != sharpness {
            sharpness = loadedSharpness
        }
        renderer.sharpness = Float(sharpness)
        hdrStrength = settings["hdrStrength"] as? Double ?? 0.0
        renderer.hdrStrength = Float(hdrStrength)
        qualitySuperResolutionScaleFactor = settings["qualitySuperResolutionScaleFactor"] as? Int ?? 0
        // Migrate: QL SR only supports 4x, convert old 2x setting to LL SR 2x
        if qualitySuperResolutionScaleFactor == 2 {
            qualitySuperResolutionScaleFactor = 0
            if superResolutionLevel == 0 { superResolutionLevel = 2 }
        }
        motionBlurStrength = settings["motionBlurStrength"] as? Int ?? 0
        denoiseStrength = settings["denoiseStrength"] as? Double ?? 0.0
        qualityPrioritization = settings["qualityPrioritization"] as? Int ?? 1
    }

    private func applyDefaultPlaybackSettings() {
        superResolutionLevel = UserDefaults.standard.integer(forKey: "VTDefaultSRLevel")
        frameInterpolationLevel = UserDefaults.standard.integer(forKey: "VTDefaultFILevel")
        playbackSpeed = 1.0
        
        let defSharp = UserDefaults.standard.double(forKey: "VTDefaultSharpness")
        sharpness = defSharp
        renderer.sharpness = Float(defSharp)
        
        let defHDR = UserDefaults.standard.double(forKey: "VTDefaultHDRBoost")
        hdrStrength = defHDR
        renderer.hdrStrength = Float(defHDR)
        
        if modelManager.status == .ready {
            qualitySuperResolutionScaleFactor = UserDefaults.standard.integer(forKey: "VTDefaultQSRLevel")
        } else {
            qualitySuperResolutionScaleFactor = 0
        }
        motionBlurStrength = UserDefaults.standard.integer(forKey: "VTDefaultMBLevel")
        denoiseStrength = UserDefaults.standard.double(forKey: "VTDefaultDNLevel")
        qualityPrioritization = 1
    }

    #if os(iOS)
    private func deleteTempFile(for url: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        if url.standardizedFileURL.path.hasPrefix(tempDir.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func loadRecentVideosIOS() {
        let paths = UserDefaults.standard.stringArray(forKey: "VTRecentVideos") ?? []
        let tempDir = FileManager.default.temporaryDirectory
        
        let loadedURLs = paths.compactMap { pathString -> URL? in
            guard let url = URL(string: pathString) else { return nil }
            // Reconstruct temp URLs to handle container UUID changes on iOS
            if pathString.contains("/tmp/") {
                let filename = url.lastPathComponent
                return tempDir.appendingPathComponent(filename)
            }
            return url
        }
        
        // Clean up temp directory files that are NOT in the recents list
        if let tempFiles = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            let activePaths = Set(loadedURLs.map { $0.standardizedFileURL.path })
            for fileURL in tempFiles {
                if !activePaths.contains(fileURL.standardizedFileURL.path) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
        
        // Filter out stale temp URLs whose files no longer exist
        self.recentVideos = loadedURLs.filter { url in
            if url.standardizedFileURL.path.hasPrefix(tempDir.standardizedFileURL.path) {
                return FileManager.default.fileExists(atPath: url.path)
            }
            return true // Keep external URLs if any
        }
        saveRecentVideosIOS() // persist cleaned list
    }
    
    func saveRecentVideosIOS() {
        let paths = self.recentVideos.map { $0.absoluteString }
        UserDefaults.standard.set(paths, forKey: "VTRecentVideos")
    }
    
    func checkGlobalModelStatus() {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
           VTSuperResolutionScalerConfiguration.isSupported {
            if let config = VTSuperResolutionScalerConfiguration(
                frameWidth: 1920, frameHeight: 1080,
                scaleFactor: 4, inputType: .video,
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: .revision1
            ) {
                modelManager.checkStatus(for: config)
            }
        }
    }
    
    func downloadGlobalModel() {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
           VTSuperResolutionScalerConfiguration.isSupported {
            if let config = VTSuperResolutionScalerConfiguration(
                frameWidth: 1920, frameHeight: 1080,
                scaleFactor: 4, inputType: .video,
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: .revision1
            ) {
                modelManager.downloadModel(for: config)
            }
        }
    }
    
    func addToRecentVideosIOS(_ url: URL) {
        let standardURL = url.resolvingSymlinksInPath().standardizedFileURL
        var list = self.recentVideos.filter { item in
            item.resolvingSymlinksInPath().standardizedFileURL.absoluteString != standardURL.absoluteString
        }
        list.insert(standardURL, at: 0)
        
        // Save the date added timestamp
        let datesKey = "VTRecentVideosDates"
        var dates = UserDefaults.standard.dictionary(forKey: datesKey) as? [String: Double] ?? [:]
        dates[standardURL.lastPathComponent] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dates, forKey: datesKey)
        
        if list.count > 15 {
            // Delete temp files of items falling off the list
            for staleURL in list.suffix(from: 15) {
                deleteTempFile(for: staleURL)
            }
            list = Array(list.prefix(15))
        }
        self.recentVideos = list
        saveRecentVideosIOS()
    }
    
    func deleteRecentVideoIOS(at indexSet: IndexSet) {
        let removedURLs = indexSet.compactMap { index in
            recentVideos.indices.contains(index) ? recentVideos[index] : nil
        }

        for idx in indexSet {
            if idx < recentVideos.count {
                deleteTempFile(for: recentVideos[idx])
            }
        }
        self.recentVideos.remove(atOffsets: indexSet)
        saveRecentVideosIOS()

        if let selectedURL = videoURL,
           removedURLs.contains(where: { $0 == selectedURL }) {
            stop()
            videoURL = nil
        }
    }

    func clearRecentVideosIOS() {
        for url in recentVideos {
            deleteTempFile(for: url)
        }
        self.recentVideos.removeAll()
        saveRecentVideosIOS()

        if videoURL != nil {
            stop()
            videoURL = nil
        }
    }
    #endif

    private func fourCharCodeString(_ code: FourCharCode) -> String {
        let n = Int(code)
        let c1 = Character(UnicodeScalar((n >> 24) & 0xff)!)
        let c2 = Character(UnicodeScalar((n >> 16) & 0xff)!)
        let c3 = Character(UnicodeScalar((n >> 8) & 0xff)!)
        let c4 = Character(UnicodeScalar(n & 0xff)!)
        return String([c1, c2, c3, c4]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The premium media player user interface view.
struct VTPlayerView: View {
    @State private var viewModel = VTPlayerViewModel()
    @State private var showFileImporter = false
    #if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showPhotoPicker = false
    #endif
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var showSettingsSheet = false
    @State private var showDiagnosticsSheet = false
    @State private var showClearAllAlert = false
    @Environment(\.dismiss) private var dismiss
    
    enum SortOption: String, CaseIterable, Identifiable {
        case dateAdded = "Date Added"
        case name = "Name"
        var id: Self { self }
    }
    @State private var sortBy: SortOption = .dateAdded
    @State private var selectedTab = 0

    @State private var videoToRename: URL? = nil
    @State private var renameText = ""
    @State private var showRenameAlert = false
    
    @State private var pinnedVideos: Set<String> = {
        let array = UserDefaults.standard.stringArray(forKey: "VTPinnedVideos") ?? []
        return Set(array)
    }()
    @State private var isPinnedExpanded = true
    @State private var isRecentsExpanded = true
    @State private var isSettingsExpanded = false
    @AppStorage("VTShowFileExtensions") private var showFileExtensions = true
    
    @AppStorage("VTDefaultSRLevel") private var defaultSRLevel = 0
    @AppStorage("VTDefaultQSRLevel") private var defaultQSRLevel = 0
    @AppStorage("VTDefaultFILevel") private var defaultFILevel = 0
    @AppStorage("VTDefaultMBLevel") private var defaultMBLevel = 0
    @AppStorage("VTDefaultDNLevel") private var defaultDNLevel = 0.0
    @AppStorage("VTDefaultSharpness") private var defaultSharpness = 0.0
    @AppStorage("VTDefaultHDRBoost") private var defaultHDRBoost = 0.0

    @State private var scrubTime: Double = 0.0
    @State private var isScrubbing: Bool = false

    // Hover state for control bar feature labels
    @State private var hoverSR = false
    @State private var hoverFI = false
    @State private var hoverMB = false
    @State private var hoverDN = false
    @State private var hoverSH = false
    @State private var hoverHDR = false

    var body: some View {
        Group {
            #if os(iOS)
            iphoneLayout
            #else
            splitViewLayout
            #endif
        }
        .alert("Rename Video", isPresented: $showRenameAlert) {
            TextField("New Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let url = videoToRename {
                    renameVideoFile(url, to: renameText)
                }
            }
        } message: {
            Text("Enter a new name for the video file.")
        }
        #if os(macOS)
        .alert("Clear Playback History?", isPresented: $showClearAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear History", role: .destructive) {
                pinnedVideos.removeAll()
                UserDefaults.standard.set([], forKey: "VTPinnedVideos")
                viewModel.clearRecentVideosMac()
            }
        } message: {
            Text("This will clear your recent playback history. Your video files will remain safe.")
        }
        #endif
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                viewModel.openVideo(url)
            case .failure(let error):
                print("Failed to import file: \(error.localizedDescription)")
            }
        }
        #if canImport(PhotosUI)
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item = item else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: PhotosMovie.self) {
                    viewModel.openVideo(movie.url)
                }
            }
        }
        #endif
        #if os(iOS)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .videos,
            photoLibrary: .shared()
        )
        #endif
        .preferredColorScheme(viewModel.videoURL != nil ? .dark : nil)
        #if os(macOS)
        .onOpenURL { url in
            viewModel.openVideo(url)
        }
        #endif
    }

    @ViewBuilder
    private var splitViewLayout: some View {
        if !viewModel.isFullScreen {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                leftSidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 360)
                    .preferredColorScheme(viewModel.videoURL != nil ? .dark : nil)
            } detail: {
                videoContent
                    .frame(minWidth: 0, idealWidth: 720)
                    .inspector(isPresented: Binding(
                        get: { viewModel.showSidebar && viewModel.videoURL != nil },
                        set: { viewModel.showSidebar = $0 }
                    )) {
                        rightSidebar
                            .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
                            .preferredColorScheme(viewModel.videoURL != nil ? .dark : nil)
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button(action: { showFileImporter = true }) {
                                Label("Open Video", systemImage: "plus")
                            }
                            .help("Open a local video file")
                            
                            Button(action: { viewModel.showSidebar.toggle() }) {
                                Label("Toggle Sidebar", systemImage: "sidebar.right")
                            }
                            .help("Toggle diagnostics and metadata sidebar panel")
                        }
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .macWindowToolbarFullScreenVisibility()
        } else {
            videoContent
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: { showFileImporter = true }) {
                            Label("Open Video", systemImage: "plus")
                        }
                        .help("Open a local video file")
                        
                        Button(action: { viewModel.showSidebar.toggle() }) {
                            Label("Toggle Sidebar", systemImage: "sidebar.right")
                        }
                        .help("Toggle diagnostics and metadata sidebar panel")
                    }
                }
                .macWindowToolbarFullScreenVisibility()
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var iphoneLayout: some View {
        NavigationStack {
            iosHomeView
                .navigationDestination(isPresented: Binding(
                    get: { viewModel.videoURL != nil },
                    set: { show in
                        if !show {
                            viewModel.stop()
                            viewModel.videoURL = nil
                        }
                    }
                )) {
                    iosPlayerView
                }
        }
    }
    #endif



    @ViewBuilder
    private var videoContent: some View {
        ZStack {
            // System Window Background
            viewModel.currentBackgroundColor
                .ignoresSafeArea()

            mainVideoArea

            // QuickTime-style Floating Control Bar at the bottom
            if viewModel.videoURL != nil {
                VStack {
                    Spacer()
                    controlBar
                }
            }

            // Hidden keyboard shortcuts for seeking
            Button("") { viewModel.seekRelative(-5) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
            Button("") { viewModel.seekRelative(5) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)

            #if os(macOS)
            // Cmd+1...9 to switch between window tabs
            ForEach(1..<10, id: \.self) { i in
                Button("") {
                    if let window = NSApp.keyWindow,
                       let tabGroup = window.tabGroup,
                       i - 1 < tabGroup.windows.count {
                        tabGroup.selectedWindow = tabGroup.windows[i - 1]
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: [.command])
                .frame(width: 0, height: 0)
                .opacity(0)
            }
            #endif
        }
        .onContinuousHover { phase in
            viewModel.userActivityDetected()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, mins, secs)
        } else {
            return String(format: "%02d:%02d", mins, secs)
        }
    }

    private func formatDateAdded(for url: URL) -> String {
        let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDates") as? [String: Double] ?? [:]
        guard let timeInterval = dates[url.lastPathComponent] else {
            return "Added recently"
        }
        let date = Date(timeIntervalSince1970: timeInterval)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Added " + formatter.string(from: date)
    }

    private func renameVideoFile(_ url: URL, to newBaseName: String) {
        let ext = url.pathExtension
        let newName = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        let newFileName = newName + (ext.isEmpty ? "" : ".\(ext)")
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newFileName)
        
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            
            // Update recentVideos list
            if let idx = viewModel.recentVideos.firstIndex(of: url) {
                viewModel.recentVideos[idx] = newURL
                #if os(iOS)
                viewModel.saveRecentVideosIOS()
                #endif
            }
            
            // Move Date Added timestamp in UserDefaults
            let datesKey = "VTRecentVideosDates"
            var dates = UserDefaults.standard.dictionary(forKey: datesKey) as? [String: Double] ?? [:]
            if let dateVal = dates[url.lastPathComponent] {
                dates[newURL.lastPathComponent] = dateVal
                dates.removeValue(forKey: url.lastPathComponent)
                UserDefaults.standard.set(dates, forKey: datesKey)
            }
            
            // Move Pin state if pinned
            let pinnedKey = "VTPinnedVideos"
            var pinned = UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []
            if let pIdx = pinned.firstIndex(of: url.lastPathComponent) {
                pinned[pIdx] = newURL.lastPathComponent
                UserDefaults.standard.set(pinned, forKey: pinnedKey)
            }
            
            // Update UI set representation
            if pinnedVideos.contains(url.lastPathComponent) {
                pinnedVideos.remove(url.lastPathComponent)
                pinnedVideos.insert(newURL.lastPathComponent)
            }
            
            // Copy saved enhancement settings to the new lastPathComponent key
            let settingsKeys = [
                "VTLastSRLevel_", "VTLastFILevel_", "VTLastQSRLevel_",
                "VTLastMBLevel_", "VTLastDNLevel_", "VTLastSharpness_",
                "VTLastHDRBoost_", "VTLastPosition_"
            ]
            for keyPrefix in settingsKeys {
                let oldKey = keyPrefix + url.lastPathComponent
                let newKey = keyPrefix + newURL.lastPathComponent
                if let val = UserDefaults.standard.value(forKey: oldKey) {
                    UserDefaults.standard.set(val, forKey: newKey)
                    UserDefaults.standard.removeObject(forKey: oldKey)
                }
            }
            
            // Also update the specific dictionary key if it exists
            let oldDictKey = "VTVideoSettings_" + url.lastPathComponent
            let newDictKey = "VTVideoSettings_" + newURL.lastPathComponent
            if let dict = UserDefaults.standard.dictionary(forKey: oldDictKey) {
                UserDefaults.standard.set(dict, forKey: newDictKey)
                UserDefaults.standard.removeObject(forKey: oldDictKey)
            }
            
        } catch {
            print("Failed to rename file: \(error)")
        }
    }

    private func togglePin(for url: URL) {
        let filename = url.lastPathComponent
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            if pinnedVideos.contains(filename) {
                pinnedVideos.remove(filename)
            } else {
                pinnedVideos.insert(filename)
            }
        }
        UserDefaults.standard.set(Array(pinnedVideos), forKey: "VTPinnedVideos")
    }

}

// MARK: - Extracted SwiftUI Components
extension VTPlayerView {
    #if os(iOS)
    @ViewBuilder
    private var iosHomeView: some View {
        TabView(selection: $selectedTab) {
            iosGalleryView
                .tag(0)
                .tabItem {
                    Label("Gallery", systemImage: "play.square.stack.fill")
                }

            iosAboutView
                .tag(1)
                .tabItem {
                    Label("About", systemImage: "info.circle.fill")
                }
        }
        .navigationTitle(selectedTab == 0 ? "Gallery" : "About")
        .toolbar {
            if selectedTab == 0 {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Clear all button (only shown/enabled when list is not empty)
                    if !viewModel.recentVideos.isEmpty {
                        Button(action: { showClearAllAlert = true }) {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        
                        // Sort option menu
                        Menu {
                            Picker("Sort By", selection: Binding(
                                get: { sortBy },
                                set: { newValue in
                                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                        sortBy = newValue
                                    }
                                }
                            )) {
                                Label("Date Added", systemImage: "calendar").tag(SortOption.dateAdded)
                                Label("Name", systemImage: "textformat.abc").tag(SortOption.name)
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                    
                    // Native Plus button (aggregated selection menu)
                    Menu {
                        Button(action: { showFileImporter = true }) {
                            Label("Browse Files", systemImage: "folder")
                        }
                        
                        #if canImport(PhotosUI)
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Photos Library", systemImage: "photo")
                        }
                        #endif
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.bold())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var iosGalleryView: some View {
        Group {
            if viewModel.recentVideos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("No Videos")
                        .font(.headline)
                    Text("Tap the + button to add video files.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            } else {
                let sortedVideos: [URL] = {
                    let pinnedList = viewModel.recentVideos.filter { pinnedVideos.contains($0.lastPathComponent) }
                    let unpinnedList = viewModel.recentVideos.filter { !pinnedVideos.contains($0.lastPathComponent) }
                    
                    let sortBlock: (URL, URL) -> Bool = { u1, u2 in
                        switch sortBy {
                        case .name:
                            return u1.lastPathComponent.localizedStandardCompare(u2.lastPathComponent) == .orderedAscending
                        case .dateAdded:
                            let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDates") as? [String: Double] ?? [:]
                            let t1 = dates[u1.lastPathComponent] ?? 0
                            let t2 = dates[u2.lastPathComponent] ?? 0
                            return t1 > t2
                        }
                    }
                    
                    return pinnedList.sorted(by: sortBlock) + unpinnedList.sorted(by: sortBlock)
                }()
                
                List {
                    let pinnedList = sortedVideos.filter { pinnedVideos.contains($0.lastPathComponent) }
                    let unpinnedList = sortedVideos.filter { !pinnedVideos.contains($0.lastPathComponent) }
                    
                    Section(isExpanded: $isPinnedExpanded) {
                        ForEach(pinnedList, id: \.self) { url in
                            videoRow(for: url)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    } header: {
                        if !pinnedList.isEmpty {
                            Text("Pinned")
                        }
                    }
                    
                    Section {
                        ForEach(unpinnedList, id: \.self) { url in
                            videoRow(for: url)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    } header: {
                        if !pinnedList.isEmpty {
                            Text("Videos")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .alert("Clear All Videos?", isPresented: $showClearAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                viewModel.clearRecentVideosIOS()
            }
        } message: {
            Text("This will clear your recent playback history. The original video files will not be deleted.")
        }

    }

    @ViewBuilder
    private func videoRow(for url: URL) -> some View {
        Button(action: {
            viewModel.openVideo(url)
        }) {
            HStack(spacing: 12) {
                VideoThumbnailView(url: url)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(showFileExtensions ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    
                    Text(formatDateAdded(for: url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                togglePin(for: url)
            } label: {
                Label(pinnedVideos.contains(url.lastPathComponent) ? "Unpin" : "Pin", 
                      systemImage: pinnedVideos.contains(url.lastPathComponent) ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                if let idx = viewModel.recentVideos.firstIndex(of: url) {
                    viewModel.deleteRecentVideoIOS(at: IndexSet(integer: idx))
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            ShareLink(item: url, preview: SharePreview(url.lastPathComponent))
            
            Button {
                togglePin(for: url)
            } label: {
                let isPinned = pinnedVideos.contains(url.lastPathComponent)
                Label(isPinned ? "Unpin Video" : "Pin Video", systemImage: isPinned ? "pin.slash" : "pin")
            }
            
            Button {
                videoToRename = url
                renameText = url.deletingPathExtension().lastPathComponent
                showRenameAlert = true
            } label: {
                Label("Rename File", systemImage: "pencil")
            }
            
            Button {
                UIPasteboard.general.string = url.lastPathComponent
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }
            
            Divider()
            
            Button(role: .destructive) {
                if let idx = viewModel.recentVideos.firstIndex(of: url) {
                    viewModel.deleteRecentVideoIOS(at: IndexSet(integer: idx))
                }
            } label: {
                Label("Remove from List", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func modelStatusLabelView(_ status: VTModelManager.Status) -> some View {
        switch status {
        case .notChecked:
            Text("Checking...")
                .foregroundStyle(.secondary)
        case .ready:
            Text("Ready")
                .foregroundStyle(.green)
                .bold()
        case .downloadRequired:
            Text("Download Required")
                .foregroundStyle(.orange)
        case .downloading(let progress):
            Text(String(format: "Downloading (%.0f%%)", progress * 100))
                .foregroundStyle(.blue)
        case .failed:
            Text("Failed")
                .foregroundStyle(.red)
        }
    }

    private var iosAboutView: some View {
        List {
            // App Identity Header section (Apple left-oriented HIG style)
            Section {
                HStack(spacing: 16) {
                    if let icon = viewModel.appIcon {
                        icon
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                    } else {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.blue)
                            .frame(width: 60, height: 60)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("VTPlayer")
                            .font(.headline)
                            .bold()
                        Text("Hardware-Accelerated AI Enhancer")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Version 1.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            // Default Playback Settings Section
            Section("Default Playback Configuration") {
                Picker("Super Resolution", selection: $defaultSRLevel) {
                    Text("Off").tag(0)
                    Text("2x Upscaling").tag(2)
                    Text("4x Upscaling").tag(4)
                }
                
                if viewModel.modelManager.status == .ready {
                    Picker("Quality SR", selection: $defaultQSRLevel) {
                        Text("Off").tag(0)
                        Text("2x Quality SR").tag(2)
                        Text("4x Quality SR").tag(4)
                    }
                }
                
                Picker("Frame Interpolation", selection: $defaultFILevel) {
                    Text("Off").tag(0)
                    Text("2x Interpolation").tag(2)
                    Text("4x Interpolation").tag(4)
                }
                
                HStack {
                    Text("Motion Blur")
                    Spacer()
                    Slider(value: Binding(
                        get: { Double(defaultMBLevel) },
                        set: { defaultMBLevel = Int($0) }
                    ), in: 0...30, step: 1)
                    .frame(width: 140)
                    Text(defaultMBLevel == 0 ? "Off" : "\(defaultMBLevel)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
                
                HStack {
                    Text("Denoise Strength")
                    Spacer()
                    Slider(value: $defaultDNLevel, in: 0.0...1.0, step: 0.05)
                    .frame(width: 140)
                    Text(String(format: "%.2f", defaultDNLevel))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                
                HStack {
                    Text("Sharpness")
                    Spacer()
                    Slider(value: $defaultSharpness, in: 0.0...2.0, step: 0.1)
                    .frame(width: 140)
                    Text(String(format: "%.1f", defaultSharpness))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
                
                HStack {
                    Text("SDR-to-HDR Boost")
                    Spacer()
                    Slider(value: $defaultHDRBoost, in: 0.0...2.0, step: 0.1)
                    .frame(width: 140)
                    Text(String(format: "%.1f", defaultHDRBoost))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
            }
            
            // Quality SR Model Section
            Section("Quality Super Resolution Model") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Model Status")
                        Spacer()
                        modelStatusLabelView(viewModel.modelManager.status)
                    }
                    
                    if case .downloadRequired = viewModel.modelManager.status {
                        Button(action: {
                            viewModel.downloadGlobalModel()
                        }) {
                            Text("Download Quality SR Model")
                                .font(.body.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if case .failed(let errMsg) = viewModel.modelManager.status {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Error: \(errMsg)")
                                .font(.caption)
                                .foregroundStyle(.red)
                            
                            Button(action: {
                                viewModel.downloadGlobalModel()
                            }) {
                                Text("Retry Download")
                                    .font(.body.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if case .downloading(let progress) = viewModel.modelManager.status {
                        ProgressView(value: progress) {
                            Text(String(format: "Downloading (%.0f%%)", progress * 100))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .progressViewStyle(.linear)
                        .padding(.vertical, 4)
                    }
                }
            }
            
            // Gallery Configuration Section
            Section("Gallery Configuration") {
                Toggle("Show File Extensions", isOn: $showFileExtensions)
            }

            // Copyright Row
            Section {
                HStack {
                    Spacer()
                    Text("Copyright © 2026 Michael Qiu. All rights reserved.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("About")
        .onAppear {
            viewModel.checkGlobalModelStatus()
        }
    }
    #endif

    #if os(iOS)
    @ViewBuilder
    private var iosPlayerView: some View {
        ZStack {
            // Enhanced Metal video renderer sits at the bottom of the ZStack
            if viewModel.isPipelineActive {
                VTMetalRendererView(renderer: viewModel.renderer)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
            }

            // Native AVPlayerViewController sits on top
            if let player = viewModel.player {
                NativeVideoPlayer(
                    player: player,
                    title: viewModel.videoURL?.lastPathComponent ?? "Video",
                    isPipelineActive: viewModel.isPipelineActive,
                    showControls: $viewModel.showControls
                )
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ProgressView()
                    .tint(.white)
            }
        }
        .navigationTitle(viewModel.showControls ? (viewModel.videoURL?.lastPathComponent ?? "Video") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Keep toolbar visible so the frame never collapses — collapsing
        // causes the player overlay to jump upward abruptly.
        .toolbar(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(!viewModel.showControls)
        .toolbar {
            if viewModel.showControls {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .labelStyle(.iconOnly)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showDiagnosticsSheet = true
                    } label: {
                        Label("Diagnostics", systemImage: "chart.bar")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettingsSheet) {
            PlaybackSettingsView(viewModel: viewModel)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showDiagnosticsSheet) {
            iosDiagnosticsSheet
        }
        .onDisappear {
            viewModel.stop()
            viewModel.videoURL = nil
        }
    }

    @ViewBuilder
    private var iosDiagnosticsSheet: some View {
        NavigationStack {
            Form {
                Section("Video metadata") {
                    LabeledContent("Resolution", value: "\(viewModel.videoWidth)×\(viewModel.videoHeight)")
                    LabeledContent("Source rate") {
                        Text(String(format: "%.2f fps", viewModel.sourceFrameRate))
                            .monospacedDigit()
                    }
                    let scale = viewModel.frameInterpolationLevel > 0 ? Double(viewModel.frameInterpolationLevel) : 1.0
                    LabeledContent("Target rate") {
                        Text(String(format: "%.2f fps", viewModel.sourceFrameRate * scale))
                            .monospacedDigit()
                    }
                    LabeledContent("Codec", value: viewModel.videoFormat)
                }

                Section {
                    LabeledContent("Playback speed") {
                        Text(String(format: "%.2fx", viewModel.playbackSpeed))
                            .monospacedDigit()
                    }
                    LabeledContent("Current time") {
                        Text(formatTime(viewModel.currentTime))
                            .monospacedDigit()
                    }
                    LabeledContent("Duration") {
                        Text(formatTime(viewModel.duration))
                            .monospacedDigit()
                    }
                } header: {
                    Text("Playback status")
                } footer: {
                    Text("Frame processing metrics (display rate, latency) are available on macOS where the VideoToolbox pipeline runs.")
                }

                Section("Super resolution") {
                    LabeledContent("SR supported", value: viewModel.srIsSupported ? "Yes" : "No")
                    let isQL = viewModel.qualitySuperResolutionScaleFactor > 0
                    let activeScale = max(viewModel.superResolutionLevel, viewModel.qualitySuperResolutionScaleFactor)
                    LabeledContent("Active mode", value: activeScale > 0 ? "\(isQL ? "Quality" : "Low Latency") \(activeScale)x" : "Off")
                    if let error = viewModel.srInitializationError {
                        LabeledContent("Error") {
                            Text(error)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showDiagnosticsSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    #endif

    private func sortedMacRecentVideos() -> [URL] {
        switch sortBy {
        case .name:
            return viewModel.recentVideos.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        case .dateAdded:
            let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDatesMac") as? [String: Double] ?? [:]
            return viewModel.recentVideos.sorted {
                (dates[$0.path] ?? 0) > (dates[$1.path] ?? 0)
            }
        }
    }

    @ViewBuilder
    private var leftSidebar: some View {
        let sortedVideos = sortedMacRecentVideos()
        let pinnedList = sortedVideos.filter { pinnedVideos.contains($0.lastPathComponent) }
        let unpinnedList = sortedVideos.filter { !pinnedVideos.contains($0.lastPathComponent) }

        VStack(spacing: 0) {
            List {
                if !pinnedList.isEmpty {
                    Section(isExpanded: $isPinnedExpanded) {
                        ForEach(pinnedList, id: \.self) { url in
                            macSidebarRow(for: url)
                        }
                    } header: {
                        Label("Pinned", systemImage: "pin.fill")
                            .font(.caption.weight(.semibold))
                    }
                }

                Section(isExpanded: $isRecentsExpanded) {
                    if !unpinnedList.isEmpty {
                        ForEach(unpinnedList, id: \.self) { url in
                            macSidebarRow(for: url)
                        }
                    }
                } header: {
                    Text("Recents")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 0, maxWidth: .infinity)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sortPicker
                    Spacer(minLength: 8)
                    deleteHistoryButton
                }

                HStack(spacing: 12) {
                    sortPicker
                    Spacer(minLength: 4)
                    deleteHistoryButton.labelStyle(.iconOnly)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func macSidebarRow(for url: URL) -> some View {
        let isPinned = pinnedVideos.contains(url.lastPathComponent)
        let isActive = (url == viewModel.videoURL)
        return Button(action: {
            viewModel.openRecentVideo(url)
        }) {
            HStack(spacing: 10) {
                VideoThumbnailView(url: url, width: 54, height: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(showFileExtensions ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.system(.subheadline, design: .default).weight(.medium))
                        .foregroundStyle(.primary)
                    
                    Text(url.deletingLastPathComponent().path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .font(.system(size: 9, design: .default))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(url.path)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
        .contextMenu {
            Button {
                togglePin(for: url)
            } label: {
                Label(isPinned ? "Unpin Video" : "Pin Video", systemImage: isPinned ? "pin.slash" : "pin")
            }
            
            Button {
                videoToRename = url
                renameText = url.deletingPathExtension().lastPathComponent
                showRenameAlert = true
            } label: {
                Label("Rename File", systemImage: "pencil")
            }
            
            Button {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.lastPathComponent, forType: .string)
                #endif
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }
            
            #if os(macOS)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            #endif
            
            Divider()
            
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    #if os(macOS)
                    pinnedVideos.remove(url.lastPathComponent)
                    UserDefaults.standard.set(Array(pinnedVideos), forKey: "VTPinnedVideos")
                    viewModel.deleteRecentVideoMac(at: url)
                    #endif
                }
            } label: {
                Label("Remove from List", systemImage: "trash")
            }
        }
    }

    private var sortPicker: some View {
        Picker(selection: $sortBy) {
            Text("Date Added")
                .tag(SortOption.dateAdded)
            Text("Name")
                .tag(SortOption.name)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .pickerStyle(.menu)
        .menuStyle(.borderlessButton)
        .foregroundStyle(.secondary)
        .help("Sort recent videos")
    }

    private var deleteHistoryButton: some View {
        Button {
            showClearAllAlert = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Clear playback history")
        .disabled(viewModel.recentVideos.isEmpty)
    }
    
    @ViewBuilder
    private var rightSidebar: some View {
        Form {
            Section("Real-Time Metrics") {
                LabeledContent("Frame Processing") {
                    Text(String(format: "%.1f ms", viewModel.frameProcessingTime))
                        .monospacedDigit()
                }
                LabeledContent("Display Rate") {
                    Text(String(format: "%.1f Hz", viewModel.displayFrameRate))
                        .monospacedDigit()
                        .foregroundStyle(viewModel.displayFrameRate > (viewModel.sourceFrameRate * 0.8) ? .blue : .red)
                }
                LabeledContent("Display 1% Low") {
                    Text(String(format: "%.1f Hz", viewModel.displayRate1PercentLow))
                        .monospacedDigit()
                        .foregroundStyle(viewModel.displayRate1PercentLow > (viewModel.sourceFrameRate * 0.8) ? .blue : .red)
                }
                LabeledContent("Cached Frames") {
                    Text("\(viewModel.frameCacheCount)")
                        .monospacedDigit()
                        .foregroundStyle(viewModel.frameCacheCount > 10 ? .blue : .secondary)
                }
            }
            
            Section("Video Metadata") {
                LabeledContent("Resolution", value: "\(viewModel.videoWidth)×\(viewModel.videoHeight)")
                LabeledContent("Source Rate") {
                    Text(String(format: "%.2f fps", viewModel.sourceFrameRate))
                        .monospacedDigit()
                }
                LabeledContent("Target Rate") {
                    let scale = viewModel.frameInterpolationLevel > 0 ? Double(viewModel.frameInterpolationLevel) : 1.0
                    let rate = viewModel.sourceFrameRate * scale
                    Text(String(format: "%.2f fps", rate))
                        .monospacedDigit()
                }
                LabeledContent("Video Codec", value: viewModel.videoFormat)
            }
            
            Section("Super Resolution Specs") {
                LabeledContent("SR Supported", value: viewModel.srIsSupported ? "Yes" : "No")
                    .foregroundStyle(viewModel.srIsSupported ? .blue : .secondary)
                
                LabeledContent("Scales", value: viewModel.srSupportedScales)
                LabeledContent("Quality Scales") {
                    let qualityScales = viewModel.availableQualitySuperResolutionScales
                        .sorted()
                        .map { "\($0)x" }
                        .joined(separator: ", ")
                    Text(qualityScales.isEmpty ? "None" : qualityScales)
                        .monospacedDigit()
                }
                
                let isQL = viewModel.qualitySuperResolutionScaleFactor > 0
                let scale = max(viewModel.superResolutionLevel, viewModel.qualitySuperResolutionScaleFactor)
                LabeledContent("Active State", value: scale > 0 ? "\(isQL ? "Quality" : "Low Latency") \(scale)x" : "Off")
                    .foregroundStyle(scale > 0 ? .blue : .secondary)
                
                if viewModel.qualitySuperResolutionScaleFactor > 0 {
                    QLModelStatusView(modelManager: viewModel.modelManager)
                }
                
                if let initError = viewModel.srInitializationError {
                    LabeledContent("SR Status", value: "Error")
                        .foregroundStyle(.red)
                    Text(initError)
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            
        }
        .formStyle(.grouped)
    }
    
    @ViewBuilder
    private var mainVideoArea: some View {
        VStack(spacing: 0) {
            ZStack {
                if viewModel.videoURL != nil {
                    if viewModel.isPipelineActive {
                        VTMetalRendererView(renderer: viewModel.renderer)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .cornerRadius(viewModel.isFullScreen ? 0 : 8)
                            .padding(.horizontal, viewModel.isFullScreen ? 0 : 16)
                            .padding(.top, viewModel.isFullScreen ? 0 : 16)
                            .padding(.bottom, viewModel.isFullScreen ? 0 : 90)
                            .ignoresSafeArea(viewModel.isFullScreen ? .all : [])
                    } else {
                        #if os(macOS)
                        if let player = viewModel.player {
                            MacNativeVideoPlayer(player: player)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .cornerRadius(viewModel.isFullScreen ? 0 : 8)
                                .padding(.horizontal, viewModel.isFullScreen ? 0 : 16)
                                .padding(.top, viewModel.isFullScreen ? 0 : 16)
                                .padding(.bottom, viewModel.isFullScreen ? 0 : 90)
                                .ignoresSafeArea(viewModel.isFullScreen ? .all : [])
                        }
                        #endif
                    }
                }
                
                if viewModel.videoURL == nil {
                    ContentUnavailableView {
                        Label("No Video Loaded", systemImage: "film")
                    } description: {
                        Text("Open a local video file to test Apple Silicon Neural Engine enhancements.")
                    } actions: {
                        VStack(spacing: 8) {
                            Button(action: { showFileImporter = true }) {
                                Text("Open Video File...")
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.regular)
                            
                            #if canImport(PhotosUI) && !os(macOS)
                            PhotosPicker(
                                selection: $selectedPhotoItem,
                                matching: .videos,
                                photoLibrary: .shared()
                            ) {
                                Text("Open from Photos Library...")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            #endif
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var controlBar: some View {
        VStack(spacing: 10) {
            // Video Scrubbing Timeline Progress Bar
            HStack(spacing: 8) {
                Text(formatTime(isScrubbing ? scrubTime : viewModel.currentTime))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Slider(value: $scrubTime, in: 0...viewModel.duration, onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        viewModel.seek(to: scrubTime)
                    }
                })
                .tint(.cyan)
                .labelsHidden()
                .onChange(of: viewModel.currentTime) { _, newValue in
                    if !isScrubbing {
                        scrubTime = newValue
                    }
                }
                .onChange(of: scrubTime) { _, newValue in
                    if isScrubbing {
                        viewModel.scrub(to: newValue)
                    }
                }
                
                Text(formatTime(viewModel.duration))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            
            // Bottom control actions
            // Keep every enhancement control available at narrow widths.
            // The bar scrolls horizontally instead of silently removing the
            // controls that are useful while tuning playback.
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                // Play/Pause button
                playPauseButton
                
                Divider()
                    .frame(height: 16)
                
                // Super Resolution Menu
                Menu {
                    Button("Off") {
                        viewModel.superResolutionLevel = 0
                        viewModel.qualitySuperResolutionScaleFactor = 0
                        viewModel.updateEnhancements()
                    }
                    Divider()
                    Button("Low Latency 2x") {
                        viewModel.superResolutionLevel = 2
                        viewModel.qualitySuperResolutionScaleFactor = 0
                        viewModel.updateEnhancements()
                    }
                    .disabled(!viewModel.availableSuperResolutionScales.contains(2))
                    Button("Low Latency 4x") {
                        viewModel.superResolutionLevel = 4
                        viewModel.qualitySuperResolutionScaleFactor = 0
                        viewModel.updateEnhancements()
                    }
                    .disabled(!viewModel.availableSuperResolutionScales.contains(4))
                    Divider()
                    Button("Quality 2x") {
                        viewModel.superResolutionLevel = 0
                        viewModel.qualitySuperResolutionScaleFactor = 2
                        viewModel.updateEnhancements()
                    }
                    .disabled(!viewModel.availableQualitySuperResolutionScales.contains(2) ||
                              viewModel.modelManager.status != .ready)
                    Button("Quality 4x") {
                        viewModel.superResolutionLevel = 0
                        viewModel.qualitySuperResolutionScaleFactor = 4
                        viewModel.updateEnhancements()
                    }
                    .disabled(!viewModel.availableQualitySuperResolutionScales.contains(4) ||
                              viewModel.modelManager.status != .ready)
                } label: {
                    let isQL = viewModel.qualitySuperResolutionScaleFactor > 0
                    let scale = max(viewModel.superResolutionLevel, viewModel.qualitySuperResolutionScaleFactor)
                    let isActive = scale > 0
                    Text(isQL ? "Super Res: \(scale)x QL" : "Super Res: \(isActive ? "\(scale)x" : "Off")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(isActive ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                        .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Super Resolution — increases spatial resolution using neural upscaling")
                
                // Frame Interpolation Menu
                Menu {
                    Picker(selection: Binding(
                        get: { viewModel.frameInterpolationLevel },
                        set: { viewModel.frameInterpolationLevel = $0; viewModel.updateEnhancements() }
                    )) {
                        Text("Off").tag(0)
                        Text("2x").tag(2)
                        Text("4x").tag(4)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                } label: {
                    let isActive = viewModel.frameInterpolationLevel > 0
                    Text("Interpolation: \(isActive ? "\(viewModel.frameInterpolationLevel)x" : "Off")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(isActive ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                        .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Frame Interpolation — increases video frame rate for fluid movement")
                
                // Motion Blur Menu
                Menu {
                    Picker(selection: Binding(
                        get: { viewModel.motionBlurStrength },
                        set: { viewModel.motionBlurStrength = $0; viewModel.updateEnhancements() }
                    )) {
                        Text("Off").tag(0)
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("20").tag(20)
                        Text("30").tag(30)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                } label: {
                    let isActive = viewModel.motionBlurStrength > 0
                    Text("Motion Blur: \(isActive ? "\(viewModel.motionBlurStrength)" : "Off")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(isActive ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                        .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Motion Blur — simulates natural motion blur on upscaled/interpolated frames")
                
                // Denoise Menu
                Menu {
                    Picker(selection: Binding(
                        get: { viewModel.denoiseStrength },
                        set: { viewModel.denoiseStrength = $0; viewModel.updateEnhancements() }
                    )) {
                        Text("Off").tag(0.0)
                        Text("0.25").tag(0.25)
                        Text("0.5").tag(0.5)
                        Text("0.75").tag(0.75)
                        Text("1.0").tag(1.0)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                } label: {
                    let isActive = viewModel.denoiseStrength > 0
                    Text("Denoise: \(isActive ? String(format: "%.2f", viewModel.denoiseStrength) : "Off")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(isActive ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                        .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Denoise — filters compression noise and high-frequency grain")

                // Image Adjustments Popover Button
                Button(action: { viewModel.showAdjustmentsPopover.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Adjustments")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle((viewModel.sharpness > 0 || viewModel.hdrStrength > 0) ? .primary : .secondary)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background((viewModel.sharpness > 0 || viewModel.hdrStrength > 0) ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .popover(isPresented: Binding(
                    get: { viewModel.showAdjustmentsPopover },
                    set: { viewModel.showAdjustmentsPopover = $0 }
                ), arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Image Adjustments")
                            .font(.headline)
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sharpness: \(viewModel.sharpness > 0 ? String(format: "%.2f", viewModel.sharpness) : "Off")")
                                .font(.caption)
                            Slider(value: $viewModel.sharpness, in: 0...2, step: 0.25)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("HDR Boost: \(viewModel.hdrStrength > 0 ? String(format: "%.2f", viewModel.hdrStrength) : "Off")")
                                .font(.caption)
                            Slider(value: $viewModel.hdrStrength, in: 0...2, step: 0.25)
                        }
                    }
                    .padding(16)
                    .frame(width: 220)
                }
                
                Spacer()
                
                playbackSpeedControl
                
                Divider()
                    .frame(height: 16)
                
                        fullscreenButton
                    }
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                }
            }
            .frame(height: 30)
        }
        .macOnHover { viewModel.isHoveringControlBar = $0 }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .opacity(viewModel.showControls ? 1.0 : 0.0)
        .offset(y: viewModel.showControls ? 0 : 50)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showControls)
    }
    
    @ViewBuilder
    private var playPauseButton: some View {
        Button(action: { viewModel.togglePlayPause() }) {
            Image(systemName: (viewModel.isPlaying && !viewModel.isPaused) ? "pause.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.glass)
        .keyboardShortcut(.space, modifiers: [])
    }
    
    @ViewBuilder
    private var sharpnessControl: some View {
        HStack(spacing: 4) {
            Text(hoverSH
                ? "Sharpness: \(viewModel.sharpness > 0 ? String(format: "%.2f", viewModel.sharpness) : "Off")"
                : "SH"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(viewModel.sharpness > 0 ? .cyan : .secondary)
            .frame(width: hoverSH ? 90 : 22, alignment: .leading)
            Slider(value: $viewModel.sharpness, in: 0...2, step: 0.25)
                .tint(.cyan)
                .labelsHidden()
                .frame(width: 60)
                .opacity(hoverSH ? 1 : 0)
                .allowsHitTesting(hoverSH)
        }
        .macOnHover { hoverSH = $0 }
        .help("Adjust sharpness intensity (CIUnsharpMask)")
    }

    @ViewBuilder
    private var playbackSpeedControl: some View {
        HStack(spacing: 6) {
            Text(String(format: "%.2fx", viewModel.playbackSpeed))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .trailing)
            Slider(value: $viewModel.playbackSpeed, in: 0.5...2.0, step: 0.25)
                .frame(width: 80)
                .tint(.cyan)
        }
        .help("Adjust playback speed (0.5x - 2x)")
    }
    
    @ViewBuilder
    private var fullscreenButton: some View {
        #if os(macOS)
        Button(action: {
            if let window = NSApp.mainWindow ?? NSApp.keyWindow {
                window.toggleFullScreen(nil)
            }
        }) {
            Image(systemName: viewModel.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.glass)
        .keyboardShortcut("f", modifiers: [])
        .help(viewModel.isFullScreen ? "Exit Fullscreen (F)" : "Enter Fullscreen (F)")
        #else
        EmptyView()
        #endif
    }

}

/// Displays Quality SR model download status with live progress tracking.
/// Must be a separate struct to create a direct observation dependency on the
/// `@Observable VTModelManager`, avoiding nested-Observable tracking issues.
struct QLModelStatusView: View {
    let modelManager: VTModelManager

    var body: some View {
        let modelStatus = modelManager.status
        LabeledContent("QL Model", value: modelStatusLabel(modelStatus))
            .foregroundStyle(modelStatusColor(modelStatus))
        if case .downloading(let progress) = modelStatus {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 200)
        }
    }

    private func modelStatusLabel(_ status: VTModelManager.Status) -> String {
        switch status {
        case .notChecked: return "Not Checked"
        case .ready: return "Ready"
        case .downloadRequired: return "Download Required"
        case .downloading(let progress): return String(format: "Downloading (%.0f%%)", progress * 100)
        case .failed(let error): return "Failed: \(error)"
        }
    }

    private func modelStatusColor(_ status: VTModelManager.Status) -> Color {
        switch status {
        case .ready: return .green
        case .downloading: return .orange
        case .downloadRequired, .notChecked: return .secondary
        case .failed: return .red
        }
    }
}

/// Helper view for blur/visual effect backgrounds.
#if os(macOS)
struct VisualEffectView: NSViewRepresentable {
    let material: PlatformVisualEffectMaterial
    let blendingMode: PlatformVisualEffectBlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
#else
struct VisualEffectView: UIViewRepresentable {
    let material: PlatformVisualEffectMaterial
    let blendingMode: PlatformVisualEffectBlendingMode
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
        return view
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}
#endif

// MARK: - Cross-Platform SwiftUI View Extensions
extension View {
    @ViewBuilder
    func macOnHover(perform action: @escaping (Bool) -> Void) -> some View {
        #if os(macOS)
        self.onHover(perform: action)
        #else
        self
        #endif
    }
    
    @ViewBuilder
    func macWindowToolbarFullScreenVisibility() -> some View {
        #if os(macOS)
        self.windowToolbarFullScreenVisibility(.onHover)
        #else
        self
        #endif
    }
    
    @ViewBuilder
    func macNavigationBarTitleDisplayMode() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#if canImport(PhotosUI)
struct PhotosMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { receivedData in
            let fileURL = receivedData.file
            let isAccessing = fileURL.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            
            let fileName = fileURL.lastPathComponent
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            
            if FileManager.default.fileExists(atPath: copy.path) {
                try? FileManager.default.removeItem(at: copy)
            }
            
            try FileManager.default.copyItem(at: fileURL, to: copy)
            return .init(url: copy)
        }
    }
}
#endif



struct PlaybackSettingsView: View {
    @Bindable var viewModel: VTPlayerViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Neural Engine Enhancements") {
                    Picker("Super Resolution", selection: Binding(
                        get: {
                            if viewModel.qualitySuperResolutionScaleFactor > 0 {
                                return 10 + viewModel.qualitySuperResolutionScaleFactor
                            }
                            return viewModel.superResolutionLevel
                        },
                        set: { selection in
                            switch selection {
                            case 2:
                                viewModel.superResolutionLevel = 2
                                viewModel.qualitySuperResolutionScaleFactor = 0
                            case 4:
                                viewModel.superResolutionLevel = 4
                                viewModel.qualitySuperResolutionScaleFactor = 0
                            case 12:
                                viewModel.superResolutionLevel = 0
                                viewModel.qualitySuperResolutionScaleFactor = 2
                            case 14:
                                viewModel.superResolutionLevel = 0
                                viewModel.qualitySuperResolutionScaleFactor = 4
                            default:
                                viewModel.superResolutionLevel = 0
                                viewModel.qualitySuperResolutionScaleFactor = 0
                            }
                            viewModel.updateEnhancements()
                        }
                    )) {
                        Text("Off").tag(0)
                        Text("Low Latency 2x").tag(2)
                            .disabled(!viewModel.availableSuperResolutionScales.contains(2))
                        Text("Low Latency 4x").tag(4)
                            .disabled(!viewModel.availableSuperResolutionScales.contains(4))
                        Text("Quality 2x").tag(12)
                            .disabled(!viewModel.availableQualitySuperResolutionScales.contains(2) ||
                                      viewModel.modelManager.status != .ready)
                        Text("Quality 4x").tag(14)
                            .disabled(!viewModel.availableQualitySuperResolutionScales.contains(4) ||
                                      viewModel.modelManager.status != .ready)
                    }
                    .pickerStyle(.menu)
                    Picker("Frame Interpolation", selection: $viewModel.frameInterpolationLevel) {
                        Text("Off").tag(0)
                        Text("2x").tag(2)
                        Text("4x").tag(4)
                    }
                    .onChange(of: viewModel.frameInterpolationLevel) { _, _ in
                        viewModel.updateEnhancements()
                    }
                    
                    Picker("Motion Blur", selection: $viewModel.motionBlurStrength) {
                        Text("Off").tag(0)
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("20").tag(20)
                        Text("30").tag(30)
                    }
                    .onChange(of: viewModel.motionBlurStrength) { _, _ in
                        viewModel.updateEnhancements()
                    }
                    
                    Picker("Denoise Strength", selection: $viewModel.denoiseStrength) {
                        Text("Off").tag(0.0)
                        Text("0.25").tag(0.25)
                        Text("0.50").tag(0.5)
                        Text("0.75").tag(0.75)
                        Text("1.00").tag(1.0)
                    }
                    .onChange(of: viewModel.denoiseStrength) { _, _ in
                        viewModel.updateEnhancements()
                    }
                }
                
                Section("Filters & Adjustments") {
                    HStack {
                        Text("Sharpness")
                        Spacer()
                        Slider(value: $viewModel.sharpness, in: 0...2, step: 0.25)
                            .frame(width: 150)
                        Text(String(format: "%.2f", viewModel.sharpness))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    
                    HStack {
                        Text("SDR-to-HDR Boost")
                        Spacer()
                        Slider(value: $viewModel.hdrStrength, in: 0...2, step: 0.25)
                            .frame(width: 150)
                        Text(String(format: "%.2f", viewModel.hdrStrength))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                
            }
            .navigationTitle("Playback Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#if os(iOS)
class CustomAVPlayerViewController: AVPlayerViewController {
    var onControlsVisibilityChange: ((Bool) -> Void)?
    var isPipelineActive = false
    private var lastKnownVisibility: Bool = true
    private var checkTimer: Timer?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startTimer()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopTimer()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        disableFullscreenButton(in: view)
        makeBackgroundsClear(in: view)
        hideVideoLayer(in: view)
        checkControlsVisibility()
    }
    
    private func hideVideoLayer(in view: UIView) {
        // If the view's layer itself is an AVPlayerLayer, hide it
        if view.layer is AVPlayerLayer {
            view.layer.isHidden = self.isPipelineActive
        }
        
        // Also check any sublayers for AVPlayerLayer
        if let sublayers = view.layer.sublayers {
            for sublayer in sublayers {
                if sublayer is AVPlayerLayer {
                    sublayer.isHidden = self.isPipelineActive
                }
            }
        }
        
        for subview in view.subviews {
            hideVideoLayer(in: subview)
        }
    }
    
    private func startTimer() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkControlsVisibility()
            self.disableFullscreenButton(in: self.view)
        }
    }
    
    private func stopTimer() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
    
    private func checkControlsVisibility() {
        if let controls = findControlsView(in: view) {
            let isVisible = !controls.isHidden && controls.alpha > 0.1 && controls.superview != nil
            if isVisible != lastKnownVisibility {
                lastKnownVisibility = isVisible
                onControlsVisibilityChange?(isVisible)
            }
        } else {
            // If controls view is not found, default to visible so the user doesn't get stuck
            if lastKnownVisibility != true {
                lastKnownVisibility = true
                onControlsVisibilityChange?(true)
            }
        }
    }
    
    private func findControlsView(in view: UIView) -> UIView? {
        let className = String(describing: type(of: view))
        if className.contains("PlaybackControls") || className.contains("ControlsContainer") || className.contains("TransportBar") {
            return view
        }
        for subview in view.subviews {
            if let found = findControlsView(in: subview) {
                return found
            }
        }
        return nil
    }
    
    private func disableFullscreenButton(in view: UIView) {
        let className = String(describing: type(of: view))
        
        // Disable native fullscreen view containers
        if className.contains("FullScreen") || className.contains("Fullscreen") {
            view.isUserInteractionEnabled = false
            view.alpha = 0.35
            if let control = view as? UIControl {
                control.isEnabled = false
            }
        }
        
        // Disable individual buttons representing fullscreen
        if let button = view as? UIButton {
            let imageDesc = button.currentImage?.description.lowercased() ?? ""
            let label = button.accessibilityLabel?.lowercased() ?? ""
            if imageDesc.contains("fullscreen") || imageDesc.contains("full-screen") || 
               imageDesc.contains("arrow.up.left") || imageDesc.contains("arrow.down.right") ||
               label.contains("fullscreen") || label.contains("full screen") {
                button.isEnabled = false
                button.isUserInteractionEnabled = false
                button.alpha = 0.35
            }
        }
        
        for subview in view.subviews {
            disableFullscreenButton(in: subview)
        }
    }
    
    private func makeBackgroundsClear(in view: UIView) {
        let className = String(describing: type(of: view))
        
        // Hide the backdrop/video presentation layers so the MTKView underneath is visible
        if className.contains("AVPlayerLayer") || className.contains("AVDisplayView") || className.contains("AVBackgroundView") {
            if self.isPipelineActive {
                view.backgroundColor = .clear
                if let layerView = view as? AnyObject, layerView.responds(to: NSSelectorFromString("isOpaque")) {
                    view.isOpaque = false
                }
            } else {
                view.backgroundColor = .black // Restore default opaque color for native playback
                if let layerView = view as? AnyObject, layerView.responds(to: NSSelectorFromString("isOpaque")) {
                    view.isOpaque = true
                }
            }
        }
        
        // General background clear for main view controller view
        if view == self.view {
            if self.isPipelineActive {
                view.backgroundColor = .clear
                view.isOpaque = false
            } else {
                view.backgroundColor = .black
                view.isOpaque = true
            }
        }
        
        for subview in view.subviews {
            makeBackgroundsClear(in: subview)
        }
    }
}

struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let isPipelineActive: Bool
    @Binding var showControls: Bool
    
    func makeUIViewController(context: Context) -> CustomAVPlayerViewController {
        let controller = CustomAVPlayerViewController()
        controller.player = player
        controller.isPipelineActive = isPipelineActive
        controller.showsPlaybackControls = true
        
        // Apply title to AVPlayerItem metadata so the system player shows the title natively
        if let currentItem = player.currentItem {
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = title as NSString
            currentItem.externalMetadata = [titleItem]
        }
        
        controller.onControlsVisibilityChange = { visible in
            DispatchQueue.main.async {
                self.showControls = visible
            }
        }
        return controller
    }
    
    func updateUIViewController(_ uiViewController: CustomAVPlayerViewController, context: Context) {
        uiViewController.isPipelineActive = isPipelineActive
        
        // Apply title to AVPlayerItem metadata if item changes
        if let currentItem = player.currentItem, currentItem.externalMetadata.isEmpty {
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = title as NSString
            currentItem.externalMetadata = [titleItem]
        }
    }
}
#endif

struct VideoThumbnailView: View {
    let url: URL
    var width: CGFloat = 90
    var height: CGFloat = 60
    @State private var thumbnail: Image? = nil
    @State private var durationString: String? = nil
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail = thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                Color.gray.opacity(0.15)
                    .frame(width: width, height: height)
                    .overlay(
                        Image(systemName: "video.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    )
            }
            
            if let duration = durationString {
                Text(duration)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(3)
                    .padding(4)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear {
            loadMetadata()
        }
    }
    
    private func loadMetadata() {
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVAsset(url: url)
            
            // Async loading of duration to keep UI super responsive
            Task {
                do {
                    let duration = try await asset.load(.duration)
                    let seconds = CMTimeGetSeconds(duration)
                    if !seconds.isNaN && !seconds.isInfinite {
                        let mins = Int(seconds) / 60
                        let secs = Int(seconds) % 60
                        await MainActor.run {
                            self.durationString = String(format: "%d:%02d", mins, secs)
                        }
                    }
                } catch {}
            }
            
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 120)
            
            // Request frame at 1.0 second or start
            let time = CMTime(seconds: 1.0, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                DispatchQueue.main.async {
                    self.thumbnail = Image(decorative: cgImage, scale: 1.0)
                }
            }
        }
    }
}
