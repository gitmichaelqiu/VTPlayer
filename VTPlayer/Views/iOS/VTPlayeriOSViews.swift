import SwiftUI
import AVKit
import AVFoundation

private struct AnimatedIOSSettingValue: View {
    let text: String
    @State private var displayedText: String

    init(text: String) {
        self.text = text
        _displayedText = State(initialValue: text)
    }

    var body: some View {
        Text(displayedText)
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: true, vertical: false)
            .contentTransition(.numericText())
            .onChange(of: text) { _, newText in
                withAnimation(.snappy(duration: 0.18)) {
                    displayedText = newText
                }
            }
    }
}

private struct IOSSliderSettingRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    let valueText: (Double) -> String
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button {
                    resetTask?.cancel()
                    let start = value
                    let end = defaultValue
                    resetTask = Task { @MainActor in
                        let steps = 40
                        let startTime = DispatchTime.now().uptimeNanoseconds
                        let duration: UInt64 = 150_000_000
                        for step in 1...steps {
                            guard !Task.isCancelled else { return }
                            let targetTime = startTime + duration * UInt64(step) / UInt64(steps)
                            let currentTime = DispatchTime.now().uptimeNanoseconds
                            if targetTime > currentTime {
                                try? await Task.sleep(nanoseconds: targetTime - currentTime)
                            }
                            guard !Task.isCancelled else { return }
                            let linearProgress = Double(step) / Double(steps)
                            let progress = 1 - (1 - linearProgress) * (1 - linearProgress) * (1 - linearProgress)
                            value = start + (end - start) * progress
                        }
                        resetTask = nil
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(abs(value - defaultValue) < 0.001)
                .accessibilityLabel("Reset to default")
            }

            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                AnimatedIOSSettingValue(text: valueText(value))
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}
#if os(iOS)
private struct IOSMoreApp: Identifiable {
    let id: String
    let name: String
    let description: LocalizedStringKey
    let url: URL
    let iconName: String
}

