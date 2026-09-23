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
                        Text("Pinned")
                    }
                }

                Section(isExpanded: $isRecentsExpanded) {
                    if !unpinnedList.isEmpty {
                        ForEach(unpinnedList, id: \.self) { url in
                            macSidebarRow(for: url)
                        }
                    }
                } header: {
                    Text("Videos")
                }
            }
            .listStyle(.sidebar)
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

    func macSidebarRow(for url: URL) -> some View {
        let isPinned = pinnedVideos.contains(url.lastPathComponent)
        let isActive = (url == viewModel.videoURL)
        return Button(action: {
            viewModel.openRecentVideo(url)
        }) {
            HStack(spacing: 10) {
                VideoThumbnailView(url: url, width: 72, height: 42)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.displayName(for: url, showingExtension: showFileExtensions))
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
            .padding(.horizontal, 4)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
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
                renameText = viewModel.displayName(for: url, showingExtension: false)
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
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Clear playback history")
        .disabled(viewModel.recentVideos.isEmpty)
    }
    
    @ViewBuilder
    var rightSidebar: some View {
        Form {
            if viewModel.isPipelineActive {
                Section("Real-Time Metrics") {
                    LabeledContent("Playback State") {
                        Text(viewModel.playbackPhase.label)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Applied Enhancements", value: viewModel.appliedEnhancementSummary)
                    LabeledContent("Processing Mode", value: viewModel.enhancedProcessingModeSummary)
                    LabeledContent("Frame Processing") {
                        Text(String(format: "%.1f ms", viewModel.frameProcessingTime))
                            .monospacedDigit()
                            .help("Latest observed enhancement-processing time. Full-cache playback reuses saved frames instead of processing each frame live.")
                    }
                    LabeledContent("Submitted Rate") {
                        Text(String(format: "%.1f Hz", viewModel.fps))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Presented Rate") {
                        Text(String(format: "%.1f Hz", viewModel.actualPresentedFrameRate))
                            .monospacedDigit()
                            .foregroundStyle(viewModel.actualPresentedFrameRate >= viewModel.displayTargetFrameRate * 0.97 ? .blue : .red)
                    }
                    LabeledContent("Presented 1% Low") {
                        Text(String(format: "%.1f Hz", viewModel.actualPresented1PercentLow))
                            .monospacedDigit()
                            .foregroundStyle(viewModel.actualPresented1PercentLow >= viewModel.displayTargetFrameRate * 0.97 ? .blue : .red)
                    }
                    LabeledContent("Display Target") {
                        Text(String(format: "%.1f Hz", viewModel.displayTargetFrameRate))
                            .monospacedDigit()
                    }
                    LabeledContent("Rendered Timeline") {
                        if viewModel.renderedTimelineSampleDuration > 0 {
                            Text(String(
                                format: "%.0f%%",
                                viewModel.renderedTimelineRatio * 100
                            ))
                            .monospacedDigit()
                            .foregroundStyle(
                                (0.98...1.02).contains(viewModel.renderedTimelineRatio) ? .blue : .red
                            )
                        } else {
                            Text("Measuring…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Buffered Frames") {
                        Text("\(viewModel.presentationQueueFrameCount)")
                            .monospacedDigit()
                            .foregroundStyle(viewModel.presentationQueueFrameCount > 10 ? .blue : .secondary)
                    }
                }
            }
            
            Section("Video Metadata") {
                LabeledContent("Resolution", value: "\(viewModel.videoWidth)×\(viewModel.videoHeight)")
                LabeledContent("Source Rate") {
                    Text(String(format: "%.2f fps", viewModel.sourceFrameRate))
                        .monospacedDigit()
                }
                LabeledContent("Generated Rate") {
                    let scale = viewModel.appliedPipelineConfiguration.frameInterpolationLevel > 0
                        ? Double(viewModel.appliedPipelineConfiguration.frameInterpolationLevel)
                        : 1.0
                    let rate = viewModel.sourceFrameRate * scale
                    Text(String(format: "%.2f fps", rate))
                        .monospacedDigit()
                }
                LabeledContent("Video Codec", value: viewModel.videoFormat)
            }
            
            Section("Super Resolution Specs") {
                LabeledContent("SR Supported", value: String(localized: viewModel.srIsSupported ? "Yes" : "No"))
                    .foregroundStyle(viewModel.srIsSupported ? .blue : .secondary)
                
                LabeledContent(
                    "Scales",
                    value: viewModel.srSupportedScales == "None"
                        ? String(localized: "None")
                        : viewModel.srSupportedScales
                )
                LabeledContent("Quality Scales") {
                    let qualityScales = viewModel.availableQualitySuperResolutionScales
                        .sorted()
                        .map { "\($0)x" }
                        .joined(separator: ", ")
                    Text(qualityScales.isEmpty ? String(localized: "None") : qualityScales)
                        .monospacedDigit()
                }
                
                let isQL = viewModel.qualitySuperResolutionScaleFactor > 0
                let scale = max(viewModel.superResolutionLevel, Float(viewModel.qualitySuperResolutionScaleFactor))
                let scaleLabel = scale.rounded() == scale
                    ? String(Int(scale))
                    : String(format: "%.1f", scale)
                let modeFormat = isQL
                    ? String(localized: "Quality %@")
                    : String(localized: "Low Latency %@")
                LabeledContent(
                    "Active State",
                    value: scale > 0
                        ? String(format: modeFormat, "\(scaleLabel)x")
                        : String(localized: "Off")
                )
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
                        #if os(macOS)
                        if !viewModel.pipelinePresentationReady,
                           let player = viewModel.player {
                            MacNativeVideoPlayer(player: player)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .cornerRadius(viewModel.isFullScreen ? 0 : 8)
                                .padding(.horizontal, viewModel.isFullScreen ? 0 : 16)
                                .padding(.top, viewModel.isFullScreen ? 0 : 16)
                                .padding(.bottom, viewModel.isFullScreen ? 0 : 90)
                                .ignoresSafeArea(viewModel.isFullScreen ? .all : SafeAreaRegions())
                        }
                        #endif

                        VTMetalRendererView(renderer: viewModel.renderer)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .cornerRadius(viewModel.isFullScreen ? 0 : 8)
                            .padding(.horizontal, viewModel.isFullScreen ? 0 : 16)
                            .padding(.top, viewModel.isFullScreen ? 0 : 16)
                            .padding(.bottom, viewModel.isFullScreen ? 0 : 90)
                            // Keep MTKView attached so its display scheduler
                            // can drain the first processed frame; opacity
                            // lets AVPlayer remain visible during handoff.
                            .opacity(viewModel.pipelinePresentationReady ? 1 : 0)
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
                        Text("Open a video to enhance.")
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
    
}
