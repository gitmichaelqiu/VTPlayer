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

/// The Main ViewModel managing the playback loop, synchronization, and processor pipeline.
@Observable
@MainActor
final class VTPlayerViewModel {
    var videoURL: URL?
    var isPlaying = false
    var isPaused = false
    
    // Feature Levels (0 = Off, 2 = 2x, 4 = 4x)
    var superResolutionLevel: Int = 0
    var frameInterpolationLevel: Int = 0

    // New API Feature Levels
    var qualitySuperResolutionScaleFactor: Int = 0  // 0=off, 2, 4 (Quality SR)
    var motionBlurStrength: Int = 0 {  // 0=off, 1-100
        didSet { updateEnhancements() }
    }
    var denoiseStrength: Double = 0.0 {  // 0.0=off, 0.0-1.0
        didSet { updateEnhancements() }
    }
    var qualityPrioritization: Int = 1 {  // 1=normal, 2=quality
        didSet { updateEnhancements() }
    }
    var showSidebar = true
    var showLeftSidebar = true
    
    // Quality Control Parameters
    var useHighQualityDownsampling: Bool = true {
        didSet {
            UserDefaults.standard.set(useHighQualityDownsampling, forKey: "VTUseHighQualityDownsampling")
            updateEnhancements()
        }
    }
    var useRealTimePriority: Bool = true {
        didSet {
            UserDefaults.standard.set(useRealTimePriority, forKey: "VTUseRealTimePriority")
            updateEnhancements()
        }
    }
    
    // Playback Progress & Stats
    var isPipelineActive: Bool {
        #if os(iOS)
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
            if let player = player {
                player.rate = Float(isPaused ? 0.0 : playbackSpeed)
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
    var droppedFrames = 0
    var aneUsagePercent: Double = 0.0
    
    // Detailed SR Diagnostics
    var srIsSupported: Bool = false
    var srSupportedScales: String = "None"
    var srInitializationError: String? = nil
    
    // Recents List
    var recentVideos: [URL] = []
    
    // Fullscreen and Auto-hide HUD controls state
    var isFullScreen = false
    var showControls = true
    var isHoveringControlBar = false
    
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
    var frameCacheCount: Int { processedFrameCache.count }

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
    private var videoOutput: AVPlayerItemVideoOutput?
    private var producerTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?
    #if os(macOS)
    private var displayLink: CVDisplayLink?
    #else
    private var displayLink: CADisplayLink?
    #endif
    private var processedFramesCount = 0
    private var fpsTimer = DispatchTime.now()
    private var diagTimer = DispatchTime.now()
    private var processedFrameCache: [VTFrame] = []
    private var securityScopedURL: URL?
    #if os(iOS)
    private var tempLocalURL: URL?
    #endif
    private var lastPulledTime: CMTime = .zero
    private var playerItemObserver: Any?
    private var timeJumpedObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var playbackGeneration: UInt64 = 0
    private var isInitializingPipeline = false

    // Audio sync monitoring (diagnostic only — never pauses player)
    private var lastRenderedPTS: CMTime = .zero
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
        self.recentVideos = NSDocumentController.shared.recentDocumentURLs
        
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
        self.useHighQualityDownsampling = UserDefaults.standard.object(forKey: "VTUseHighQualityDownsampling") as? Bool ?? true
        self.useRealTimePriority = UserDefaults.standard.object(forKey: "VTUseRealTimePriority") as? Bool ?? true
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
        let asset = AVAsset(url: url)
        
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
                
                // Create AVPlayerItem and AVPlayerItemVideoOutput
                let outputSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
                let item = AVPlayerItem(asset: asset)
                item.add(output)

                #if os(macOS)
                // Disable the video track on AVPlayer so it only decodes
                // audio.  Video frames are read separately via
                // VTFrameSequence (AVAssetReader).  Without this, the
                // AVPlayer's internal video decoder competes with the
                // VTFrameProcessor for ANE/hardware resources, starving
                // FI and making the video appear to play in slow motion.
                for track in item.tracks {
                    if track.assetTrack?.mediaType == .video {
                        track.isEnabled = false
                    }
                }
                #endif

                let newPlayer = AVPlayer(playerItem: item)
                newPlayer.automaticallyWaitsToMinimizeStalling = false
                
                // Update properties on @MainActor
                await MainActor.run {
                    #if os(macOS)
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    self.reloadRecentVideos()
                    #endif
                    
                    self.duration = durationSecs
                    self.videoWidth = width
                    self.videoHeight = height
                    self.sourceFrameRate = frameRate
                    self.videoFormat = formatStr
                    self.srIsSupported = supported
                    self.srSupportedScales = scalesStr
                    
                    self.player = newPlayer
                    self.videoOutput = output
                    
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
                                self.isPaused = true
                            case .playing:
                                self.isPaused = false
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
        self.recentVideos = NSDocumentController.shared.recentDocumentURLs
    }
    #endif
    
    func openVideo(_ url: URL) {
        self.stop()
        
        var targetURL = url
        
        #if os(iOS)
        self.tempLocalURL = nil
        
        // Release any previously held security-scoped resource
        if let prev = securityScopedURL {
            prev.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
        
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        if isSecurityScoped {
            self.securityScopedURL = url
        }
        
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
        #if os(iOS)
        let shouldAutoHide = isPlaying && !isPaused
        #else
        let shouldAutoHide = isFullScreen && isPlaying && !isPaused
        #endif
        
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
            let shouldHide = self.isFullScreen && self.isPlaying && !self.isPaused && !self.isHoveringControlBar
            #endif
            if shouldHide {
                self.showControls = false
                #if os(macOS)
                if !self.cursorHidden {
                    NSCursor.hide()
                    self.cursorHidden = true
                }
                #endif
            }
        }
    }

    /// Seeks to a specific timestamp in seconds.
    func seek(to seconds: Double) {
        self.currentTime = seconds
        self.saveProgress()
        self.lastRenderedPTS = .zero
        self.processedFrameCache.removeAll()
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
                // Re-assert player rate — AVPlayer can transiently drop
                // rate to 0 during seek, causing arrow-key seeks to
                // unexpectedly pause playback.
                if shouldPlay {
                    self.player?.rate = targetRate
                }
                await self.triggerSingleFrameUpdate(at: time)
            }
        }
    }