private struct IOSMoreAppsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    private let primaryTextColor = Color(uiColor: .label)
    private let secondaryTextColor = Color(uiColor: .secondaryLabel)
    private let tertiaryTextColor = Color(uiColor: .tertiaryLabel)

    private let apps = [
        IOSMoreApp(id: "desktoprenamer", name: "DesktopRenamer", description: "Rename and organize your desktop spaces.", url: URL(string: "https://desktoprenamer.mqiu.dev")!, iconName: "DesktopRenamerIcon_Default"),
        IOSMoreApp(id: "optclicker", name: "OptClicker", description: "Right-click with the Option key.", url: URL(string: "https://optclicker.mqiu.dev")!, iconName: "OptClickerIcon_Default"),
        IOSMoreApp(id: "spaceswitcher", name: "SpaceSwitcher", description: "Control apps and docks across spaces.", url: URL(string: "https://spaceswitcher.mqiu.dev")!, iconName: "SpaceSwitcherIcon_Default")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("More apps for Apple platforms")
                        .font(.subheadline)
                        .foregroundStyle(secondaryTextColor)

                    ForEach(apps) { app in
                        Button {
                            openURL(app.url)
                        } label: {
                            HStack(spacing: 14) {
                                appIcon(for: app)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name)
                                        .font(.headline)
                                        .foregroundStyle(primaryTextColor)
                                    Text(app.description)
                                        .font(.subheadline)
                                        .foregroundStyle(secondaryTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(tertiaryTextColor)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(primaryTextColor)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .scrollIndicators(.hidden)
            .navigationTitle("More apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func appIcon(for app: IOSMoreApp) -> some View {
        let iconName = colorScheme == .dark
            ? app.iconName.replacingOccurrences(of: "_Default", with: "_Dark")
            : app.iconName
        if let image = UIImage(named: iconName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
}

private struct IOSAcknowledgementSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = Bundle.main.url(forResource: "Acknowledgement", withExtension: "pdf") {
                    IOSPDFView(url: url)
                } else {
                    ContentUnavailableView("Acknowledgement Unavailable", systemImage: "doc.badge.ellipsis")
                }
            }
            .navigationTitle("Acknowledgements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct IOSPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGroupedBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
#endif

import VideoToolbox
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif
#if os(iOS)
import PDFKit
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
            NavigationStack {
                ZStack {
                    iosGalleryView
                }
                .navigationTitle("Gallery")
                .navigationBarTitleDisplayMode(.large)
                    .navigationDestination(isPresented: $isPlayerPresented) {
                        iosPlayerView
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            if !viewModel.recentVideos.isEmpty {
                                Button(action: { showClearAllAlert = true }) {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }

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
                .tag(0)
                .tabItem {
                    Label("Gallery", systemImage: "play.square.stack.fill")
                }

            NavigationStack {
                iosAboutView
                    .navigationTitle("About")
            }
                .tag(1)
                .tabItem {
                    Label("About", systemImage: "info.circle.fill")
                }
        }
        .toolbar(isPlayerTabBarHidden ? .hidden : .visible, for: .tabBar)
        .onChange(of: viewModel.videoURL) { _, url in
            if url != nil {
                isPlayerNavigationReady = false
                isPlayerPresented = true
            } else {
                isPlayerNavigationReady = false
                isPlayerPresented = false
            }
        }
        .onChange(of: isPlayerPresented) { _, presented in
            guard !presented, viewModel.videoURL != nil else { return }

            // Dismiss through the navigation destination's state first. The
            // URL is playback state, not the presentation mechanism.
            withAnimation(.easeInOut(duration: 0.25)) {
                isPlayerTabBarHidden = false
            }
            viewModel.stop()
            viewModel.videoURL = nil
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
                    if !pinnedList.isEmpty {
                        Section(isExpanded: $isPinnedExpanded) {
                            ForEach(pinnedList, id: \.self) { url in
                                videoRow(for: url)
                                    .id("\(url.path)-pinned")
                            }
                        } header: {
                            Text("Pinned")
                        }
                    }
                    
                    Section(isExpanded: $isRecentsExpanded) {
                        ForEach(unpinnedList, id: \.self) { url in
                            videoRow(for: url)
                                .id("\(url.path)-unpinned")
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
                pinnedVideos.removeAll()
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
                    Text(viewModel.displayName(for: url, showingExtension: showFileExtensions))
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
            .contentShape(Rectangle())
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
            Button {
                togglePin(for: url)
            } label: {
                let isPinned = pinnedVideos.contains(url.lastPathComponent)
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
            let percent = progress.formatted(.percent.precision(.fractionLength(0)))
            Text(String(localized: "Downloading %@", defaultValue: "Downloading \(percent)", comment: "Model download progress"))
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
                DisclosureGroup(isExpanded: $isAboutCardExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider()

                        Text("Made by Michael Qiu.")
                            .font(.subheadline.weight(.medium))

                        Text("A real-time video enhancer using hardware acceleration.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            aboutLinkRow(title: "Report an issue", systemImage: "exclamationmark.bubble", url: "https://github.com/gitmichaelqiu/VTPlayer/issues")
                            aboutLinkRow(title: "VTPlayer's GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/gitmichaelqiu/VTPlayer")
                            aboutLinkRow(title: "Author's website", systemImage: "globe", url: "https://mqiu.dev")
                            aboutLinkRow(title: "Author's GitHub", systemImage: "person.crop.circle", url: "https://github.com/gitmichaelqiu")
                            aboutActionRow(title: "Acknowledgement", systemImage: "doc.text") {
                                showAcknowledgementSheet = true
                            }

                            Button {
                                showMoreAppsSheet = true
                            } label: {
                                Text("Explore more apps")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, -20)
                    .padding(.top, -15)
                } label: {
                    HStack(alignment: .center, spacing: 16) {
                        aboutAppIcon

                        VStack(alignment: .leading, spacing: 4) {
                            Text("VTPlayer")
                                .font(.headline)
                                .bold()
                            Text("Sharper. Smoother. Better.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(appVersionLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                    .frame(minHeight: 60, alignment: .center)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            
            // Default Playback Settings Section
            Section("Defaults") {
                Toggle("Continue video playback", isOn: $defaultContinueVideoPlayback)

                IOSSliderSettingRow(
                    title: "Frame cache",
                    value: Binding(
                        get: { Double(min(max(enhancedFrameCacheMemoryMB, 128), 1_024)) },
                        set: { enhancedFrameCacheMemoryMB = Int($0.rounded()) }
                    ),
                    range: 128...1_024,
                    step: 128,
                    defaultValue: 256,
                    valueText: { $0 >= 1_024 ? "1 GB" : "\(Int($0)) MB" }
                )
            }

            Section {
                IOSSliderSettingRow(
                    title: "Motion Blur",
                    value: Binding(
                        get: { Double(defaultMBLevel) },
                        set: { defaultMBLevel = Int($0.rounded()) }
                    ),
                    range: 0...100,
                    step: 5,
                    defaultValue: 0,
                    valueText: { $0 == 0 ? String(localized: "Off") : "\(Int($0))" }
                )

                IOSSliderSettingRow(
                    title: "Denoise",
                    value: $defaultDNLevel,
                    range: 0.0...1.0,
                    step: 0.05,
                    defaultValue: 0,
                    valueText: { String(format: "%.2f", $0) }
                )

                IOSSliderSettingRow(
                    title: "Sharpness",
                    value: $defaultSharpness,
                    range: 0.0...2.0,
                    step: 0.05,
                    defaultValue: 0,
                    valueText: { String(format: "%.2f", $0) }
                )

                IOSSliderSettingRow(
                    title: "HDR Boost",
                    value: Binding(
                        get: { defaultHDRBoost },
                        set: { newValue in
                            let wasEnabled = defaultHDRBoost > 0
                            let isEnabled = newValue > 0
                            if wasEnabled != isEnabled {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    defaultHDRBoost = newValue
                                }
                            } else {
                                defaultHDRBoost = newValue
                            }
                        }
                    ),
                    range: 0.0...2.0,
                    step: 0.05,
                    defaultValue: 0,
                    valueText: { String(format: "%.2f", $0) }
                )

            if defaultHDRBoost > 0 {
                IOSSliderSettingRow(
                    title: "HDR Colorfulness",
                    value: $defaultHDRColorfulness,
                    range: 0.0...1.0,
                    step: 0.05,
                    defaultValue: 0,
                    valueText: { String(format: "%.2f", $0) }
                )
                .transition(.opacity)
            }
            }
            .animation(.easeInOut(duration: 0.2), value: defaultHDRBoost)
            
            // Gallery Configuration Section
            Section("Display") {
                Toggle("Always use dark mode when playing", isOn: $alwaysDarkOnPlayback)
                Toggle("Show file extensions", isOn: $showFileExtensions)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.custom(16))
        .sheet(isPresented: $showMoreAppsSheet) {
            IOSMoreAppsSheet()
        }
        .sheet(isPresented: $showAcknowledgementSheet) {
            IOSAcknowledgementSheet()
        }
        .onAppear {
            viewModel.checkGlobalModelStatus()
        }
    }

    @ViewBuilder
    private var aboutAppIcon: some View {
        let icon = colorScheme == .dark
            ? UIImage(named: "VTPlayerIcon_Dark").map(Image.init(uiImage:))
            : viewModel.appIcon
        if let icon {
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
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? String(localized: "Unknown")
        return String(format: String(localized: "Version %@"), version)
    }

    @ViewBuilder
    private func aboutLinkRow(title: LocalizedStringKey, systemImage: String, url: String) -> some View {
        Button {
            openExternalURL(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)

                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func aboutActionRow(title: LocalizedStringKey, systemImage: String, verticalPadding: CGFloat = 8, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)

                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.vertical, verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openExternalURL(_ string: String) {
        guard let url = URL(string: string), UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
    #endif

}
