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
import UniformTypeIdentifiers
#endif

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
    @ObservationIgnored let cacheLock = NSRecursiveLock()
    /// Limit retained presentation frames by bytes, not a fixed frame count.
    /// 4x SR can turn a single 1080p frame into a 33 MP image.
    let frameCacheMemoryBudget = 512 * 1024 * 1024
    let maximumFrameCacheCount = 120
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
    }

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

    func compactProcessedFrameCacheIfNeeded() {
        guard processedFrameCacheStart > 0 else { return }
        let totalCount = processedFrameCache.count
        if processedFrameCacheStart >= 64 || processedFrameCacheStart * 2 >= totalCount {
            processedFrameCache = Array(processedFrameCache[processedFrameCacheStart...])
            processedFrameCacheStart = 0
        }
    }

    var bufferedFrameLimit: Int {
        let scale = max(1, max(superResolutionLevel, qualitySuperResolutionScaleFactor))
        let outputPixels = Double(videoWidth) * Double(videoHeight) * Double(scale * scale)
        guard outputPixels > 0 else { return maximumFrameCacheCount }

        // The processors normally use YUV, but a four-byte estimate keeps
        // the cache safe if VideoToolbox selects a packed destination format.
        let estimatedBytesPerFrame = max(1.0, outputPixels * 4.0)
        let budgetedFrames = Int(Double(frameCacheMemoryBudget) / estimatedBytesPerFrame)
        return min(maximumFrameCacheCount, max(2, budgetedFrames))
    }

    var resumeBufferFrameCount: Int {
        min(8, max(2, bufferedFrameLimit / 2))
    }

    /// FI generates frames between adjacent source timestamps. Keeping one
    /// source interval in the presentation queue prevents a late processor
    /// completion from collapsing the interpolated and source frames into one
    /// display refresh.
    var interpolationPresentationDelay: Double {
        guard frameInterpolationLevel > 0, sourceFrameRate > 0 else { return 0 }
        return 1.0 / sourceFrameRate
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
    #if os(iOS)
    var tempLocalURL: URL?
    #endif
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

    func resetPresentationClock(at seconds: Double) {
        guard seconds.isFinite else { return }
        presentationClockAnchorPTS = seconds
        presentationClockAnchorWall = .now()
        presentationClockLastPlayerPTS = seconds
        presentationClockInitialized = true
        lastPresentationWall = .now()
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
    

    
    func setupPlayer(with url: URL) {
        // Capability probing is asynchronous. Clear the previous video's
        // scale set immediately so its enabled menu items cannot leak into
        // the new video's loading window.
        availableSuperResolutionScales.removeAll()
        availableQualitySuperResolutionScales.removeAll()
        readyQualitySuperResolutionScales.removeAll()
        useSequentialSRFIFallback = false
        let asset = AVURLAsset(url: url)
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
                let supported = VTFrameProcessorCoordinator.isSuperResolutionSupported()
                let scales = VTFrameProcessorCoordinator.supportedSuperResolutionScaleFactors(width: width, height: height)
                let scalesStr = scales.isEmpty ? "None" : scales.map { String(format: "%.1fx", $0) }.joined(separator: ", ")
                // Probe each selectable LL SR mode at the dimensions it will
                // actually process. A 4x cascade needs a second supported 2x
                // processor at the first-stage output size; do not advertise
                // it merely because the source-resolution stage works.
                let ll2SessionSupported = await VTFrameProcessorCoordinator
                    .canStartLowLatencyPipeline(width: width, height: height, scale: 2)
                let ll4SessionSupported: Bool
                if ll2SessionSupported {
                    ll4SessionSupported = await VTFrameProcessorCoordinator
                        .isLowLatencySuperResolutionSupported(width: width * 2, height: height * 2, scale: 2.0)
                } else {
                    ll4SessionSupported = false
                }
                var availableSRScales: Set<Int> = []
                if ll2SessionSupported {
                    availableSRScales.insert(2)
                }
                if ll4SessionSupported {
                    availableSRScales.insert(4)
                }
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
        self.recentVideos.removeAll()
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosMac")
        UserDefaults.standard.removeObject(forKey: "VTRemovedRecentVideos")
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosDatesMac")
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosOpenedDatesMac")

        if hadSelectedVideo {
            stop()
            videoURL = nil
        }
    }
    #endif
    
    func openVideo(_ url: URL) {
        self.stop()

        #if os(macOS)
        let targetURL = resolveSecurityScopedBookmark(for: url)
        #else
        var targetURL = url
        #endif
        
        // Release any previously held security-scoped resource
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
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let idx = recentVideos.firstIndex(of: url) {
                deleteRecentVideoIOS(at: IndexSet(integer: idx))
            }
            return
        }
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
            Self.decodeSingleFrame(from: url, at: time)
        }.value
    }

    nonisolated static func decodeSingleFrame(from url: URL, at time: CMTime) -> VTFrame? {
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
    var enhancementsPendingRestart = false

}
