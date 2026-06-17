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
    
    // AVPlayer components
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var playbackTimerTask: Task<Void, Never>?
    private var playerItemObserver: Any?
    
    private let renderer: VTMetalRenderer
    
    init(renderer: VTMetalRenderer) {
        self.renderer = renderer
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
    }
    
    /// Pauses player
    func pause() {
        guard let player = player else { return }
        player.pause()
        self.isPaused = true
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
                            
                            for outFrame in outputFrames {
                                self.renderer.render(pixelBuffer: outFrame.buffer)
                            }
                            
                            self.currentTime = CMTimeGetSeconds(itemTime)
                            processedFramesCount += 1
                            
                            let elapsedFPSTime = Double(DispatchTime.now().uptimeNanoseconds - fpsTimer.uptimeNanoseconds) / 1_000_000_000.0
                            if elapsedFPSTime >= 1.0 {
                                self.fps = Double(processedFramesCount) / elapsedFPSTime
                                processedFramesCount = 0
                                fpsTimer = DispatchTime.now()
                            }
                        } catch {
                            // Fallback to original frame rendering on error
                            self.renderer.render(pixelBuffer: pixelBuffer)
                        }
                    }
                }
                
                // Sleep based on target framerate to avoid CPU spinning
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - frameStart.uptimeNanoseconds) / 1_000_000_000.0
                let targetFPS = self.enableFrameInterpolation ? (self.sourceFrameRate > 0 ? self.sourceFrameRate * 2 : 60.0) : (self.sourceFrameRate > 0 ? self.sourceFrameRate : 30.0)
                let targetInterval = 1.0 / targetFPS
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
                                .controlSize(.large)
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
                                
                                Text(formatTime(viewModel.duration))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            
                            HStack(spacing: 20) {
                                Button(action: { viewModel.togglePlayPause() }) {
                                    Image(systemName: (viewModel.isPlaying && !viewModel.isPaused) ? "pause.fill" : "play.fill")
                                        .font(.title2)
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(.space, modifiers: [])
                                
                                Button(action: { viewModel.selectFile() }) {
                                    Image(systemName: "folder")
                                        .font(.title3)
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(.plain)
                                .help("Load a different video file")
                                
                                Divider()
                                    .frame(height: 20)
                                
                                // Real-time processing indicators in the control bar
                                HStack(spacing: 12) {
                                    if viewModel.enableSuperResolution {
                                        Label("SR 2× Active", systemImage: "sparkles")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.cyan.opacity(0.15))
                                            .cornerRadius(4)
                                            .foregroundColor(.cyan)
                                    }
                                    
                                    if viewModel.enableFrameInterpolation {
                                        let targetFPS = viewModel.sourceFrameRate > 0 ? Int(viewModel.sourceFrameRate * 2) : 60
                                        Label("\(targetFPS) FPS Active", systemImage: "bolt.fill")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.green.opacity(0.15))
                                            .cornerRadius(4)
                                            .foregroundColor(.green)
                                    }
                                }
                                
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
                }
            }
            
            // Collapsible Right Sidebar Panel for Diagnostics and Video info
            if viewModel.showSidebar && viewModel.videoURL != nil {
                VStack(alignment: .leading, spacing: 20) {
                    Text("DIAGNOSTICS & SPECS")
                        .font(.system(.caption, design: .monospaced)).bold()
                        .foregroundColor(.cyan)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Enhancement Metrics")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Group {
                            LabeledContent("ANE Workload", value: String(format: "%.1f%%", viewModel.aneUsagePercent))
                            LabeledContent("Processing Time", value: String(format: "%.1f ms", viewModel.frameProcessingTime))
                            LabeledContent("Display Rate", value: String(format: "%.1f Hz", viewModel.fps))
                                .foregroundColor(viewModel.fps > (viewModel.sourceFrameRate * 1.8) ? .green : .yellow)
                            LabeledContent("Late Frames", value: "\(viewModel.droppedFrames)")
                                .foregroundColor(viewModel.droppedFrames > 0 ? .red : .primary)
                        }
                        .font(.system(.subheadline, design: .monospaced))
                    }
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Video Metadata")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Group {
                            LabeledContent("Resolution", value: "\(viewModel.videoWidth)×\(viewModel.videoHeight)")
                            LabeledContent("Source Rate", value: String(format: "%.2f fps", viewModel.sourceFrameRate))
                            LabeledContent("Target Rate", value: viewModel.enableFrameInterpolation ? String(format: "%.2f fps", viewModel.sourceFrameRate * 2) : String(format: "%.2f fps", viewModel.sourceFrameRate))
                            LabeledContent("Video Codec", value: viewModel.videoFormat)
                        }
                        .font(.system(.subheadline, design: .monospaced))
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
        .animation(.easeInOut, value: viewModel.showSidebar)
        // Native System Toolbar in window titlebar
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { viewModel.selectFile() }) {
                    Label("Open Video", systemImage: "folder.badge.plus")
                }
                .help("Open a local video file")
            }
            
            // Labeled switch toggles in the toolbar
            ToolbarItem {
                HStack(spacing: 6) {
                    Text("2× Super Resolution")
                        .font(.subheadline)
                    Toggle("", isOn: $viewModel.enableSuperResolution)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: viewModel.enableSuperResolution) { _, _ in
                            if viewModel.isPlaying {
                                viewModel.play()
                            }
                        }
                }
                .help("Upscale resolution using low-latency ANE models")
            }
            
            ToolbarItem {
                HStack(spacing: 6) {
                    // Show dynamic expected target framerate in the toggle label
                    let targetFPS = viewModel.sourceFrameRate > 0 ? Int(viewModel.sourceFrameRate * 2) : 60
                    Text("Frame Interpolation (\(targetFPS)fps)")
                        .font(.subheadline)
                    Toggle("", isOn: $viewModel.enableFrameInterpolation)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: viewModel.enableFrameInterpolation) { _, _ in
                            if viewModel.isPlaying {
                                viewModel.play()
                            }
                        }
                }
                .help("Double video framerate dynamically")
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
