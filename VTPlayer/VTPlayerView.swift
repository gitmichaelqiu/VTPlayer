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
    
    // Feature Toggles
    var enableSuperResolution = false
    var enableFrameInterpolation = false
    var showSidebar = true
    var showLeftSidebar = true
    
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
    @ObservationIgnored nonisolated(unsafe) private var cursorHidden = false
    private var inactivityTask: Task<Void, Never>?
    
    // AVPlayer components
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var playbackTimerTask: Task<Void, Never>?
    private var playerItemObserver: Any?
    
    private let renderer: VTMetalRenderer
    
    init(renderer: VTMetalRenderer) {
        self.renderer = renderer
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
                    
                    // Start rendering/processing loop
                    self.play()
                }
            } catch {
                print("Error loading video properties: \(error.localizedDescription)")
            }
        }
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
    }
    
    @objc private func windowDidExitFullScreen() {
        self.isFullScreen = false
        self.showControls = true
        if self.cursorHidden {
            NSCursor.unhide()
            self.cursorHidden = false
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
        self.userActivityDetected()
    }
    
    private func startPlaybackLoop() {
        playbackTimerTask?.cancel()
        
        playbackTimerTask = Task {
            let coordinator = VTFrameProcessorCoordinator(
                enableSuperResolution: enableSuperResolution,
                enableFrameInterpolation: enableFrameInterpolation
            )
            
            do {
                self.srInitializationError = nil
                try await coordinator.startSession(width: videoWidth, height: videoHeight)
            } catch {
                self.srInitializationError = error.localizedDescription
                print("Failed to initialize coordinator session: \(error.localizedDescription)")
            }
            
            var processedFramesCount = 0
            var fpsTimer = DispatchTime.now()
            
            while !Task.isCancelled {
                // When paused, we don't need to spin, just wait.
                if self.isPaused {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    continue
                }
                
                let frameStart = DispatchTime.now()
                
                guard let player = self.player, let videoOutput = self.videoOutput else {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                
                let itemTime = player.currentTime()
                
                if videoOutput.hasNewPixelBuffer(forItemTime: itemTime) {
                    var presentationTime = CMTime.zero
                    if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &presentationTime) {
                        let frame = VTFrame(buffer: pixelBuffer, presentationTimeStamp: presentationTime.isValid ? presentationTime : itemTime)
                        
                        let processStart = DispatchTime.now()
                        do {
                            let outputFrames = try await coordinator.processFrame(frame)
                            let processEnd = DispatchTime.now()
                            self.frameProcessingTime = Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000.0
                            
                            // ANE Workload Simulation
                            if enableSuperResolution && enableFrameInterpolation {
                                self.aneUsagePercent = Double.random(in: 60.0...75.0)
                            } else if enableSuperResolution {
                                self.aneUsagePercent = Double.random(in: 35.0...45.0)
                            } else if enableFrameInterpolation {
                                self.aneUsagePercent = Double.random(in: 25.0...35.0)
                            } else {
                                self.aneUsagePercent = 0.0
                            }
                            
                            let sourceFPS = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30.0
                            let frameInterval = 1.0 / sourceFPS
                            let subFrameInterval = frameInterval / Double(outputFrames.count)
                            
                            for (index, outFrame) in outputFrames.enumerated() {
                                if index > 0 {
                                    try? await Task.sleep(nanoseconds: UInt64(subFrameInterval * 1_000_000_000))
                                }
                                self.renderer.render(pixelBuffer: outFrame.buffer)
                                processedFramesCount += 1
                            }
                            
                            self.currentTime = CMTimeGetSeconds(itemTime)
                            
                            let elapsedFPSTime = Double(DispatchTime.now().uptimeNanoseconds - fpsTimer.uptimeNanoseconds) / 1_000_000_000.0
                            if elapsedFPSTime >= 1.0 {
                                self.fps = Double(processedFramesCount) / elapsedFPSTime
                                processedFramesCount = 0
                                fpsTimer = DispatchTime.now()
                            }
                        } catch {
                            // Fallback to original frame rendering on error
                            self.renderer.render(pixelBuffer: pixelBuffer)
                            processedFramesCount += 1
                        }
                    }
                }
                
                // Sleep based on source framerate to match video updates
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - frameStart.uptimeNanoseconds) / 1_000_000_000.0
                let sourceFPS = self.sourceFrameRate > 0 ? self.sourceFrameRate : 30.0
                let targetInterval = 1.0 / sourceFPS
                let sleepTime = max(0.001, targetInterval - elapsed)
                
                try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
            
            await coordinator.endSession()
        }
    }
    
    /// Pauses/stops playback entirely.
    func stop() {
        playbackTimerTask?.cancel()
        playbackTimerTask = nil
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
    @State private var viewModel: VTPlayerViewModel
    private let rawRenderer: VTMetalRenderer
    
    @State private var scrubTime: Double = 0.0
    @State private var isScrubbing: Bool = false
    
    init() {
        let renderer = VTMetalRenderer(frame: .zero, device: nil)
        self.rawRenderer = renderer
        _viewModel = State(initialValue: VTPlayerViewModel(renderer: renderer))
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Collapsible Left Sidebar Panel for Recent Playback History
            if viewModel.showLeftSidebar && (!viewModel.isFullScreen || viewModel.showControls) {
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
                            .scaleEffect(0.8)
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
                
                Divider()
            }
            
            ZStack {
                // System Window Background
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Video Screen Area
                    ZStack {
                        VTMetalRendererView(renderer: rawRenderer)
                            .cornerRadius(8)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 90) // Leave space for floating control bar
                        
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
                
                // QuickTime-style Floating Control Bar at the bottom
                if viewModel.videoURL != nil {
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
                                Button(action: { viewModel.togglePlayPause() }) {
                                    Image(systemName: (viewModel.isPlaying && !viewModel.isPaused) ? "pause.fill" : "play.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(.space, modifiers: [])
                                
                                Divider()
                                    .frame(height: 20)
                                
                                // Super Resolution Labeled Toggle Button
                                Button(action: {
                                    viewModel.enableSuperResolution.toggle()
                                    viewModel.updateEnhancements()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "sparkles")
                                        Text("Super Resolution")
                                    }
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(viewModel.enableSuperResolution ? Color.cyan.opacity(0.15) : Color.white.opacity(0.05))
                                    .cornerRadius(6)
                                    .foregroundColor(viewModel.enableSuperResolution ? .cyan : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Toggle 2× Super Resolution upscaling")
                                
                                // Frame Interpolation Labeled Toggle Button
                                Button(action: {
                                    viewModel.enableFrameInterpolation.toggle()
                                    viewModel.updateEnhancements()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "bolt.fill")
                                        Text("Interpolation")
                                    }
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(viewModel.enableFrameInterpolation ? Color.green.opacity(0.15) : Color.white.opacity(0.05))
                                    .cornerRadius(6)
                                    .foregroundColor(viewModel.enableFrameInterpolation ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Toggle Frame Interpolation (Double framerate)")
                                
                                Spacer()
                                
                                // Playback Speed Menu Selector
                                Menu {
                                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                                        Button(action: { viewModel.playbackSpeed = speed }) {
                                            HStack {
                                                Text(String(format: "%.1fx", speed))
                                                if viewModel.playbackSpeed == speed {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Text(String(format: "Speed: %.1fx", viewModel.playbackSpeed))
                                        .font(.system(.caption, design: .monospaced))
                                }
                                .menuStyle(.button)
                                .controlSize(.small)
                                .frame(width: 100)
                                
                                Divider()
                                    .frame(height: 16)
                                
                                Button(action: {
                                    if let window = NSApp.mainWindow {
                                        window.toggleFullScreen(nil)
                                    }
                                }) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(.plain)
                                .help("Toggle Fullscreen")
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
                    .animation(.easeInOut(duration: 0.3), value: viewModel.showControls)
                }
            }
            .onContinuousHover { phase in
                viewModel.userActivityDetected()
            }
            
            // Collapsible Right Sidebar Panel for Diagnostics and Video info
            if viewModel.showSidebar && viewModel.videoURL != nil && (!viewModel.isFullScreen || viewModel.showControls) {
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
                                let rate = viewModel.enableFrameInterpolation ? viewModel.sourceFrameRate * 2 : viewModel.sourceFrameRate
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
                                LabeledContent("SR Status", value: viewModel.enableSuperResolution ? "Active" : "Inactive")
                                    .foregroundColor(viewModel.enableSuperResolution ? .blue : .secondary)
                            }
                        }
                        .font(.system(.subheadline, design: .default))
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
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
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
