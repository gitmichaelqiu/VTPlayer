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

#if os(macOS)
private struct MacNativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> MacNativeVideoPlayerView {
        MacNativeVideoPlayerView(player: player)
    }

    func updateNSView(_ nsView: MacNativeVideoPlayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

private final class MacNativeVideoPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#endif

/// The premium media player user interface view.
struct VTPlayerView: View {
    @State private var viewModel = VTPlayerViewModel()
    @State private var showFileImporter = false
    #if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showPhotoPicker = false
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
    @State private var selectedTab = 0

    @State private var videoToRename: URL? = nil
    @State private var renameText = ""
    @State private var showRenameAlert = false
    
    @State private var pinnedVideos: Set<String> = {
        let array = UserDefaults.standard.stringArray(forKey: "VTPinnedVideos") ?? []
        return Set(array)
    }()
    @State private var isPinnedExpanded = true
    @State private var isRecentsExpanded = true
    @State private var isSettingsExpanded = false
    @AppStorage("VTShowFileExtensions") private var showFileExtensions = true
    
    @AppStorage("VTDefaultSRLevel") private var defaultSRLevel = 0
    @AppStorage("VTDefaultQSRLevel") private var defaultQSRLevel = 0
    @AppStorage("VTDefaultFILevel") private var defaultFILevel = 0
    @AppStorage("VTDefaultMBLevel") private var defaultMBLevel = 0
    @AppStorage("VTDefaultDNLevel") private var defaultDNLevel = 0.0
    @AppStorage("VTDefaultSharpness") private var defaultSharpness = 0.0
    @AppStorage("VTDefaultHDRBoost") private var defaultHDRBoost = 0.0

    @State private var scrubTime: Double = 0.0
    @State private var isScrubbing: Bool = false

    // Hover state for control bar feature labels
    @State private var hoverSR = false
    @State private var hoverFI = false
    @State private var hoverMB = false
    @State private var hoverDN = false
    @State private var hoverSH = false
    @State private var hoverHDR = false

    private var globallySupportedQualityScales: Set<Int> {
        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
           VTSuperResolutionScalerConfiguration.isSupported {
            return Set(VTSuperResolutionScalerConfiguration.supportedScaleFactors.filter { $0 == 2 || $0 == 4 })
        }
        #endif
        return []
    }

    private var globallySupportedLowLatencySR: Bool {
        VTLowLatencySuperResolutionScalerConfiguration.isSupported
    }

    var body: some View {
        Group {
            #if os(iOS)
            iphoneLayout
            #else
            splitViewLayout
            #endif
        }
        .alert("Rename Video", isPresented: $showRenameAlert) {
            TextField("New Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let url = videoToRename {
                    renameVideoFile(url, to: renameText)
                }
            }
        } message: {
            Text("Enter a new name for the video file.")
        }
        #if os(macOS)
        .alert("Clear Playback History?", isPresented: $showClearAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear History", role: .destructive) {
                pinnedVideos.removeAll()
                UserDefaults.standard.set([], forKey: "VTPinnedVideos")
                viewModel.clearRecentVideosMac()
            }
        } message: {
            Text("This will clear your recent playback history. Your video files will remain safe.")
        }
        #endif
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                viewModel.openVideo(url)
            case .failure(let error):
                print("Failed to import file: \(error.localizedDescription)")
            }
        }
        #if canImport(PhotosUI)
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item = item else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: PhotosMovie.self) {
                    viewModel.openVideo(movie.url)
                }
            }
        }
        #endif
        #if os(iOS)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .videos,
            photoLibrary: .shared()
        )
        #endif
        .preferredColorScheme(viewModel.videoURL != nil ? .dark : nil)
        #if os(macOS)
        .onOpenURL { url in
            viewModel.openVideo(url)
        }
        #endif
    }

    @ViewBuilder
    private var splitViewLayout: some View {
        if !viewModel.isFullScreen {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                leftSidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 360)
                    .preferredColorScheme(viewModel.videoURL != nil ? .dark : nil)
            } detail: {
                videoContent
                    .frame(minWidth: 0, idealWidth: 720)
                    .inspector(isPresented: Binding(
                        get: { viewModel.showSidebar && viewModel.videoURL != nil },
                        set: { viewModel.showSidebar = $0 }
                    )) {
                        rightSidebar
                            .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
                            .preferredColorScheme(viewModel.videoURL != nil ? .dark : nil)
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button(action: { showFileImporter = true }) {
                                Label("Open Video", systemImage: "plus")
                            }
                            .help("Open a local video file")
                            
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
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: { showFileImporter = true }) {
                            Label("Open Video", systemImage: "plus")
                        }
                        .help("Open a local video file")
                        
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
        NavigationStack {
            iosHomeView
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
                VStack {
                    Spacer()
                    controlBar
                }
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

    private func renameVideoFile(_ url: URL, to newBaseName: String) {
        let ext = url.pathExtension
        let newName = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        let newFileName = newName + (ext.isEmpty ? "" : ".\(ext)")
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newFileName)
        
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            
            // Update recentVideos list
            if let idx = viewModel.recentVideos.firstIndex(of: url) {
                viewModel.recentVideos[idx] = newURL
                #if os(iOS)
                viewModel.saveRecentVideosIOS()
                #endif
            }
            
            // Move Date Added timestamp in UserDefaults
            let datesKey = "VTRecentVideosDates"
            var dates = UserDefaults.standard.dictionary(forKey: datesKey) as? [String: Double] ?? [:]
            if let dateVal = dates[url.lastPathComponent] {
                dates[newURL.lastPathComponent] = dateVal
                dates.removeValue(forKey: url.lastPathComponent)
                UserDefaults.standard.set(dates, forKey: datesKey)
            }
            
            // Move Pin state if pinned
            let pinnedKey = "VTPinnedVideos"
            var pinned = UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []
            if let pIdx = pinned.firstIndex(of: url.lastPathComponent) {
                pinned[pIdx] = newURL.lastPathComponent
                UserDefaults.standard.set(pinned, forKey: pinnedKey)
            }
            
            // Update UI set representation
            if pinnedVideos.contains(url.lastPathComponent) {
                pinnedVideos.remove(url.lastPathComponent)
                pinnedVideos.insert(newURL.lastPathComponent)
            }
            
            // Copy saved enhancement settings to the new lastPathComponent key
            let settingsKeys = [
                "VTLastSRLevel_", "VTLastFILevel_", "VTLastQSRLevel_",
                "VTLastMBLevel_", "VTLastDNLevel_", "VTLastSharpness_",
                "VTLastHDRBoost_", "VTLastPosition_"
            ]
            for keyPrefix in settingsKeys {
                let oldKey = keyPrefix + url.lastPathComponent
                let newKey = keyPrefix + newURL.lastPathComponent
                if let val = UserDefaults.standard.value(forKey: oldKey) {
                    UserDefaults.standard.set(val, forKey: newKey)
                    UserDefaults.standard.removeObject(forKey: oldKey)
                }
            }
            
            // Also update the specific dictionary key if it exists
            let oldDictKey = "VTVideoSettings_" + url.lastPathComponent
            let newDictKey = "VTVideoSettings_" + newURL.lastPathComponent
            if let dict = UserDefaults.standard.dictionary(forKey: oldDictKey) {
                UserDefaults.standard.set(dict, forKey: newDictKey)
                UserDefaults.standard.removeObject(forKey: oldDictKey)
            }
            
        } catch {
            print("Failed to rename file: \(error)")
        }
    }

    private func togglePin(for url: URL) {
        let filename = url.lastPathComponent
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            if pinnedVideos.contains(filename) {
                pinnedVideos.remove(filename)
            } else {
                pinnedVideos.insert(filename)
            }
        }
        UserDefaults.standard.set(Array(pinnedVideos), forKey: "VTPinnedVideos")
    }

}

