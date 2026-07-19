import SwiftUI
import AVKit
import AVFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif
#if canImport(PhotosUI)
import PhotosUI
import UniformTypeIdentifiers
#endif

// MARK: - Extracted SwiftUI Components
extension VTPlayerView {
    #if os(iOS)
    @ViewBuilder
    var iosHomeView: some View {
        TabView(selection: $selectedTab) {
            iosGalleryView
                .tag(0)
                .tabItem {
                    Label("Gallery", systemImage: "play.square.stack.fill")
                }

            iosAboutView
                .tag(1)
                .tabItem {
                    Label("About", systemImage: "info.circle.fill")
                }
        }
        .navigationTitle(selectedTab == 0 ? "Gallery" : "About")
        .toolbar {
            if selectedTab == 0 {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Clear all button (only shown/enabled when list is not empty)
                    if !viewModel.recentVideos.isEmpty {
                        Button(action: { showClearAllAlert = true }) {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        
                        // Sort option menu
                        Menu {
                            Picker("Sort By", selection: Binding(
                                get: { sortBy },
                                set: { newValue in
                                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                        sortBy = newValue
                                    }
                                }
                            )) {
                                Label("Date Added", systemImage: "calendar").tag(SortOption.dateAdded)
                                Label("Date Opened", systemImage: "clock.arrow.circlepath").tag(SortOption.dateOpened)
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
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Photos Library", systemImage: "photo")
                        }
                        #endif
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.bold())
                    }
                }
            }
        }
    }

    @ViewBuilder
    var iosGalleryView: some View {
        Group {
            if viewModel.recentVideos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("No Videos")
                        .font(.headline)
                    Text("Tap the + button to add video files.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            } else {
                let sortedVideos: [URL] = {
                    let pinnedList = viewModel.recentVideos.filter { pinnedVideos.contains($0.lastPathComponent) }
                    let unpinnedList = viewModel.recentVideos.filter { !pinnedVideos.contains($0.lastPathComponent) }
                    
                    let sortBlock: (URL, URL) -> Bool = { u1, u2 in
                        switch sortBy {
                        case .name:
                            return u1.lastPathComponent.localizedStandardCompare(u2.lastPathComponent) == .orderedAscending
                        case .dateAdded:
                            let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDates") as? [String: Double] ?? [:]
                            let t1 = dates[u1.lastPathComponent] ?? 0
                            let t2 = dates[u2.lastPathComponent] ?? 0
                            return t1 > t2
                        case .dateOpened:
                            let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDates") as? [String: Double] ?? [:]
                            return (dates[u1.lastPathComponent] ?? 0) > (dates[u2.lastPathComponent] ?? 0)
                        }
                    }
                    
                    return pinnedList.sorted(by: sortBlock) + unpinnedList.sorted(by: sortBlock)
                }()
                
                let pinnedList = sortedVideos.filter { pinnedVideos.contains($0.lastPathComponent) }
                let unpinnedList = sortedVideos.filter { !pinnedVideos.contains($0.lastPathComponent) }
                
                List {
                    Section(isExpanded: $isPinnedExpanded) {
                        ForEach(pinnedList, id: \.self) { url in
                            videoRow(for: url)
                        }
                    } header: {
                        if !pinnedList.isEmpty {
                            Text("Pinned")
                        }
                    }
                    
                    Section {
                        ForEach(unpinnedList, id: \.self) { url in
                            videoRow(for: url)
                        }
                    } header: {
                        if !pinnedList.isEmpty {
                            Text("Videos")
                        }
                    }
                }
                .listStyle(.insetGrouped)
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
    func videoRow(for url: URL) -> some View {
        Button(action: {
            viewModel.openVideo(url)
        }) {
            HStack(spacing: 12) {
                VideoThumbnailView(url: url)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(showFileExtensions ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    
                    Text(sortBy == .dateOpened ? formatDateOpened(for: url) : formatDateAdded(for: url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    togglePin(for: url)
                }
            } label: {
                Label(pinnedVideos.contains(url.lastPathComponent) ? "Unpin" : "Pin", 
                      systemImage: pinnedVideos.contains(url.lastPathComponent) ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.orange)
        }
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
            Button {
                togglePin(for: url)
            } label: {
                let isPinned = pinnedVideos.contains(url.lastPathComponent)
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
                UIPasteboard.general.string = url.lastPathComponent
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }
            
            ShareLink(item: url, preview: SharePreview(url.lastPathComponent))
            
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

    @ViewBuilder
    func modelStatusLabelView(_ status: VTModelManager.Status) -> some View {
        switch status {
        case .notChecked:
            Text("Checking...")
                .foregroundStyle(.secondary)
        case .ready:
            Text("Ready")
                .foregroundStyle(.green)
                .bold()
        case .downloadRequired:
            Text("Download Required")
                .foregroundStyle(.orange)
        case .downloading(let progress):
            Text(String(format: "Downloading (%.0f%%)", progress * 100))
                .foregroundStyle(.blue)
        case .failed:
            Text("Failed")
                .foregroundStyle(.red)
        }
    }

    var iosAboutView: some View {
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
                            .foregroundStyle(.blue)
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
                            .foregroundStyle(.secondary)
                        Text("Version 1.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            // Default Playback Settings Section
            Section("Default Playback Configuration") {
                Picker("Frame Interpolation", selection: $defaultFILevel) {
                    Text("Off").tag(0)
                    Text("2x Interpolation").tag(2)
                    Text("4x Interpolation").tag(4)
                }
                .tint(.secondary)
                
                HStack {
                    Text("Motion Blur")
                    Spacer()
                    Slider(value: Binding(
                        get: { Double(defaultMBLevel) },
                        set: { defaultMBLevel = Int($0) }
                    ), in: 0...30, step: 1)
                    .frame(width: 140)
                    Text(defaultMBLevel == 0 ? "Off" : "\(defaultMBLevel)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                
                HStack {
                    Text("Denoise")
                    Spacer()
                    Slider(value: $defaultDNLevel, in: 0.0...1.0, step: 0.05)
                    .frame(width: 140)
                    Text(String(format: "%.2f", defaultDNLevel))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                
                HStack {
                    Text("Sharpness")
                    Spacer()
                    Slider(value: $defaultSharpness, in: 0.0...2.0, step: 0.1)
                    .frame(width: 140)
                    Text(String(format: "%.1f", defaultSharpness))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                
                HStack {
                    Text("HDR Boost")
                    Spacer()
                    Slider(value: Binding(
                        get: { defaultHDRBoost },
                        set: { newValue in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                defaultHDRBoost = newValue
                            }
                        }
                    ), in: 0.0...2.0, step: 0.1)
                    .frame(width: 140)
                    Text(String(format: "%.1f", defaultHDRBoost))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }

                if defaultHDRBoost > 0 {
                    HStack {
                        Text("HDR Colorfulness")
                        Spacer()
                        Slider(value: $defaultHDRColorfulness, in: 0.0...1.0, step: 0.05)
                        .frame(width: 140)
                        Text(String(format: "%.2f", defaultHDRColorfulness))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: defaultHDRBoost)
            
            // Gallery Configuration Section
            Section("Gallery Configuration") {
                Toggle("Show File Extensions", isOn: $showFileExtensions)
            }

            // Copyright Row
            Section {
                HStack {
                    Spacer()
                    Text("Copyright © 2026 Michael Qiu. All rights reserved.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("About")
        .onAppear {
            viewModel.checkGlobalModelStatus()
        }
    }
    #endif

    #if os(iOS)
    @ViewBuilder
    var iosPlayerView: some View {
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
    var iosDiagnosticsSheet: some View {
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
                                .foregroundStyle(.red)
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

    func formatDateOpened(for url: URL) -> String {
        let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDates") as? [String: Double] ?? [:]
        guard let timeInterval = dates[url.lastPathComponent] else {
            return "Opened recently"
        }
        let date = Date(timeIntervalSince1970: timeInterval)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Opened " + formatter.string(from: date)
    }
    #endif

}
