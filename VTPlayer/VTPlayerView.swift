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
    
    var currentBackgroundColor: Color {
        if isFullScreen {
            return Color.black
        } else if videoURL != nil {
            return Color.black
        } else {
            return Color(nsColor: .windowBackgroundColor)
        }
    }
    
    var superResolutionText: String {
        superResolutionLevel > 0 ? "SR: \(superResolutionLevel)x" : "Super Resolution"
    }
    
    var superResolutionBackgroundColor: Color {
        superResolutionLevel > 0 ? Color.cyan.opacity(0.15) : Color.white.opacity(0.05)
    }
    
    var superResolutionForegroundColor: Color {
        superResolutionLevel > 0 ? Color.cyan : Color.secondary
    }
    
    var frameInterpolationText: String {
        frameInterpolationLevel > 0 ? "Interpolation: \(frameInterpolationLevel)x" : "Interpolation"
    }
    
    var frameInterpolationBackgroundColor: Color {
        frameInterpolationLevel > 0 ? Color.green.opacity(0.15) : Color.white.opacity(0.05)
    }
    
    var frameInterpolationForegroundColor: Color {
        frameInterpolationLevel > 0 ? Color.green : Color.secondary
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

    // Audio sync state
    private var lastRenderedPTS: CMTime = .zero
    private var isAudioPausedForSync = false
    private var audioSyncTask: Task<Void, Never>?
    private let audioSyncLatencyThreshold: Double = 0.1
    private let audioSyncRecoveryFrameCount: Int = 5
    
    let renderer: VTMetalRenderer
    
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
        inactivityTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard !Task.isCancelled else { return }
            if self.isFullScreen && self.isPlaying && !self.isPaused {
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
        self.isAudioPausedForSync = false
        self.lastRenderedPTS = .zero
        self.processedFrameCache.removeAll()
        self.lastPulledTime = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            guard completed, let self = self else { return }
            Task { @MainActor in
                await self.triggerSingleFrameUpdate(at: time)
            }
        }
    }
    
    /// Seeks and draws the frame immediately during continuous scrubbing.
    func scrub(to seconds: Double) {
        self.currentTime = seconds
        self.saveProgress()
        self.isAudioPausedForSync = false
        self.lastRenderedPTS = .zero
        self.processedFrameCache.removeAll()
        self.lastPulledTime = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        
        // Pull and render frame immediately
        var presentationTime = CMTime.zero
        if let videoOutput = videoOutput,
           let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentationTime) {
            self.renderer.render(pixelBuffer: pixelBuffer)
        }
    }
    
    private func triggerSingleFrameUpdate(at time: CMTime) async {
        guard let videoOutput = videoOutput else { return }
        var attempts = 0
        while attempts < 5 {
            if videoOutput.hasNewPixelBuffer(forItemTime: time) {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            attempts += 1
        }
        
        var presentationTime = CMTime.zero
        if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentationTime) {
            self.renderer.render(pixelBuffer: pixelBuffer)
        }
    }
    
    /// Updates coordinator when features are toggled without changing playback state.
    func updateEnhancements() {
        if isPlaying {
            startPlaybackLoop()
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
        
        startPlaybackLoop()
        self.userActivityDetected()
    }
    
    /// Pauses player
    func pause() {
        guard let player = player else { return }
        player.pause()
        self.isPaused = true
        self.saveProgress()
        self.userActivityDetected()
    }
    
    private func startPlaybackLoop() {
        producerTask?.cancel()
        consumerTask?.cancel()
        
        processedFrameCache.removeAll()
        if let player = player {
            lastPulledTime = player.currentTime()
        } else {
            lastPulledTime = .zero
        }
        
        let srLevel = self.superResolutionLevel
        let fiLevel = self.frameInterpolationLevel
        let highQuality = self.useHighQualityDownsampling
        let realTime = self.useRealTimePriority
        
        producerTask = Task {
            let coordinator = VTFrameProcessorCoordinator(
                superResolutionLevel: srLevel,
                frameInterpolationLevel: fiLevel,
                useHighQualityDownsampling: highQuality,
                useRealTimePriority: realTime
            )
            
            do {
                self.srInitializationError = nil
                try await coordinator.startSession(width: videoWidth, height: videoHeight)
            } catch {
                self.srInitializationError = error.localizedDescription
                print("Failed to initialize coordinator session: \(error.localizedDescription)")
                return
            }
            
            let sourceFPS = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30.0
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(sourceFPS))
            
            while !Task.isCancelled {
                if self.isPaused {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    continue
                }
                
                guard let player = self.player, let videoOutput = self.videoOutput else {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                
                if self.processedFrameCache.count >= 15 {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                
                let nextPullTime = CMTimeAdd(self.lastPulledTime, frameDuration)
                let playerTime = player.currentTime()
                let maxLookahead = CMTimeAdd(playerTime, CMTime(seconds: 0.5, preferredTimescale: 600))
                if nextPullTime > maxLookahead {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    continue
                }
                
                if videoOutput.hasNewPixelBuffer(forItemTime: nextPullTime) {
                    var presentationTime = CMTime.zero
                    if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: nextPullTime, itemTimeForDisplay: &presentationTime) {
                        let frame = VTFrame(buffer: pixelBuffer, presentationTimeStamp: presentationTime.isValid ? presentationTime : nextPullTime)
                        
                        let processStart = DispatchTime.now()
                        do {
                            let outputFrames = try await coordinator.processFrame(frame)
                            let processEnd = DispatchTime.now()
                            
                            self.frameProcessingTime = Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000.0
                            
                            // ANE usage not yet measurable via public API — placeholder for future telemetry
                            self.aneUsagePercent = 0.0
                            
                            self.processedFrameCache.append(contentsOf: outputFrames)
                            self.processedFrameCache.sort { $0.presentationTimeStamp < $1.presentationTimeStamp }
                            
                            self.lastPulledTime = nextPullTime
                        } catch {
                            self.processedFrameCache.append(frame)
                            self.lastPulledTime = nextPullTime
                        }
                    } else {
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            
            await coordinator.endSession()
        }
        
        consumerTask = Task {
            var processedFramesCount = 0
            var fpsTimer = DispatchTime.now()
            
            while !Task.isCancelled {
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
                
                if !self.processedFrameCache.isEmpty {
                    let firstFrame = self.processedFrameCache[0]
                    let frameTime = CMTimeGetSeconds(firstFrame.presentationTimeStamp)

                    if frameTime <= currentSecs + 0.005 {
                        self.renderer.render(pixelBuffer: firstFrame.buffer)
                        self.lastRenderedPTS = firstFrame.presentationTimeStamp
                        processedFramesCount += 1

                        self.processedFrameCache.removeFirst()
                        self.currentTime = currentSecs
                    }
                }
                
                let elapsedFPSTime = Double(DispatchTime.now().uptimeNanoseconds - fpsTimer.uptimeNanoseconds) / 1_000_000_000.0
                if elapsedFPSTime >= 1.0 {
                    self.fps = Double(processedFramesCount) / elapsedFPSTime
                    processedFramesCount = 0
                    fpsTimer = DispatchTime.now()
                }
                
                if let nextFrame = self.processedFrameCache.first {
                    let nextPTS = CMTimeGetSeconds(nextFrame.presentationTimeStamp)
                    let sleepDuration = max(0.001, nextPTS - currentSecs - 0.002)
                    try? await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
                } else {
                    try? await Task.sleep(nanoseconds: 4_000_000)
                }
            }
        }

        audioSyncTask?.cancel()
        audioSyncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !self.isPaused, let player = self.player else { continue }
                let currentSecs = CMTimeGetSeconds(player.currentTime())
                let lastSecs = CMTimeGetSeconds(self.lastRenderedPTS)
                let latency = currentSecs - lastSecs

                if latency > self.audioSyncLatencyThreshold && !self.isAudioPausedForSync {
                    player.rate = 0
                    self.isAudioPausedForSync = true
                } else if self.isAudioPausedForSync {
                    if self.processedFrameCache.count >= self.audioSyncRecoveryFrameCount || latency <= 0 {
                        player.rate = Float(self.playbackSpeed)
                        self.isAudioPausedForSync = false
                    }
                }
            }
        }
    }

    /// Pauses/stops playback entirely.
    func stop() {
        if self.currentTime > 0 {
            self.saveProgress()
        }
        producerTask?.cancel()
        producerTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        audioSyncTask?.cancel()
        audioSyncTask = nil
        isAudioPausedForSync = false
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
        self.userActivityDetected()
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
    
    @State private var scrubTime: Double = 0.0
    @State private var isScrubbing: Bool = false
    
    init() {}
    
    var body: some View {
        HStack(spacing: 0) {
            // Collapsible Left Sidebar Panel for Recent Playback History
            if viewModel.showLeftSidebar && !viewModel.isFullScreen {
                leftSidebar
                Divider()
            }
            
            ZStack {
                // System Window Background
                viewModel.currentBackgroundColor
                    .ignoresSafeArea()
                
                mainVideoArea
                
                // QuickTime-style Floating Control Bar at the bottom
                if viewModel.videoURL != nil {
                    controlBar
                }
            }
            .onContinuousHover { phase in
                viewModel.userActivityDetected()
            }
            
            // Collapsible Right Sidebar Panel for Diagnostics and Video info
            if viewModel.showSidebar && viewModel.videoURL != nil && !viewModel.isFullScreen {
                rightSidebar
            }
        }
        .animation(.easeInOut, value: viewModel.showLeftSidebar)
        .animation(.easeInOut, value: viewModel.showSidebar)
        // Native System Toolbar in window titlebar
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { viewModel.showLeftSidebar.toggle() }) {
                    Label("Toggle Recents", systemImage: "sidebar.left")
                }
                .help("Toggle recent videos sidebar")
            }
            
            ToolbarItem(placement: .navigation) {
                Button(action: { viewModel.selectFile() }) {
                    Label("Open Video", systemImage: "folder.badge.plus")
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
            Text("RECENT PLAYBACKS")
                .font(.system(.footnote, design: .default)).bold()
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)
            
            if viewModel.recentVideos.isEmpty {
                VStack {
                    Spacer()
                    ContentUnavailableView {
                        Label("No Recents", systemImage: "clock")
                    }
                    Spacer()
                }
            } else {
                List(viewModel.recentVideos, id: \.self) { url in
                    Button(action: { viewModel.openRecentVideo(url) }) {
                        HStack(spacing: 8) {
                            Image(systemName: "film")
                                .foregroundColor(.secondary)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.system(.subheadline, design: .default))
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help(url.path)
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 240)
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
        )
        .transition(.move(edge: .leading))
    }
    
    @ViewBuilder
    private var rightSidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("DIAGNOSTICS & METADATA")
                .font(.system(.footnote, design: .default)).bold()
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Enhancement Metrics")
                    .font(.system(.subheadline, design: .default).bold())
                    .foregroundColor(.secondary)
                
                Group {
                    LabeledContent("ANE Workload") {
                        Text(String(format: "%.1f%%", viewModel.aneUsagePercent))
                            .monospacedDigit()
                    }
                    LabeledContent("Processing Time") {
                        Text(String(format: "%.1f ms", viewModel.frameProcessingTime))
                            .monospacedDigit()
                    }
                    LabeledContent("Display Rate") {
                        Text(String(format: "%.1f Hz", viewModel.fps))
                            .monospacedDigit()
                            .foregroundColor(viewModel.fps > (viewModel.sourceFrameRate * 1.8) ? .blue : .primary)
                    }
                    LabeledContent("Late Frames") {
                        Text("\(viewModel.droppedFrames)")
                            .monospacedDigit()
                            .foregroundColor(viewModel.droppedFrames > 0 ? .red : .primary)
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
                    if let initError = viewModel.srInitializationError {
                        LabeledContent("SR Status", value: "Error")
                            .foregroundColor(.red)
                        Text(initError)
                            .font(.system(.caption2, design: .default))
                            .foregroundColor(.red)
                            .lineLimit(3)
                    } else {
                        LabeledContent("SR Status", value: viewModel.superResolutionLevel > 0 ? "Active (\(viewModel.superResolutionLevel)x)" : "Inactive")
                            .foregroundColor(viewModel.superResolutionLevel > 0 ? .blue : .secondary)
                    }
                }
                .font(.system(.subheadline, design: .default))
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Fallback Upscaling Settings")
                    .font(.system(.subheadline, design: .default).bold())
                    .foregroundColor(.secondary)
                
                Toggle("High Quality Downsampling", isOn: $viewModel.useHighQualityDownsampling)
                    .font(.system(.subheadline, design: .default))
                    .help("Use high-quality chroma downsampling when scaling")
                
                Toggle("Real-Time Priority", isOn: $viewModel.useRealTimePriority)
                    .font(.system(.subheadline, design: .default))
                    .help("Hint VideoToolbox to prioritize real-time processing")
            }
            
            Spacer()
        }
        .padding(20)
        .frame(width: 260)
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
        )
        .transition(.move(edge: .trailing))
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
                    
                    superResolutionMenu
                    
                    frameInterpolationMenu
                    
                    Spacer()
                    
                    playbackSpeedControl
                    
                    Divider()
                        .frame(height: 16)
                    
                    fullscreenButton
                }
            }
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
    private var superResolutionMenu: some View {
        Picker(selection: Binding(
            get: { viewModel.superResolutionLevel },
            set: { viewModel.superResolutionLevel = $0; viewModel.updateEnhancements() }
        )) {
            Text("Off").tag(0)
            Text("2× Super Resolution").tag(2)
            Text("4× Super Resolution").tag(4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(viewModel.superResolutionText)
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(viewModel.superResolutionBackgroundColor)
            .cornerRadius(6)
            .foregroundColor(viewModel.superResolutionForegroundColor)
        }
        .pickerStyle(.menu)
        .help("Select Super Resolution upscaling level")
    }
    
    @ViewBuilder
    private var frameInterpolationMenu: some View {
        Picker(selection: Binding(
            get: { viewModel.frameInterpolationLevel },
            set: { viewModel.frameInterpolationLevel = $0; viewModel.updateEnhancements() }
        )) {
            Text("Off").tag(0)
            Text("2× Interpolation").tag(2)
            Text("4× Interpolation").tag(4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                Text(viewModel.frameInterpolationText)
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(viewModel.frameInterpolationBackgroundColor)
            .cornerRadius(6)
            .foregroundColor(viewModel.frameInterpolationForegroundColor)
        }
        .pickerStyle(.menu)
        .help("Select Frame Interpolation level")
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