    private func handleTimeJump() {
        guard let player = player else { return }
        let currentTime = player.currentTime()
        
        self.processedFrameCache.removeAll()
        self.lastPulledTime = currentTime
        self.lastRenderedPTS = currentTime
        Task { @MainActor in
            await self.activeCoordinator?.clearHistory()
        }
        
        // If paused (e.g. scrubbing), read and draw a single frame immediately
        // at the new seek position so the screen updates in real time.
        if self.isPaused, let url = videoURL {
            Task { @MainActor in
                if let pixelBuffer = self.readSingleFrame(from: url, at: currentTime) {
                    self.renderer.render(pixelBuffer: pixelBuffer)
                }
            }
        }
    }

    /// Seeks and draws the frame immediately during continuous scrubbing.
    func scrub(to seconds: Double) {
        self.currentTime = seconds
        self.saveProgress()
        self.lastRenderedPTS = .zero
        self.processedFrameCache.removeAll()
        self.lastPulledTime = CMTime(seconds: seconds, preferredTimescale: 600)
        Task { @MainActor in
            await self.activeCoordinator?.clearHistory()
        }
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)

        // Read a single frame via AVAssetReader (video track is disabled
        // on AVPlayer, so copyPixelBuffer won't work).
        if let url = videoURL,
           let pixelBuffer = readSingleFrame(from: url, at: time) {
            self.renderer.render(pixelBuffer: pixelBuffer)
        }
    }

    /// Seeks forward or backward by the given relative offset in seconds.
    func seekRelative(_ delta: Double) {
        let target = max(0, min(duration, currentTime + delta))
        seek(to: target)
    }

    private func triggerSingleFrameUpdate(at time: CMTime) async {
        guard let url = videoURL else { return }
        // Small delay to let the seek settle
        try? await Task.sleep(nanoseconds: 10_000_000)
        if let pixelBuffer = readSingleFrame(from: url, at: time) {
            self.renderer.render(pixelBuffer: pixelBuffer)
        }
    }

    /// Reads a single decoded video frame at the given time using AVAssetReader.
    private func readSingleFrame(from url: URL, at time: CMTime) -> CVPixelBuffer? {
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
        return CMSampleBufferGetImageBuffer(sample)
    }
    
    /// Whether the pipeline needs to be rebuilt on the next resume.
    private var enhancementsPendingRestart = false

    /// Updates coordinator when features are toggled without changing playback state.
    func updateEnhancements() {
        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        if isPlaying && !isPaused {
            startPlaybackLoop()
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

        player.rate = Float(self.playbackSpeed)

        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        // Rebuild the pipeline if enhancements were changed while paused,
        // or if the loop has not yet been initialized. Otherwise, the existing
        // active loop will automatically resume processing when isPaused is false.
        if enhancementsPendingRestart || producerTask == nil {
            enhancementsPendingRestart = false
            startPlaybackLoop()
        }
        #endif
        self.userActivityDetected()
    }
    
    /// Pauses player
    func pause() {
        guard let player = player else { return }
        player.pause()
        self.isPaused = true
        #if os(macOS)
        if let link = displayLink {
            CVDisplayLinkStop(link)
            self.displayLink = nil
        }
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
    private func startPlaybackLoop() {
        playbackGeneration += 1
        let gen = playbackGeneration
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil

        let sourceFPS = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30.0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(sourceFPS))

        processedFrameCache.removeAll()
        if let player = player {
            let adjusted = CMTimeSubtract(player.currentTime(), frameDuration)
            lastPulledTime = adjusted > .zero ? adjusted : .zero
            lastRenderedPTS = player.currentTime()
        } else {
            lastPulledTime = .zero
            lastRenderedPTS = .zero
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
                self.producerTask = nil
            }

            // Check Quality SR model availability before starting (macOS only)
            var effectiveQualitySR = qualitySR
            var effectiveSRLevel = srLevel
            
            #if os(macOS)
            if qualitySR > 0 {
                var qlConfig: VTSuperResolutionScalerConfiguration? = nil
                if #available(macOS 26.0, *),
                   VTSuperResolutionScalerConfiguration.isSupported {
                    qlConfig = VTSuperResolutionScalerConfiguration(
                        frameWidth: videoWidth, frameHeight: videoHeight,
                        scaleFactor: qualitySR, inputType: .video,
                        usePrecomputedFlow: false, qualityPrioritization: .normal,
                        revision: .revision1
                    )
                    if qlConfig == nil {
                        self.srInitializationError = "Quality SR unavailable for \(videoWidth)x\(videoHeight)"
                        print("Quality SR not available for \(videoWidth)x\(videoHeight) @ \(qualitySR)x, falling back to LL SR")
                    }
                } else {
                    print("VTSuperResolutionScaler not supported on this system, falling back to LL SR")
                }
                if let checkConfig = qlConfig {
                    await self.modelManager.checkStatus(for: checkConfig)
                    if case .downloadRequired = self.modelManager.status {
                        print("Quality SR model download required, starting download and falling back to LL SR")
                        self.modelManager.downloadModel(for: checkConfig)
                        // Yield to allow the download Timer to fire and UI to update progress
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        effectiveQualitySR = 0
                        effectiveSRLevel = qualitySR == 4 ? 4 : 2
                    }
                } else {
                    effectiveQualitySR = 0
                    effectiveSRLevel = qualitySR == 4 ? 4 : 2
                }
            }
            #else
            if qualitySR > 0 {
                effectiveQualitySR = 0
                effectiveSRLevel = qualitySR == 4 ? 4 : 2
            }
            #endif
            let coordinator = VTFrameProcessorCoordinator(
                superResolutionLevel: effectiveSRLevel,
                frameInterpolationLevel: fiLevel,
                useHighQualityDownsampling: highQuality,
                useRealTimePriority: realTime,
                qualitySuperResolutionScaleFactor: effectiveQualitySR,
                motionBlurStrength: mbStrength,
                denoiseStrength: dnStrength,
                qualityPrioritization: qualPrior
            )
            self.activeCoordinator = coordinator

            // Pause the player during coordinator init so the audio clock
            // doesn't advance while the cache is empty.  Without this, the
            // consumer stalls (empty cache) while audio keeps running,
            // creating an audible gap followed by a video jump.
            self.isInitializingPipeline = true
            let wasRate = self.player?.rate ?? 0
            self.player?.pause()

            do {
                self.srInitializationError = nil
                try await coordinator.startSession(width: videoWidth, height: videoHeight)
            } catch {
                self.srInitializationError = error.localizedDescription
                print("Failed to initialize coordinator session: \(error.localizedDescription)")
                // Stop playback entirely so the consumer and audio sync don't hang
                // forever with an empty frame cache.
                self.stop()
                return
            }

            // Re-sync lastPulledTime after potentially slow coordinator setup
            // and resume the player from the same position.
            if let player = self.player {
                let resumeTime = player.currentTime()
                self.lastPulledTime = resumeTime
                self.lastRenderedPTS = resumeTime
                await player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
                player.rate = wasRate != 0 ? wasRate : Float(self.playbackSpeed)
                self.isInitializingPipeline = false
            }

            // Create VTFrameSequence to decode frames faster-than-real-time
            guard let videoURL = self.videoURL else { return }
            var iteratorStartTime = self.lastPulledTime
            let frameSequence = VTFrameSequence(url: videoURL, startTime: iteratorStartTime)
            var frameIterator = frameSequence.makeAsyncIterator()

            while !Task.isCancelled {
                guard gen == self.playbackGeneration else { break }

                if self.isPaused {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    continue
                }

                // Detect seek: if lastPulledTime was changed by seekRelative,
                // recreate the iterator at the new position. Without this, the
                // producer would keep feeding stale frames from the old position.
                if self.lastPulledTime != iteratorStartTime {
                    iteratorStartTime = self.lastPulledTime
                    let newSequence = VTFrameSequence(url: videoURL, startTime: iteratorStartTime)
                    frameIterator = newSequence.makeAsyncIterator()
                    continue
                }

                // Large cache target — buffer frames ahead so the consumer
                // always has processed frames to render even when the
                // pipeline is slower than real-time.
                if self.processedFrameCache.count >= 60 {
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
                    let currentSecs = CMTimeGetSeconds(player.currentTime())
                    let frameSecs = CMTimeGetSeconds(vtFrame.presentationTimeStamp)
                    // If the frame is late by more than 100ms, skip processing it
                    if !self.processedFrameCache.isEmpty && frameSecs < currentSecs - 0.10 {
                        self.droppedFrames += 1
                        continue
                    }
                }

                // Process through the VideoToolbox pipeline
                let processStart = DispatchTime.now()
                do {
                    let outputFrames = try await coordinator.processFrame(vtFrame)
                    let processEnd = DispatchTime.now()

                    guard gen == self.playbackGeneration else { break }

                    self.frameProcessingTime = Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000.0

                    // ANE usage not yet measurable via public API — placeholder for future telemetry
                    self.aneUsagePercent = 0.0

                    if outputFrames.count < 2 && self.frameInterpolationLevel > 0 {
                        print("⚠️ FI: expected >=2 output frames, got \(outputFrames.count) for frame at \(CMTimeGetSeconds(vtFrame.presentationTimeStamp))")
                    }

                    // Insert output frames in PTS-sorted order using binary
                    // search.  The cache is already sorted and output frames
                    // arrive roughly in order, so this is O(log n) per frame
                    // instead of re-sorting the entire array every time.
                    for outFrame in outputFrames {
                        let pts = outFrame.presentationTimeStamp
                        var lo = 0, hi = self.processedFrameCache.count
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
                } catch {
                    guard gen == self.playbackGeneration else { break }
                    print("⚠️ Pipeline processing error: \(error)")
                    self.processedFrameCache.append(vtFrame)
                }
            }

            await coordinator.endSession()
        }
        
        // Start CVDisplayLink (macOS) or CADisplayLink (iOS)
        #if os(macOS)
        if let link = self.displayLink {
            CVDisplayLinkStop(link)
            self.displayLink = nil
        }
        #else
        if let link = self.displayLink {
            link.invalidate()
            self.displayLink = nil
        }
        #endif
        
        self.processedFramesCount = 0
        self.fpsTimer = DispatchTime.now()
        self.diagTimer = DispatchTime.now()
        
        #if os(macOS)
        var newLink: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&newLink) == kCVReturnSuccess, let link = newLink {
            let callback: CVDisplayLinkOutputCallback = { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
                let vm = Unmanaged<VTPlayerViewModel>.fromOpaque(displayLinkContext!).takeUnretainedValue()
                DispatchQueue.main.async {
                    vm.tickDisplayLink()
                }
                return kCVReturnSuccess
            }
            let context = Unmanaged.passUnretained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(link, callback, context)
            CVDisplayLinkStart(link)
            self.displayLink = link
        }
        #else
        let link = CADisplayLink(target: self, selector: #selector(caDisplayLinkTick))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
        #endif

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

                // Log desync for diagnostics but never pause the player.
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
    #endif

    @MainActor
    private func tickDisplayLink() {
        guard isPlaying && !isPaused, let player = self.player else { return }
        
        let currentTime = player.currentTime()
        let currentSecs = CMTimeGetSeconds(currentTime)
        
        // Drain all frames whose PTS ≤ current player time, but only render the last one.
        var lastFrameToRender: VTFrame? = nil
        var drained = 0
        while !self.processedFrameCache.isEmpty {
            let firstFrame = self.processedFrameCache[0]
            let frameTime = CMTimeGetSeconds(firstFrame.presentationTimeStamp)
            guard frameTime <= currentSecs + 0.005 else { break }

            lastFrameToRender = firstFrame
            self.lastRenderedPTS = firstFrame.presentationTimeStamp
            drained += 1
            if !self.processedFrameCache.isEmpty {
                self.processedFrameCache.removeFirst()
            }
        }
        
        if let frame = lastFrameToRender {
            self.renderer.render(pixelBuffer: frame.buffer, isInterpolated: frame.isInterpolated)
            processedFramesCount += drained
            self.currentTime = currentSecs
            if drained > 1 {
                self.droppedFrames += drained - 1
            }
        }
        
        // Stats calculations
        let now = DispatchTime.now()
        let elapsedFPSTime = Double(now.uptimeNanoseconds - fpsTimer.uptimeNanoseconds) / 1_000_000_000.0
        if elapsedFPSTime >= 1.0 {
            self.fps = Double(processedFramesCount) / elapsedFPSTime
            processedFramesCount = 0
            fpsTimer = now
        }
        
        let diagElapsed = Double(now.uptimeNanoseconds - diagTimer.uptimeNanoseconds) / 1_000_000_000.0
        if diagElapsed >= 5.0 {
            let curRate = player.rate
            let curFPS = self.fps
            if let first = self.processedFrameCache.first {
                let ft = CMTimeGetSeconds(first.presentationTimeStamp)
                print("DIAG: cache=\(self.processedFrameCache.count) currentSecs=\(String(format: "%.3f", currentSecs)) nextPTS=\(String(format: "%.3f", ft)) rate=\(curRate) rendered=\(curFPS)")
            } else {
                print("DIAG: cache=0 currentSecs=\(String(format: "%.3f", currentSecs)) rate=\(curRate) rendered=\(curFPS)")
            }
            diagTimer = now
        }
    }

    #if !os(macOS)
    @objc private func caDisplayLinkTick() {
        self.tickDisplayLink()
    }
    #endif

    /// Pauses/stops playback entirely.
    func stop() {
        if self.currentTime > 0 {
            self.saveProgress()
        }
        saveVideoSettings()
        activeCoordinator = nil
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        #if os(macOS)
        if let link = displayLink {
            CVDisplayLinkStop(link)
            self.displayLink = nil
        }
        #else
        if let link = displayLink {
            link.invalidate()
            self.displayLink = nil
        }
        #endif
        #if os(iOS)
        self.tempLocalURL = nil
        if let scoped = securityScopedURL {
            scoped.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
        #endif
        audioSyncTask?.cancel()
        audioSyncTask = nil
        audioSyncLatency = 0
        lastRenderedPTS = .zero
        processedFrameCache.removeAll()
        
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
        videoOutput = nil
        
        self.isPlaying = false
        self.isPaused = false
        self.currentTime = 0.0
        self.duration = 0.0
        self.fps = 0.0
        self.frameProcessingTime = 0.0
        self.aneUsagePercent = 0.0
        self.srInitializationError = nil
        self.isInitializingPipeline = false
        self.enhancementsPendingRestart = false
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
        guard let settings = UserDefaults.standard.dictionary(forKey: Self.videoSettingsKey(for: url.lastPathComponent)) else { return }
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
    
    private func saveRecentVideosIOS() {
        let paths = self.recentVideos.map { $0.absoluteString }
        UserDefaults.standard.set(paths, forKey: "VTRecentVideos")
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
        for idx in indexSet {
            if idx < recentVideos.count {
                deleteTempFile(for: recentVideos[idx])
            }
        }
        self.recentVideos.remove(atOffsets: indexSet)
        saveRecentVideosIOS()
    }
    
    func clearRecentVideosIOS() {
        for url in recentVideos {
            deleteTempFile(for: url)
        }
        self.recentVideos.removeAll()
        saveRecentVideosIOS()
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
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                viewModel.openVideo(url)
                withAnimation {
                    columnVisibility = .detailOnly
                }
            case .failure(let error):
                print("Failed to import file: \(error.localizedDescription)")
            }
        }
        #if canImport(PhotosUI)
        .onChange(of: selectedPhotoItem) { item in
            guard let item = item else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: PhotosMovie.self) {
                    viewModel.openVideo(movie.url)
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private var splitViewLayout: some View {
        if !viewModel.isFullScreen {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                leftSidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 500)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: { showFileImporter = true }) {
                                Label("Open Video", systemImage: "plus")
                            }
                            .help("Open a local video file")
                        }
                    }
            } detail: {
                videoContent
                    .inspector(isPresented: Binding(
                        get: { viewModel.showSidebar && viewModel.videoURL != nil },
                        set: { viewModel.showSidebar = $0 }
                    )) {
                        rightSidebar
                            .inspectorColumnWidth(min: 200, ideal: 260, max: 500)
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
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
                    ToolbarItem(placement: .primaryAction) {
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
        iosHomeView
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
                controlBar
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

}

// MARK: - Extracted SwiftUI Components
extension VTPlayerView {
    #if os(iOS)
    @ViewBuilder
    private var iosHomeView: some View {
        TabView {
            NavigationStack {
                iosGalleryView
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
            .tabItem {
                Label("Gallery", systemImage: "play.square.stack.fill")
            }

            NavigationStack {
                iosAboutView
            }
            .tabItem {
                Label("About", systemImage: "info.circle.fill")
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
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No Videos")
                        .font(.headline)
                    Text("Tap the + button to add video files.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            } else {
                let sortedVideos: [URL] = {
                    switch sortBy {
                    case .name:
                        return viewModel.recentVideos.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    case .dateAdded:
                        return viewModel.recentVideos
                    }
                }()
                
                List {
                    ForEach(sortedVideos, id: \.self) { url in
                        Button(action: {
                            viewModel.openVideo(url)
                        }) {
                            HStack(spacing: 12) {
                                VideoThumbnailView(url: url)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(url.lastPathComponent)
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                    
                                    Text(formatDateAdded(for: url))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
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
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Gallery")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Clear all button (only shown/enabled when list is not empty)
                if !viewModel.recentVideos.isEmpty {
                    Button(action: { showClearAllAlert = true }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    
                    // Sort option menu
                    Menu {
                        Picker("Sort By", selection: $sortBy) {
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
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .videos,
                        photoLibrary: .shared()
                    ) {
                        Label("Photos Library", systemImage: "photo")
                    }
                    #endif
                } label: {
                    Image(systemName: "plus")
                        .font(.body.bold())
                }
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
                            .foregroundColor(.blue)
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
                            .foregroundColor(.secondary)
                        Text("Version 1.0")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Copyright Row
            Section {
                HStack {
                    Spacer()
                    Text("Copyright © 2026 Michael Qiu. All rights reserved.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("About")
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
        .toolbar(.hidden, for: .tabBar)
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
                                .foregroundColor(.red)
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

    @ViewBuilder
    private var leftSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header matching macOS sidebar conventions
            HStack {
                Text("Recents")
                    .font(.system(.callout, design: .default).weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !viewModel.recentVideos.isEmpty {
                    Button("Clear") {
                        #if os(macOS)
                        NSDocumentController.shared.clearRecentDocuments(nil)
                        viewModel.reloadRecentVideos()
                        #endif
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 8)

            if viewModel.recentVideos.isEmpty {
                VStack {
                    Spacer()
                    ContentUnavailableView {
                        Label("No Recents", systemImage: "clock")
                    } description: {
                        Text("Open a video to see it here.")
                    } actions: {
                        VStack(spacing: 8) {
                            Button(action: { showFileImporter = true }) {
                                Text("Open from Files...")
                            }
                            .buttonStyle(.borderedProminent)
                            
                            #if canImport(PhotosUI)
                            PhotosPicker(
                                selection: $selectedPhotoItem,
                                matching: .videos,
                                photoLibrary: .shared()
                            ) {
                                Text("Open from Photos...")
                            }
                            .buttonStyle(.bordered)
                            #endif
                        }
                    }
                    Spacer()
                }
            } else {
                List(viewModel.recentVideos, id: \.self) { url in
                    Button(action: {
                        viewModel.openRecentVideo(url)
                        withAnimation {
                            columnVisibility = .detailOnly
                        }
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "film")
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .font(.system(.subheadline, design: .default))
                                Text(url.path.replacingOccurrences(of: url.lastPathComponent, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(url == viewModel.videoURL ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help(url.path)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }
    
    @ViewBuilder
    private var rightSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("DIAGNOSTICS & METADATA")
                    .font(.system(.footnote, design: .default)).bold()
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Real-Time Metrics")
                        .font(.system(.subheadline, design: .default).bold())
                        .foregroundColor(.secondary)

                    Group {
                        LabeledContent("Frame Processing") {
                            Text(String(format: "%.1f ms", viewModel.frameProcessingTime))
                                .monospacedDigit()
                        }
                        LabeledContent("Display Rate") {
                            Text(String(format: "%.1f Hz", viewModel.fps))
                                .monospacedDigit()
                                .foregroundColor(viewModel.fps > (viewModel.sourceFrameRate * 0.8) ? .blue : .red)
                        }
                        LabeledContent("Cached Frames") {
                            Text("\(viewModel.frameCacheCount)")
                                .monospacedDigit()
                                .foregroundColor(viewModel.frameCacheCount > 10 ? .blue : .secondary)
                        }
                    }
                    .font(.system(.subheadline, design: .default))
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Video Metadata")
                        .font(.system(.subheadline, design: .default).bold())
                        .foregroundColor(.secondary)
                    
                    Group {
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
                    .font(.system(.subheadline, design: .default))
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Super Resolution Specs")
                        .font(.system(.subheadline, design: .default).bold())
                        .foregroundColor(.secondary)
                    
                    Group {
                        LabeledContent("SR Supported", value: viewModel.srIsSupported ? "Yes" : "No")
                            .foregroundColor(viewModel.srIsSupported ? .blue : .secondary)
                        LabeledContent("Scales", value: viewModel.srSupportedScales)
                        if viewModel.qualitySuperResolutionScaleFactor > 0 {
                            QLModelStatusView(modelManager: viewModel.modelManager)
                        }
                        if let initError = viewModel.srInitializationError {
                            LabeledContent("SR Status", value: "Error")
                                .foregroundColor(.red)
                            Text(initError)
                                .font(.system(.caption2, design: .default))
                                .foregroundColor(.red)
                                .lineLimit(3)
                        } else {
                            let isQL = viewModel.qualitySuperResolutionScaleFactor > 0
                            let scale = max(viewModel.superResolutionLevel, viewModel.qualitySuperResolutionScaleFactor)
                            LabeledContent("Active", value: scale > 0 ? "\(isQL ? "QL" : "LL") \(scale)x" : "None")
                                .foregroundColor(scale > 0 ? .blue : .secondary)
                        }
                    }
                    .font(.system(.subheadline, design: .default))
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Image Processing")
                        .font(.system(.subheadline, design: .default).bold())
                        .foregroundColor(.secondary)

                    Toggle("High Quality Downsampling", isOn: $viewModel.useHighQualityDownsampling)
                        .font(.system(.subheadline, design: .default))
                        .help("Use high-quality chroma downsampling when scaling")

                    Toggle("Real-Time Priority", isOn: $viewModel.useRealTimePriority)
                        .font(.system(.subheadline, design: .default))
                        .help("Hint VideoToolbox to prioritize real-time processing")
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var mainVideoArea: some View {
        VStack(spacing: 0) {
            ZStack {
                VTMetalRendererView(renderer: viewModel.renderer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .cornerRadius(viewModel.isFullScreen ? 0 : 8)
                    .padding(.horizontal, viewModel.isFullScreen ? 0 : 16)
                    .padding(.top, viewModel.isFullScreen ? 0 : 16)
                    .padding(.bottom, viewModel.isFullScreen ? 0 : 90)
                    .ignoresSafeArea(viewModel.isFullScreen ? .all : [])
                
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
                            .buttonStyle(.borderedProminent)
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
        VStack {
            Spacer()
            VStack(spacing: 8) {
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
                    .accentColor(.cyan)
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
                
                HStack(spacing: 20) {
                    playPauseButton

                    Divider()
                        .frame(height: 20)

                    // Super Resolution (LL SR + Quality SR)
                    Menu {
                        Picker(selection: Binding(
                            get: {
                                // Tags: 0=Off, 1=LL2, 2=LL4, 3=QL4
                                if viewModel.qualitySuperResolutionScaleFactor == 4 {
                                    3
                                } else if viewModel.superResolutionLevel > 0 {
                                    viewModel.superResolutionLevel == 4 ? 2 : 1
                                } else {
                                    0
                                }
                            },
                            set: { tag in
                                switch tag {
                                case 1: viewModel.superResolutionLevel = 2; viewModel.qualitySuperResolutionScaleFactor = 0
                                case 2: viewModel.superResolutionLevel = 4; viewModel.qualitySuperResolutionScaleFactor = 0
                                case 3: viewModel.superResolutionLevel = 0; viewModel.qualitySuperResolutionScaleFactor = 4
                                default: viewModel.superResolutionLevel = 0; viewModel.qualitySuperResolutionScaleFactor = 0
                                }
                                viewModel.updateEnhancements()
                            }
                        )) {
                            Text("Off").tag(0)
                            Divider()
                            Text("Low Latency 2x").tag(1)
                            Text("Low Latency 4x").tag(2)
                            Divider()
                            Text("Quality 4x").tag(3)
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.inline)
                    } label: {
                        let isQL = viewModel.qualitySuperResolutionScaleFactor > 0
                        let scale = max(viewModel.superResolutionLevel, viewModel.qualitySuperResolutionScaleFactor)
                        let isActive = scale > 0
                        Text(hoverSR
                            ? (isQL
                                ? "Quality SR: \(scale)x"
                                : (isActive ? "LL Super Resolution: \(scale)x" : "Super Resolution: Off"))
                            : (isQL
                                ? "SR: \(scale)x QL"
                                : "SR: \(isActive ? "\(scale)x" : "Off")")
                        )
                        .font(.caption.weight(.medium))
                        .foregroundColor(isActive ? (isQL ? Color.blue : .cyan) : .secondary)
                        .frame(width: 148, alignment: .leading)
                        .padding(.vertical, 5)
                        .background(isActive ? (isQL ? Color.blue.opacity(0.15) : Color.cyan.opacity(0.15)) : Color.white.opacity(0.05))
                        .cornerRadius(6)
                    }
                    .menuStyle(.borderlessButton)
                    .macOnHover { hoverSR = $0 }

                    // Frame Interpolation (LL FI)
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
                        Text(hoverFI
                            ? "Frame Interpolation: \(viewModel.frameInterpolationLevel > 0 ? "\(viewModel.frameInterpolationLevel)x" : "Off")"
                            : "FI: \(viewModel.frameInterpolationLevel > 0 ? "\(viewModel.frameInterpolationLevel)x" : "Off")"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundColor(viewModel.frameInterpolationLevel > 0 ? .green : .secondary)
                        .frame(width: 158, alignment: .leading)
                        .padding(.vertical, 5)
                        .background(viewModel.frameInterpolationLevel > 0 ? Color.green.opacity(0.15) : Color.white.opacity(0.05))
                        .cornerRadius(6)
                    }
                    .menuStyle(.borderlessButton)
                    .macOnHover { hoverFI = $0 }

                    // Motion Blur
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
                        Text(hoverMB
                            ? "Motion Blur: \(viewModel.motionBlurStrength > 0 ? "\(viewModel.motionBlurStrength)" : "Off")"
                            : "MB: \(viewModel.motionBlurStrength > 0 ? "\(viewModel.motionBlurStrength)" : "Off")"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundColor(viewModel.motionBlurStrength > 0 ? .purple : .secondary)
                        .frame(width: 120, alignment: .leading)
                        .padding(.vertical, 5)
                        .background(viewModel.motionBlurStrength > 0 ? Color.purple.opacity(0.15) : Color.white.opacity(0.05))
                        .cornerRadius(6)
                    }
                    .menuStyle(.borderlessButton)
                    .macOnHover { hoverMB = $0 }

                    // Denoise
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
                        Text(hoverDN
                            ? "Denoise: \(viewModel.denoiseStrength > 0 ? String(format: "%.2f", viewModel.denoiseStrength) : "Off")"
                            : "DN: \(viewModel.denoiseStrength > 0 ? String(format: "%.2f", viewModel.denoiseStrength) : "Off")"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundColor(viewModel.denoiseStrength > 0 ? .orange : .secondary)
                        .frame(width: 110, alignment: .leading)
                        .padding(.vertical, 5)
                        .background(viewModel.denoiseStrength > 0 ? Color.orange.opacity(0.15) : Color.white.opacity(0.05))
                        .cornerRadius(6)
                    }
                    .menuStyle(.borderlessButton)
                    .macOnHover { hoverDN = $0 }

                    // Sharpness Slider
                    sharpnessControl

                    // HDR Tone Mapping
                    HStack(spacing: 4) {
                        Text(hoverHDR
                            ? "HDR: \(viewModel.hdrStrength > 0 ? String(format: "%.2f", viewModel.hdrStrength) : "Off")"
                            : "HDR"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundColor(viewModel.hdrStrength > 0 ? .yellow : .secondary)
                        .frame(width: hoverHDR ? 90 : 28, alignment: .leading)
                        Slider(value: $viewModel.hdrStrength, in: 0...2, step: 0.25)
                            .accentColor(.yellow)
                            .labelsHidden()
                            .frame(width: 60)
                            .opacity(hoverHDR ? 1 : 0)
                            .allowsHitTesting(hoverHDR)
                    }
                    .macOnHover { hoverHDR = $0 }
                    .help("SDR to HDR tone mapping — expands highlights into display EDR headroom")

                    Spacer()

                    playbackSpeedControl

                    Divider()
                        .frame(height: 16)

                    fullscreenButton
                }
            }
            .macOnHover { viewModel.isHoveringControlBar = $0 }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                    .cornerRadius(16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .opacity(viewModel.showControls ? 1.0 : 0.0)
        .offset(y: viewModel.showControls ? 0 : 50)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showControls)
    }
    
    @ViewBuilder
    private var playPauseButton: some View {
        Button(action: { viewModel.togglePlayPause() }) {
            Image(systemName: (viewModel.isPlaying && !viewModel.isPaused) ? "pause.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .foregroundColor(.primary)
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
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
            .foregroundColor(viewModel.sharpness > 0 ? .cyan : .secondary)
            .frame(width: hoverSH ? 90 : 22, alignment: .leading)
            Slider(value: $viewModel.sharpness, in: 0...2, step: 0.25)
                .accentColor(.cyan)
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
                .foregroundColor(.secondary)
                .frame(width: 45, alignment: .trailing)
            Slider(value: $viewModel.playbackSpeed, in: 0.25...4.0, step: 0.25)
                .frame(width: 80)
                .accentColor(.cyan)
        }
        .help("Adjust playback speed (0.25x - 4x)")
    }
    
    @ViewBuilder
    private var fullscreenButton: some View {
        #if os(macOS)
        Button(action: {
            if let window = NSApp.mainWindow ?? NSApp.keyWindow {
                window.toggleFullScreen(nil)
            }
        }) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.body.weight(.semibold))
                .foregroundColor(.primary)
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .keyboardShortcut("f", modifiers: [])
        .help("Toggle Fullscreen (F)")
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
            .foregroundColor(modelStatusColor(modelStatus))
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
                    Picker("Super Resolution", selection: $viewModel.superResolutionLevel) {
                        Text("Off").tag(0)
                        Text("2x").tag(2)
                        Text("4x").tag(4)
                    }
                    .onChange(of: viewModel.superResolutionLevel) { _ in
                        viewModel.updateEnhancements()
                    }
                    
                    Picker("Frame Interpolation", selection: $viewModel.frameInterpolationLevel) {
                        Text("Off").tag(0)
                        Text("2x").tag(2)
                        Text("4x").tag(4)
                    }
                    .onChange(of: viewModel.frameInterpolationLevel) { _ in
                        viewModel.updateEnhancements()
                    }
                    
                    Picker("Motion Blur", selection: $viewModel.motionBlurStrength) {
                        Text("Off").tag(0)
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("20").tag(20)
                        Text("30").tag(30)
                    }
                    .onChange(of: viewModel.motionBlurStrength) { _ in
                        viewModel.updateEnhancements()
                    }
                    
                    Picker("Denoise Strength", selection: $viewModel.denoiseStrength) {
                        Text("Off").tag(0.0)
                        Text("0.25").tag(0.25)
                        Text("0.50").tag(0.5)
                        Text("0.75").tag(0.75)
                        Text("1.00").tag(1.0)
                    }
                    .onChange(of: viewModel.denoiseStrength) { _ in
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
                            .foregroundColor(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    
                    HStack {
                        Text("SDR-to-HDR Boost")
                        Spacer()
                        Slider(value: $viewModel.hdrStrength, in: 0...2, step: 0.25)
                            .frame(width: 150)
                        Text(String(format: "%.2f", viewModel.hdrStrength))
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                
                Section("System Optimizations") {
                    Toggle("High Quality Downsampling", isOn: $viewModel.useHighQualityDownsampling)
                    Toggle("Real-Time Priority", isOn: $viewModel.useRealTimePriority)
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
            self?.checkControlsVisibility()
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
        
        // Hide native fullscreen view containers
        if className.contains("FullScreen") || className.contains("Fullscreen") || className.contains("Zoom") {
            view.isHidden = true
            if let control = view as? UIControl {
                control.isEnabled = false
            }
        }
        
        var isFullscreenElement = false
        
        // Check accessibility properties
        if let label = view.accessibilityLabel?.lowercased(),
           label.contains("fullscreen") || label.contains("full screen") || label.contains("exit fullscreen") || label.contains("exit full screen") {
            isFullscreenElement = true
        }
        
        if let identifier = view.accessibilityIdentifier?.lowercased(),
           identifier.contains("fullscreen") || identifier.contains("full-screen") {
            isFullscreenElement = true
        }
        
        // Check if it's a button and inspect its image
        if let button = view as? UIButton {
            if let image = button.currentImage {
                let imageDesc = image.description.lowercased()
                if imageDesc.contains("fullscreen") || imageDesc.contains("full-screen") ||
                   imageDesc.contains("arrow.up.left") || imageDesc.contains("arrow.down.right") ||
                   imageDesc.contains("expand") || imageDesc.contains("collapse") ||
                   imageDesc.contains("resize") {
                    isFullscreenElement = true
                }
            }
        }
        
        // Check UIImageView subviews of this view for matching images
        for subview in view.subviews {
            if let imageView = subview as? UIImageView, let image = imageView.image {
                let imageDesc = image.description.lowercased()
                if imageDesc.contains("fullscreen") || imageDesc.contains("full-screen") ||
                   imageDesc.contains("arrow.up.left") || imageDesc.contains("arrow.down.right") ||
                   imageDesc.contains("expand") || imageDesc.contains("collapse") ||
                   imageDesc.contains("resize") {
                    isFullscreenElement = true
                }
            }
        }
        
        // Also check if any private properties might have image info using reflection (Mirror)
        let mirror = Mirror(reflecting: view)
        for child in mirror.children {
            if let image = child.value as? UIImage {
                let imageDesc = image.description.lowercased()
                if imageDesc.contains("fullscreen") || imageDesc.contains("full-screen") ||
                   imageDesc.contains("arrow.up.left") || imageDesc.contains("arrow.down.right") ||
                   imageDesc.contains("expand") || imageDesc.contains("collapse") ||
                   imageDesc.contains("resize") {
                    isFullscreenElement = true
                }
            }
        }
        
        if isFullscreenElement {
            view.isHidden = true
            view.alpha = 0
            if let control = view as? UIControl {
                control.isEnabled = false
            }
            view.superview?.layoutIfNeeded()
        }
        
        for subview in view.subviews {
            disableFullscreenButton(in: subview)
        }
    }
    
    private func makeBackgroundsClear(in view: UIView) {
        let className = String(describing: type(of: view))
        
        // Hide the backdrop/video presentation layers so the MTKView underneath is visible
        if className.contains("AVPlayerLayer") || className.contains("AVDisplayView") || className.contains("AVBackgroundView") {
            view.backgroundColor = .clear
            if let layerView = view as? AnyObject, layerView.responds(to: NSSelectorFromString("isOpaque")) {
                view.isOpaque = false
            }
        }
        
        // General background clear for main view controller view
        if view == self.view {
            view.backgroundColor = .clear
            view.isOpaque = false
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

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: Image? = nil
    @State private var durationString: String? = nil
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail = thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 90, height: 60)
                    .clipped()
            } else {
                Color(.secondarySystemGroupedBackground)
                    .frame(width: 90, height: 60)
                    .overlay(
                        Image(systemName: "video.fill")
                            .font(.body)
                            .foregroundColor(.secondary)
                    )
            }
            
            if let duration = durationString {
                Text(duration)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(3)
                    .padding(4)
            }
        }
        .frame(width: 90, height: 60)
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
                let uiImage = UIImage(cgImage: cgImage)
                DispatchQueue.main.async {
                    self.thumbnail = Image(uiImage: uiImage)
                }
            }
        }
    }
}
#endif
