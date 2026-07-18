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
    var readyQualitySuperResolutionScales: Set<Int> = []
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
    @ObservationIgnored private var qualityModelRetryTask: Task<Void, Never>?
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

    private func retryAfterQualityModelDownload(generation: UInt64) {
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
        readyQualitySuperResolutionScales.removeAll()
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
                
                // Get the encoded pixel dimensions used by AVAssetReader and
                // VideoToolbox. `naturalSize` is display geometry and can be
                // altered by rotation or a clean aperture, which can make a
                // capability probe disagree with the actual pixel buffers.
                let descriptions = try await videoTrack.load(.formatDescriptions)
                let encodedDimensions: CMVideoDimensions?
                if let firstDesc = descriptions.first {
                    encodedDimensions = CMVideoFormatDescriptionGetDimensions(firstDesc)
                } else {
                    encodedDimensions = nil
                }
                let naturalSize = try await videoTrack.load(.naturalSize)
                let width = Int(encodedDimensions?.width ?? Int32(naturalSize.width))
                let height = Int(encodedDimensions?.height ?? Int32(naturalSize.height))
                
                // Get framerate
                let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
                let frameRate = Double(nominalFrameRate)
                
                // Get format description
                var formatStr = "Unknown"
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
                // valid. Probe the actual video dimensions on every platform;
                // a global `isSupported` result is not sufficient because
                // VideoToolbox can reject individual resolutions.
                let ll2SessionSupported = await VTFrameProcessorCoordinator
                    .isLowLatencySuperResolutionSupported(width: width, height: height, scale: 2.0)
                let availableSRScales: Set<Int> = ll2SessionSupported ? [2, 4] : []
                var availableQualityScales: Set<Int> = []
                var readyQualityScales: Set<Int> = []
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
                            if let modelConfig = VTSuperResolutionScalerConfiguration(
                                frameWidth: width, frameHeight: height,
                                scaleFactor: scale, inputType: .video,
                                usePrecomputedFlow: false, qualityPrioritization: .normal,
                                revision: .revision1
                            ), modelConfig.configurationModelStatus == .ready {
                                readyQualityScales.insert(scale)
                            }
                        }
                    }
                }
                #endif

                NSLog("CAPABILITY: video=\(width)x\(height) LL reported=\(scalesStr) LL session2=\(ll2SessionSupported) LL menu=\(availableSRScales.sorted()) QL menu=\(availableQualityScales.sorted()) QL ready=\(readyQualityScales.sorted())")

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
                    self.readyQualitySuperResolutionScales = readyQualityScales
                    
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
        qualityModelRetryTask?.cancel()
        qualityModelRetryTask = nil
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
        qualityModelRetryTask?.cancel()
        qualityModelRetryTask = nil
        let gen = playbackGeneration
        let oldProducer = producerTask
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        endActiveCoordinator(after: oldProducer)

        let sourceFPS = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30.0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(sourceFPS))
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
            @MainActor func fallBackFromQualitySR(preserveSelection: Bool = false) {
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
                    await self.modelManager.checkStatus(for: checkConfig)
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
        let useWallClockPacing = frameInterpolationLevel > 0 && sourceFrameRate > 0
        
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

}
