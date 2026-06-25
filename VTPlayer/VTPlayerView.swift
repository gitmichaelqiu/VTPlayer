//
//  VTPlayerView.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import SwiftUI
import AVFoundation
import MetalKit
import VideoToolbox
import AppKit

/// SwiftUI Representable wrapper for the VTMetalRenderer.
struct VTMetalRendererView: NSViewRepresentable {
    let renderer: VTMetalRenderer
    
    func makeNSView(context: Context) -> VTMetalRenderer {
        return renderer
    }
    
    func updateNSView(_ nsView: VTMetalRenderer, context: Context) {}
}

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
            return Color(nsColor: .windowBackgroundColor)
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
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var producerTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?
    private var processedFrameCache: [VTFrame] = []
    private var lastPulledTime: CMTime = .zero
    private var playerItemObserver: Any?
    private var playbackGeneration: UInt64 = 0
    private var isInitializingPipeline = false

    // Audio sync monitoring (diagnostic only — never pauses player)
    private var lastRenderedPTS: CMTime = .zero
    var audioSyncLatency: Double = 0
    private var audioSyncTask: Task<Void, Never>?
    private let audioSyncLatencyThreshold: Double = 0.1
    
    let renderer: VTMetalRenderer
    let modelManager = VTModelManager()

    init() {
        self.renderer = VTMetalRenderer(frame: .zero, device: nil)
        self.recentVideos = NSDocumentController.shared.recentDocumentURLs
        self.useHighQualityDownsampling = UserDefaults.standard.object(forKey: "VTUseHighQualityDownsampling") as? Bool ?? true
        self.useRealTimePriority = UserDefaults.standard.object(forKey: "VTUseRealTimePriority") as? Bool ?? true

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
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        if cursorHidden {
            NSCursor.unhide()
        }
    }
    
    /// Launches an NSOpenPanel to select a local media file.
    func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK, let url = panel.url {
            self.stop()
            self.videoURL = url
            self.setupPlayer(with: url)
        }
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

                let newPlayer = AVPlayer(playerItem: item)
                newPlayer.automaticallyWaitsToMinimizeStalling = false
                
                // Update properties on @MainActor
                await MainActor.run {
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    self.reloadRecentVideos()
                    
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
                    
                    // Retrieve and apply saved playback progress
                    let savedProgress = UserDefaults.standard.double(forKey: "VTPlaybackProgress_\(url.path)")
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
            }
        }
    }
    
    func saveProgress() {
        guard let url = videoURL else { return }
        UserDefaults.standard.set(self.currentTime, forKey: "VTPlaybackProgress_\(url.path)")
    }
    
    @objc func reloadRecentVideos() {
        self.recentVideos = NSDocumentController.shared.recentDocumentURLs
    }
    
    func openRecentVideo(_ url: URL) {
        self.stop()
        self.videoURL = url
        self.setupPlayer(with: url)
    }
    
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
    
    func userActivityDetected() {
        if isFullScreen && isPlaying && !isPaused {
            self.showControls = true
            if self.cursorHidden {
                NSCursor.unhide()
                self.cursorHidden = false
            }
            startInactivityTimer()
        } else {
            self.showControls = true
            if self.cursorHidden {
                NSCursor.unhide()
                self.cursorHidden = false
            }
            inactivityTask?.cancel()
        }
    }
    
    private func startInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard !Task.isCancelled, let self = self else { return }
            if self.isFullScreen && self.isPlaying && !self.isPaused && !self.isHoveringControlBar {
                self.showControls = false
                if !self.cursorHidden {
                    NSCursor.hide()
                    self.cursorHidden = true
                }
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

    /// Seeks and draws the frame immediately during continuous scrubbing.
    func scrub(to seconds: Double) {
        self.currentTime = seconds
        self.saveProgress()
        self.lastRenderedPTS = .zero
        self.processedFrameCache.removeAll()
        self.lastPulledTime = CMTime(seconds: seconds, preferredTimescale: 600)
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
        if isPlaying && !isPaused {
            startPlaybackLoop()
        } else if isPlaying && isPaused {
            // Don't restart the pipeline while paused — the cache clear
            // would cause a visible freeze on resume.  Flag it so play()
            // rebuilds the pipeline when the user unpauses.
            enhancementsPendingRestart = true
        }
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
        
        // Always rebuild the pipeline if enhancements were changed while
        // paused.  Otherwise, just start the loop normally.
        if enhancementsPendingRestart {
            enhancementsPendingRestart = false
        }
        startPlaybackLoop()
        self.userActivityDetected()
    }
    
    /// Pauses player
    func pause() {
        guard let player = player else { return }
        player.pause()
        self.isPaused = true
        self.saveProgress()
        self.saveVideoSettings()
        self.userActivityDetected()
    }
    
    private func startPlaybackLoop() {
        playbackGeneration += 1
        let gen = playbackGeneration
        producerTask?.cancel()
        consumerTask?.cancel()

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

            // Check Quality SR model availability before starting
            var effectiveQualitySR = qualitySR
            var effectiveSRLevel = srLevel
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
        
        consumerTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let myGen = gen
            var processedFramesCount = 0
            var fpsTimer = DispatchTime.now()
            var diagTimer = DispatchTime.now()

            while !Task.isCancelled {
                guard myGen == self.playbackGeneration else { break }

                if self.isPaused {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }

                guard let player = self.player else {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }

                let currentTime = player.currentTime()
                let currentSecs = CMTimeGetSeconds(currentTime)

                // Drain all frames whose PTS ≤ current player time, but only
                // render the *last* one.  When catching up (e.g. after a
                // pipeline restart), the loop may drain many frames at once;
                // calling renderer.render() for each one wastes GPU cycles and
                // can stall on Metal drawable contention, making playback
                // appear slow — especially with FI generating 2–4× more frames.
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
                    self.renderer.render(pixelBuffer: frame.buffer)
                    processedFramesCount += drained
                    self.currentTime = currentSecs
                    if drained > 1 {
                        self.droppedFrames += drained - 1
                    }
                }

                let elapsedFPSTime = Double(DispatchTime.now().uptimeNanoseconds - fpsTimer.uptimeNanoseconds) / 1_000_000_000.0
                if elapsedFPSTime >= 1.0 {
                    self.fps = Double(processedFramesCount) / elapsedFPSTime
                    processedFramesCount = 0
                    fpsTimer = DispatchTime.now()
                }

                // Diagnostic log every 5 seconds
                let diagElapsed = Double(DispatchTime.now().uptimeNanoseconds - diagTimer.uptimeNanoseconds) / 1_000_000_000.0
                if diagElapsed >= 5.0 {
                    let curRate = player.rate
                    let curFPS = self.fps
                    if let first = self.processedFrameCache.first {
                        let ft = CMTimeGetSeconds(first.presentationTimeStamp)
                        print("DIAG: cache=\(self.processedFrameCache.count) currentSecs=\(String(format: "%.3f", currentSecs)) nextPTS=\(String(format: "%.3f", ft)) rate=\(curRate) rendered=\(curFPS)")
                    } else {
                        print("DIAG: cache=0 currentSecs=\(String(format: "%.3f", currentSecs)) rate=\(curRate) rendered=\(curFPS)")
                    }
                    diagTimer = DispatchTime.now()
                }

                // Cache-safe sleep calculation.
                if let nextFrame = self.processedFrameCache.first {
                    let nextPTS = CMTimeGetSeconds(nextFrame.presentationTimeStamp)
                    // Re-read currentSecs for a more accurate sleep duration.
                    let updatedSecs = CMTimeGetSeconds(player.currentTime())
                    let sleepDuration = max(0.001, nextPTS - updatedSecs - 0.002)
                    try? await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
                } else {
                    try? await Task.sleep(nanoseconds: 4_000_000)
                }
            }
        }

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
                if player.rate == 0 && self.isPlaying && !self.isInitializingPipeline {
                    player.rate = Float(self.playbackSpeed)
                }
            }
        }
    }

    /// Pauses/stops playback entirely.
    func stop() {
        if self.currentTime > 0 {
            self.saveProgress()
        }
        saveVideoSettings()
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        audioSyncTask?.cancel()
        audioSyncTask = nil
        audioSyncLatency = 0
        lastRenderedPTS = .zero
        processedFrameCache.removeAll()
        
        if let observer = playerItemObserver {
            NotificationCenter.default.removeObserver(observer)
            playerItemObserver = nil
        }
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
        UserDefaults.standard.set(settings, forKey: Self.videoSettingsKey(for: url.path))
    }

    private func loadVideoSettings(for url: URL) {
        guard let settings = UserDefaults.standard.dictionary(forKey: Self.videoSettingsKey(for: url.path)) else { return }
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
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

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
        if !viewModel.isFullScreen {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                leftSidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 500)
            } detail: {
                videoContent
                    .inspector(isPresented: Binding(
                        get: { viewModel.showSidebar && viewModel.videoURL != nil },
                        set: { viewModel.showSidebar = $0 }
                    )) {
                        rightSidebar
                            .inspectorColumnWidth(min: 200, ideal: 260, max: 500)
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: { viewModel.selectFile() }) {
                        Label("Open Video", systemImage: "plus")
                    }
                    .help("Open a local video file")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { viewModel.showSidebar.toggle() }) {
                        Label("Toggle Sidebar", systemImage: "sidebar.right")
                    }
                    .help("Toggle diagnostics and metadata sidebar panel")
                }
            }
            .windowToolbarFullScreenVisibility(.onHover)
        } else {
            videoContent
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: { viewModel.selectFile() }) {
                            Label("Open Video", systemImage: "plus")
                        }
                        .help("Open a local video file")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: { viewModel.showSidebar.toggle() }) {
                            Label("Toggle Sidebar", systemImage: "sidebar.right")
                        }
                        .help("Toggle diagnostics and metadata sidebar panel")
                    }
                }
                .windowToolbarFullScreenVisibility(.onHover)
        }
    }

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

}

// MARK: - Extracted SwiftUI Components
extension VTPlayerView {
    
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
                        NSDocumentController.shared.clearRecentDocuments(nil)
                        viewModel.reloadRecentVideos()
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
                    }
                    Spacer()
                }
            } else {
                List(viewModel.recentVideos, id: \.self) { url in
                    Button(action: { viewModel.openRecentVideo(url) }) {
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
                        Button(action: { viewModel.selectFile() }) {
                            Text("Open Video File...")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
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
                    .onHover { hoverSR = $0 }

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
                    .onHover { hoverFI = $0 }

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
                    .onHover { hoverMB = $0 }

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
                    .onHover { hoverDN = $0 }

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
                    .onHover { hoverHDR = $0 }
                    .help("SDR to HDR tone mapping — expands highlights into display EDR headroom")

                    Spacer()

                    playbackSpeedControl

                    Divider()
                        .frame(height: 16)

                    fullscreenButton
                }
            }
            .onHover { viewModel.isHoveringControlBar = $0 }
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
        .onHover { hoverSH = $0 }
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

/// Helper view for macOS blur/visual effect backgrounds.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
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