// MARK: - Extracted SwiftUI Components
extension VTPlayerView {
    #if os(iOS)
    @ViewBuilder
    private var iosHomeView: some View {
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
    private var iosGalleryView: some View {
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
                        }
                    }
                    
                    return pinnedList.sorted(by: sortBlock) + unpinnedList.sorted(by: sortBlock)
                }()
                
                List {
                    let pinnedList = sortedVideos.filter { pinnedVideos.contains($0.lastPathComponent) }
                    let unpinnedList = sortedVideos.filter { !pinnedVideos.contains($0.lastPathComponent) }
                    
                    Section(isExpanded: $isPinnedExpanded) {
                        ForEach(pinnedList, id: \.self) { url in
                            videoRow(for: url)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    } header: {
                        if !pinnedList.isEmpty {
                            Text("Pinned")
                        }
                    }
                    
                    Section {
                        ForEach(unpinnedList, id: \.self) { url in
                            videoRow(for: url)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
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
    private func videoRow(for url: URL) -> some View {
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
                    
                    Text(formatDateAdded(for: url))
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
                togglePin(for: url)
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
            ShareLink(item: url, preview: SharePreview(url.lastPathComponent))
            
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
    private func modelStatusLabelView(_ status: VTModelManager.Status) -> some View {
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
                Picker("Super Resolution", selection: Binding(
                    get: {
                        defaultQSRLevel > 0 ? 10 + defaultQSRLevel : defaultSRLevel
                    },
                    set: { selection in
                        switch selection {
                        case 2, 4:
                            defaultSRLevel = selection
                            defaultQSRLevel = 0
                        case 12, 14:
                            defaultSRLevel = 0
                            defaultQSRLevel = selection - 10
                        default:
                            defaultSRLevel = 0
                            defaultQSRLevel = 0
                        }
                    }
                )) {
                    Text("Off").tag(0)
                    if globallySupportedLowLatencySR {
                        Text("Low Latency 2x").tag(2)
                        Text("Low Latency 4x").tag(4)
                    }
                    if globallySupportedQualityScales.contains(2) {
                        Text("Quality 2x").tag(12)
                    }
                    if globallySupportedQualityScales.contains(4) {
                        Text("Quality 4x").tag(14)
                    }
                }
                .pickerStyle(.menu)
                .tint(.secondary)
                
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
                        .frame(width: 24, alignment: .trailing)
                }
                
                HStack {
                    Text("Denoise Strength")
                    Spacer()
                    Slider(value: $defaultDNLevel, in: 0.0...1.0, step: 0.05)
                    .frame(width: 140)
                    Text(String(format: "%.2f", defaultDNLevel))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                
                HStack {
                    Text("Sharpness")
                    Spacer()
                    Slider(value: $defaultSharpness, in: 0.0...2.0, step: 0.1)
                    .frame(width: 140)
                    Text(String(format: "%.1f", defaultSharpness))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
                
                HStack {
                    Text("SDR-to-HDR Boost")
                    Spacer()
                    Slider(value: $defaultHDRBoost, in: 0.0...2.0, step: 0.1)
                    .frame(width: 140)
                    Text(String(format: "%.1f", defaultHDRBoost))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
            }
            
            // Quality SR Model Section
            Section("Quality Super Resolution Model") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Model Status")
                        Spacer()
                        modelStatusLabelView(viewModel.modelManager.status)
                    }
                    
                    if case .downloadRequired = viewModel.modelManager.status {
                        Button(action: {
                            viewModel.downloadGlobalModel()
                        }) {
                            Text("Download Quality SR Model")
                                .font(.body.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if case .failed(let errMsg) = viewModel.modelManager.status {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Error: \(errMsg)")
                                .font(.caption)
                                .foregroundStyle(.red)
                            
                            Button(action: {
                                viewModel.downloadGlobalModel()
                            }) {
                                Text("Retry Download")
                                    .font(.body.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if case .downloading(let progress) = viewModel.modelManager.status {
                        ProgressView(value: progress) {
                            Text(String(format: "Downloading (%.0f%%)", progress * 100))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .progressViewStyle(.linear)
                        .padding(.vertical, 4)
                    }
                }
            }
            
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
    #endif

    private func sortedMacRecentVideos() -> [URL] {
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
        }
    }

    @ViewBuilder
    private var leftSidebar: some View {
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
    private func macSidebarRow(for url: URL) -> some View {
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

    private var sortPicker: some View {
        Picker(selection: $sortBy) {
            Text("Date Added")
                .tag(SortOption.dateAdded)
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

    private var deleteHistoryButton: some View {
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
    private var rightSidebar: some View {
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
    private var mainVideoArea: some View {
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
                            .ignoresSafeArea(viewModel.isFullScreen ? .all : [])
                    } else {
                        #if os(macOS)
                        if let player = viewModel.player {
                            MacNativeVideoPlayer(player: player)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .cornerRadius(viewModel.isFullScreen ? 0 : 8)
                                .padding(.horizontal, viewModel.isFullScreen ? 0 : 16)
                                .padding(.top, viewModel.isFullScreen ? 0 : 16)
                                .padding(.bottom, viewModel.isFullScreen ? 0 : 90)
                                .ignoresSafeArea(viewModel.isFullScreen ? .all : [])
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
    private var controlBar: some View {
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
    private var playPauseButton: some View {
        Button(action: { viewModel.togglePlayPause() }) {
            Image(systemName: (viewModel.isPlaying && !viewModel.isPaused) ? "pause.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.glass)
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
    private var playbackSpeedControl: some View {
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
    private var fullscreenButton: some View {
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

/// Displays Quality SR model download status with live progress tracking.
/// Must be a separate struct to create a direct observation dependency on the
/// `@Observable VTModelManager`, avoiding nested-Observable tracking issues.
