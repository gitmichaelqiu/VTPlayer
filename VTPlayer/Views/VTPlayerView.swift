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
struct MacNativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> MacNativeVideoPlayerView {
        MacNativeVideoPlayerView(player: player)
    }

    func updateNSView(_ nsView: MacNativeVideoPlayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class MacNativeVideoPlayerView: NSView {
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
    @State var viewModel = VTPlayerViewModel()
    @State var showFileImporter = false
    #if canImport(PhotosUI)
    @State var selectedPhotoItem: PhotosPickerItem? = nil
    @State var showPhotoPicker = false
    #endif
    @State var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State var showSettingsSheet = false
    @State var showDiagnosticsSheet = false
    @State var showClearAllAlert = false
    @State var showDenoisePopover = false
    @State var showPlaybackSpeedPopover = false
    @Environment(\.dismiss) var dismiss
    
    enum SortOption: String, CaseIterable, Identifiable {
        case dateAdded = "Date Added"
        case dateOpened = "Date Opened"
        case name = "Name"
        var id: Self { self }
    }
    @State var sortBy: SortOption = .dateAdded
    @State var selectedTab = 0

    @State var videoToRename: URL? = nil
    @State var renameText = ""
    @State var showRenameAlert = false
    
    @State var pinnedVideos: Set<String> = {
        let array = UserDefaults.standard.stringArray(forKey: "VTPinnedVideos") ?? []
        return Set(array)
    }()
    @State var isPinnedExpanded = true
    @State var isRecentsExpanded = true
    @State var isSettingsExpanded = false
    @AppStorage("VTShowFileExtensions") var showFileExtensions = true
    
    @AppStorage("VTDefaultSRLevel") var defaultSRLevel = 0
    @AppStorage("VTDefaultQSRLevel") var defaultQSRLevel = 0
    @AppStorage("VTDefaultFILevel") var defaultFILevel = 0
    @AppStorage("VTDefaultMBLevel") var defaultMBLevel = 0
    @AppStorage("VTDefaultDNLevel") var defaultDNLevel = 0.0
    @AppStorage("VTDefaultSharpness") var defaultSharpness = 0.0
    @AppStorage("VTDefaultHDRBoost") var defaultHDRBoost = 0.0
    @AppStorage("VTDefaultHDRColorfulness") var defaultHDRColorfulness = 0.0

    @State var scrubTime: Double = 0.0
    @State var isScrubbing: Bool = false

    // Hover state for control bar feature labels
    @State var hoverSR = false
    @State var hoverFI = false
    @State var hoverMB = false
    @State var hoverDN = false
    @State var hoverSH = false
    @State var hoverHDR = false

    var globallySupportedQualityScales: Set<Int> {
        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
           VTSuperResolutionScalerConfiguration.isSupported {
            return Set(VTSuperResolutionScalerConfiguration.supportedScaleFactors.filter { $0 == 2 || $0 == 4 })
        }
        #endif
        return []
    }

    var globallySupportedLowLatencySR: Bool {
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
    var splitViewLayout: some View {
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
    var iphoneLayout: some View {
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
    var videoContent: some View {
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

    func formatTime(_ seconds: Double) -> String {
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

    func formatDateAdded(for url: URL) -> String {
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

    func renameVideoFile(_ url: URL, to newBaseName: String) {
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
            let openedKey = "VTRecentVideosOpenedDates"
            var openedDates = UserDefaults.standard.dictionary(forKey: openedKey) as? [String: Double] ?? [:]
            if let dateVal = openedDates[url.lastPathComponent] {
                openedDates[newURL.lastPathComponent] = dateVal
                openedDates.removeValue(forKey: url.lastPathComponent)
                UserDefaults.standard.set(openedDates, forKey: openedKey)
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
                "VTLastHDRBoost_", "VTLastHDRColorfulness_", "VTLastPosition_"
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

    func togglePin(for url: URL) {
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
