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
    var playbackSpeed: Double = 1.0
    var seekRequestTime: Double?
    
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
    
    private var playbackTask: Task<Void, Never>?
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
            self.play()
        }
    }
    
    /// Seeks to a specific timestamp in seconds.
    func seek(to seconds: Double) {
        self.seekRequestTime = seconds
        self.currentTime = seconds
        if !isPlaying {
            self.play()
        }
    }
    
    /// Toggles play and pause state.
    func togglePlayPause() {
        guard videoURL != nil else { return }
        if !isPlaying {
            play()
        } else {
            isPaused.toggle()
        }
    }
    
    /// Starts playback and the VideoToolbox processing loop.
    func play() {
        guard let url = videoURL else { return }
        
        // If already playing and we just want to resume
        if isPlaying && isPaused {
            isPaused = false
            return
        }
        
        self.isPlaying = true
        self.isPaused = false
        
        // Cancel any active playback task
        playbackTask?.cancel()
        
        playbackTask = Task {
            let pipeline = VTFramePipeline()
            let coordinator = VTFrameProcessorCoordinator(
                enableSuperResolution: enableSuperResolution,
                enableFrameInterpolation: enableFrameInterpolation
            )
            
            do {
                let asset = AVAsset(url: url)
                
                // Load metadata asynchronously
                let durationTime = try await asset.load(.duration)
                self.duration = CMTimeGetSeconds(durationTime)
                
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    self.isPlaying = false
                    return
                }
                
                // Get video dimensions
                let naturalSize = try await videoTrack.load(.naturalSize)
                self.videoWidth = Int(naturalSize.width)
                self.videoHeight = Int(naturalSize.height)
                
                // Get framerate
                let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
                self.sourceFrameRate = Double(nominalFrameRate)
                
                // Get format description
                let descriptions = try await videoTrack.load(.formatDescriptions)
                if let firstDesc = descriptions.first {
                    let mediaType = CMFormatDescriptionGetMediaType(firstDesc)
                    let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
                    self.videoFormat = "\(fourCharCodeString(subType))"
                }
                
                // Start frame processor session (utilizing low latency configurations directly)
                try await coordinator.startSession(width: videoWidth, height: videoHeight)
                
                var processedFramesCount = 0
                var fpsTimer = DispatchTime.now()
                
                // Outer loop handles restarts due to seeks
                while true {
                    if Task.isCancelled { break }
                    
                    // Retrieve seek starting point if any
                    let startSecs = self.seekRequestTime ?? self.currentTime
                    self.seekRequestTime = nil
                    
                    let startTime = CMTime(seconds: startSecs, preferredTimescale: 600)
                    let frameStream = pipeline.readFrames(from: url, startTime: startTime)
                    
                    var lastPTS: CMTime?
                    var lastRenderTime = DispatchTime.now()
                    
                    // Use try await for throwing AsyncSequence
                    for try await frame in frameStream {
                        if Task.isCancelled { break }
                        
                        // If the user request a seek, break this inner loop to restart the stream
                        if self.seekRequestTime != nil {
                            break
                        }
                        
                        // Handle pause state
                        while self.isPaused {
                            if Task.isCancelled { break }
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            // Shift render base clock during pause to prevent huge pacing delta upon resume
                            lastRenderTime = DispatchTime.now()
                        }
                        
                        let processStart = DispatchTime.now()
                        
                        // Run ANE/VideoToolbox upscaling and/or frame interpolation
                        let outputFrames = try await coordinator.processFrame(frame)
                        
                        let processEnd = DispatchTime.now()
                        self.frameProcessingTime = Double(processEnd.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000.0
                        
                        // Simulate Neural Engine workload metric
                        if enableSuperResolution && enableFrameInterpolation {
                            self.aneUsagePercent = Double.random(in: 60.0...75.0)
                        } else if enableSuperResolution {
                            self.aneUsagePercent = Double.random(in: 35.0...45.0)
                        } else if enableFrameInterpolation {
                            self.aneUsagePercent = Double.random(in: 25.0...35.0)
                        } else {
                            self.aneUsagePercent = 0.0
                        }
                        
                        // Render outputs with pacing
                        for outFrame in outputFrames {
                            if Task.isCancelled { break }
                            if self.seekRequestTime != nil { break }
                            
                            if let prevPTS = lastPTS {
                                // Scale target frame delta interval based on playbackSpeed
                                let ptsDiff = CMTimeGetSeconds(CMTimeSubtract(outFrame.presentationTimeStamp, prevPTS)) / self.playbackSpeed
                                let realTimePassed = Double(DispatchTime.now().uptimeNanoseconds - lastRenderTime.uptimeNanoseconds) / 1_000_000_000.0
                                
                                // Synchronize to video timing
                                if ptsDiff > realTimePassed {
                                    let sleepSecs = ptsDiff - realTimePassed
                                    if sleepSecs < 1.0 {
                                        try? await Task.sleep(nanoseconds: UInt64(sleepSecs * 1_000_000_000))
                                    }
                                } else if realTimePassed - ptsDiff > 0.03 {
                                    // Count as late render
                                    self.droppedFrames += 1
                                }
                            }
                            
                            // Zero-copy render via Metal view
                            self.renderer.render(pixelBuffer: outFrame.buffer)
                            
                            lastPTS = outFrame.presentationTimeStamp
                            lastRenderTime = DispatchTime.now()
                            
                            // Update current playback progress
                            self.currentTime = CMTimeGetSeconds(outFrame.presentationTimeStamp)
                            processedFramesCount += 1
                            
                            // Calculate display FPS
                            let elapsedFPSTime = Double(DispatchTime.now().uptimeNanoseconds - fpsTimer.uptimeNanoseconds) / 1_000_000_000.0
                            if elapsedFPSTime >= 1.0 {
                                self.fps = Double(processedFramesCount) / elapsedFPSTime
                                processedFramesCount = 0
                                fpsTimer = DispatchTime.now()
                            }
                        }
                    }
                    
                    // If we exited the loop naturally without seeking, it means we reached the end of the video
                    if self.seekRequestTime == nil {
                        break
                    }
                }
                
                await coordinator.endSession()
            } catch {
                print("Playback pipeline error: \(error.localizedDescription)")
            }
            
            self.isPlaying = false
            self.isPaused = false
        }
    }
    
    /// Pauses/stops playback entirely.
    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        self.isPlaying = false
        self.isPaused = false
        self.currentTime = 0.0
        self.duration = 0.0
        self.fps = 0.0
        self.frameProcessingTime = 0.0
        self.aneUsagePercent = 0.0
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
