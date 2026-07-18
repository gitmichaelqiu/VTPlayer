import SwiftUI
import AVKit
import AVFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif
#if os(macOS)
import AppKit
#endif
#if canImport(PhotosUI)
import PhotosUI
import UniformTypeIdentifiers
#endif

extension VTPlayerView {
    func sortedMacRecentVideos() -> [URL] {
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
        case .dateOpened:
            let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDatesMac") as? [String: Double] ?? [:]
            return viewModel.recentVideos.sorted { (dates[$0.path] ?? 0) > (dates[$1.path] ?? 0) }
        }
    }

    @ViewBuilder
    var leftSidebar: some View {
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
    func macSidebarRow(for url: URL) -> some View {
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

    var sortPicker: some View {
        Picker(selection: $sortBy) {
            Text("Date Added")
                .tag(SortOption.dateAdded)
            Text("Date Opened")
                .tag(SortOption.dateOpened)
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

    var deleteHistoryButton: some View {
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
    var rightSidebar: some View {
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
    var mainVideoArea: some View {
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
                            .ignoresSafeArea(viewModel.isFullScreen ? .all : SafeAreaRegions())
                    } else {
                        #if os(macOS)
                        if let player = viewModel.player {
                            MacNativeVideoPlayer(player: player)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .cornerRadius(viewModel.isFullScreen ? 0 : 8)
                                .padding(.horizontal, viewModel.isFullScreen ? 0 : 16)
                                .padding(.top, viewModel.isFullScreen ? 0 : 16)
                                .padding(.bottom, viewModel.isFullScreen ? 0 : 90)
                                .ignoresSafeArea(viewModel.isFullScreen ? .all : SafeAreaRegions())
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
    var controlBar: some View {
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
                    if viewModel.availableSuperResolutionScales.contains(2) {
                        Button("Low Latency 2x") {
                            viewModel.superResolutionLevel = 2
                            viewModel.qualitySuperResolutionScaleFactor = 0
                            viewModel.updateEnhancements()
                        }
                    }
                    if viewModel.availableSuperResolutionScales.contains(4) {
                        Button("Low Latency 4x") {
                            viewModel.superResolutionLevel = 4
                            viewModel.qualitySuperResolutionScaleFactor = 0
                            viewModel.updateEnhancements()
                        }
                    }
                    Divider()
                    if viewModel.availableQualitySuperResolutionScales.contains(2) {
                        Button("Quality 2x") {
                            viewModel.superResolutionLevel = 0
                            viewModel.qualitySuperResolutionScaleFactor = 2
                            viewModel.updateEnhancements()
                        }
                    }
                    if viewModel.availableQualitySuperResolutionScales.contains(4) {
                        Button("Quality 4x") {
                            viewModel.superResolutionLevel = 0
                            viewModel.qualitySuperResolutionScaleFactor = 4
                            viewModel.updateEnhancements()
                        }
                    }
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
                .tint(.secondary)
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
    var playPauseButton: some View {
        Button(action: { viewModel.togglePlayPause() }) {
            Image(systemName: (viewModel.isPlaying && !viewModel.isPaused) ? "pause.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.glass)
        .keyboardShortcut(.space, modifiers: [])
    }
    
    @ViewBuilder
    var sharpnessControl: some View {
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
    var playbackSpeedControl: some View {
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
    var fullscreenButton: some View {
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
