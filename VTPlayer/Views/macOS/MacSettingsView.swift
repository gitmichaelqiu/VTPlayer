#if os(macOS)
import SwiftUI
import Combine
import AppKit

struct MacSettingsView: View {
    @StateObject private var navigationState = SettingsNavigationState()
    @State private var selectedTab: SettingsTab?
    @State private var searchText = ""

    init(initialTab: SettingsTab? = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                sidebar
            } detail: {
                detailView
            }

            // Pre-render settings views off-screen in the active root hierarchy to index them
            ZStack {
                GeneralSettingsTab()
                    .environment(\.settingsTab, .general)
                EnhancementsSettingsTab()
                    .environment(\.settingsTab, .enhancements)
                AboutSettingsTab()
                    .environment(\.settingsTab, .about)
            }
            .environmentObject(navigationState)
            .environment(\.isSettingsPreRendering, true)
            .frame(width: CGFloat(defaultSettingsWindowWidth), height: CGFloat(defaultSettingsWindowHeight))
            .opacity(0.001)
            .allowsHitTesting(false)
        }
        .environmentObject(navigationState)
        .navigationTitle("")
        .edgesIgnoringSafeArea(.top)
        .frame(
            width: CGFloat(defaultSettingsWindowWidth), height: CGFloat(defaultSettingsWindowHeight)
        )
        .onChange(of: searchText) { _, newValue in
            navigationState.searchText = newValue
            if !newValue.isEmpty {
                let tabs = filteredTabs
                if let selected = selectedTab, !tabs.contains(selected) {
                    selectedTab = tabs.first
                } else if selectedTab == nil {
                    selectedTab = tabs.first
                }
            }
        }
    }

    var filteredTabs: [SettingsTab] {
        if searchText.isEmpty {
            return SettingsTab.allCases
        }
        let query = searchText.lowercased()
        return SettingsTab.allCases.filter { tab in
            let matchesTabName = tab.rawValue.lowercased().contains(query) ||
                                 String(localized: tab.localizedName).lowercased().contains(query)
            
            let matchesSetting = navigationState.registeredItems.contains { item in
                item.tab == tab && (
                    item.title.lowercased().contains(query) ||
                    item.localizedTitle.lowercased().contains(query) ||
                    item.keywords.contains { $0.lowercased().contains(query) }
                )
            }
            
            return matchesTabName || matchesSetting
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 13))
            
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.primary)
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )
        )
        .padding(.leading, -4)
        .padding(.trailing, 10)
    }

    @ViewBuilder
    private func sidebarContent(titleSize: CGFloat, spacing: CGFloat) -> some View {
        Section {
            if filteredTabs.isEmpty {
                Text("No results")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
                    .padding(.top, 4)
            } else {
                ForEach(filteredTabs) { tab in
                    VStack(alignment: .leading, spacing: 2) {
                        sidebarItem(for: tab)
                        
                        if !searchText.isEmpty {
                            let matchingItems = navigationState.registeredItems.filter { item in
                                item.tab == tab && (
                                    item.title.lowercased().contains(searchText.lowercased()) ||
                                    item.localizedTitle.lowercased().contains(searchText.lowercased()) ||
                                    item.keywords.contains { $0.lowercased().contains(searchText.lowercased()) }
                                )
                            }
                            
                            ForEach(matchingItems) { item in
                                Button {
                                    selectedTab = tab
                                    navigationState.scrollToItemID = item.title
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                            .padding(.leading, 12)
                                        
                                        Text(highlightedText(text: item.localizedTitle, query: searchText, color: nil))
                                            .font(.system(size: 11, weight: .regular))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(height: 18)
                            }
                        }
                    }
                    .tag(tab)
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: spacing) {
                Color.clear.frame(height: 45)
                Text("VT").font(.custom("Syncopate-Bold", size: titleSize)).foregroundStyle(.primary)
                Text("Player").font(.custom("Syncopate-Bold", size: titleSize)).foregroundStyle(.primary).padding(.bottom, 10)
                
                searchField
                    .padding(.bottom, 12)
            }
        }
        .collapsible(false)
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedTab) {
            sidebarContent(titleSize: 21, spacing: 2)
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
        .edgesIgnoringSafeArea(.top)
        .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth)
    }

    @ViewBuilder
    private var detailView: some View {
        let activeTab = selectedTab ?? filteredTabs.first ?? .general
        
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                switch activeTab {
                case .general:
                    GeneralSettingsTab()
                case .enhancements:
                    EnhancementsSettingsTab()
                case .about:
                    AboutSettingsTab()
                }
            }
            .environmentObject(navigationState)
            .environment(\.settingsTab, activeTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, titleHeaderHeight)

            VStack(spacing: 0) {
                HStack {
                    Text(activeTab.localizedName).font(.system(size: 20, weight: .semibold)).padding(.leading, 20)
                    Spacer()
                }
                .frame(height: titleHeaderHeight)
                .background(.bar)
                Divider()
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .edgesIgnoringSafeArea(.top)
    }

    @ViewBuilder
    private func sidebarItem(for tab: SettingsTab) -> some View {
        NavigationLink(value: tab) {
            Label {
                Text(tab.localizedName)
                    .font(.system(size: sidebarFontSize, weight: .medium))
                    .padding(.leading, 2)
            } icon: {
                Image(systemName: tab.iconName).resizable().scaledToFit().frame(height: sidebarRowHeight - 15)
            }
        }
        .frame(height: sidebarRowHeight)
    }
}

struct GeneralSettingsTab: View {
    @AppStorage("VTShowFileExtensions") private var showFileExtensions = true
    @AppStorage("VTAlwaysDarkOnPlayback") private var alwaysDarkOnPlayback = false

    var body: some View {
        SettingsContainer(.general) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection("User Interface") {
                    SettingsRow(
                        "Show file extensions in sidebar",
                        helperText: "Toggle whether file extensions (e.g. .mp4, .mkv) are visible in the recent files list."
                    ) {
                        Toggle("", isOn: $showFileExtensions)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsRow(
                        "Always dark when a video is playing",
                        helperText: "Force the application window to use dark mode styling during video playback, regardless of system theme."
                    ) {
                        Toggle("", isOn: $alwaysDarkOnPlayback)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct EnhancementsSettingsTab: View {
    @AppStorage("VTDefaultFILevel") private var defaultFILevel = 0
    @AppStorage("VTDefaultMBLevel") private var defaultMBLevel = 0
    @AppStorage("VTDefaultDNLevel") private var defaultDNLevel = 0.0
    @AppStorage("VTDefaultSharpness") private var defaultSharpness = 0.0
    @AppStorage("VTDefaultHDRBoost") private var defaultHDRBoost = 0.0
    @AppStorage("VTDefaultHDRColorfulness") private var defaultHDRColorfulness = 0.0

    var body: some View {
        SettingsContainer(.enhancements) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection("Neural Engine Fluidity") {
                    SettingsRow(
                        "Frame Interpolation",
                        helperText: "Temporal low-latency frame interpolation factor to boost frame rate."
                    ) {
                        Picker("", selection: $defaultFILevel) {
                            Text("Off").tag(0)
                            Text("2x").tag(2)
                            Text("4x").tag(4)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                        .padding(.trailing, -16)
                    }
                }

                SettingsSection("Postprocessing") {
                    SliderSettingsRow(
                        "Motion Blur",
                        helperText: "Apply a simulated motion blur filter (capped at 30 to prevent extreme darkening).",
                        value: Binding(
                            get: { Double(defaultMBLevel) },
                            set: { defaultMBLevel = Int($0) }
                        ),
                        range: 0.0...30.0,
                        defaultValue: 0.0,
                        step: 1.0,
                        valueString: { $0 > 0 ? String(format: "%.0f", $0) : "Off" }
                    )

                    Divider()

                    SliderSettingsRow(
                        "Denoise",
                        helperText: "Filter out noise dynamically using temporal reference frames.",
                        value: $defaultDNLevel,
                        range: 0.0...1.0,
                        defaultValue: 0.0,
                        step: 0.05,
                        valueString: { $0 > 0 ? String(format: "%.2f", $0) : "Off" }
                    )
                }

                SettingsSection("Color & Image Adjustments") {
                    VStack(spacing: 0) {
                        SliderSettingsRow(
                            "Sharpness",
                            helperText: "Adjust intensity of edge-enhancement contrast (radius is fixed at 0.5).",
                            value: $defaultSharpness,
                            range: 0.0...2.0,
                            defaultValue: 0.0,
                            step: 0.05
                        )

                        Divider()

                        SliderSettingsRow(
                            "HDR Boost",
                            helperText: "Luminance expansion from SDR into display's EDR headroom.",
                            value: $defaultHDRBoost,
                            range: 0.0...2.0,
                            defaultValue: 0.0,
                            step: 0.05
                        )

                        if defaultHDRBoost > 0 {
                            Divider()
                                .transition(.opacity)

                            SliderSettingsRow(
                                "HDR Colorfulness",
                                helperText: "Adjust chroma saturation boost in the midtone range during HDR expansion.",
                                value: $defaultHDRColorfulness,
                                range: 0.0...1.0,
                                defaultValue: 0.0,
                                step: 0.05
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: defaultHDRBoost)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct AboutSettingsTab: View {
    var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "VTPlayer"
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var currentYear: String {
        let year = Calendar.current.component(.year, from: Date())
        return String(year)
    }

    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var navigationState: SettingsNavigationState

    var body: some View {
        SettingsContainer(.about) {
            VStack(alignment: .leading, spacing: 32) {
                // Header Section
                HStack(spacing: 20) {
                    if let nsImage = NSApplication.shared.applicationIconImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 100, height: 100)
                            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appName)
                            .font(.custom("Syncopate-Bold", size: 24))
                        
                        Text("v\(appVersion)")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        
                        Text("© \(currentYear) Michael Yicheng Qiu")
                            .font(.footnote)
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Links")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        AboutLinkRow(title: "Report an issue", url: "https://github.com/gitmichaelqiu/VTPlayer/issues")
                        AboutLinkRow(title: "VTPlayer's GitHub", url: "https://github.com/gitmichaelqiu/VTPlayer")
                        AboutLinkRow(title: "My website", url: "https://mqiu.dev")
                        AboutLinkRow(title: "My GitHub", url: "https://github.com/gitmichaelqiu")
                    }
                }
                .id("GitHub / Support")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            navigationState.register(title: "GitHub / Support", tab: .about, keywords: ["github", "website", "developer", "contact", "support"])
        }
        .onDisappear {
            navigationState.unregister(title: "GitHub / Support", tab: .about)
        }
    }
}

struct AboutLinkRow: View {
    let title: String
    let url: String
    
    @State private var isHovering = false
    
    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundColor(isHovering ? .accentColor : .secondary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

class SettingsHostingController: NSHostingController<AnyView> {
    init(initialTab: SettingsTab? = .general) {
        let rootView = MacSettingsView(initialTab: initialTab)
        super.init(rootView: AnyView(rootView))
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.preferredContentSize = NSSize(
            width: defaultSettingsWindowWidth, height: defaultSettingsWindowHeight)
    }
}

class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()
    
    private var settingsWindowController: NSWindowController?
    
    func showSettings(tab: SettingsTab = .general) {
        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultSettingsWindowWidth, height: defaultSettingsWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.identifier = NSUserInterfaceItemIdentifier("SettingsWindow")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.center()
        window.minSize = NSSize(width: CGFloat(defaultSettingsWindowWidth), height: CGFloat(defaultSettingsWindowHeight))
        window.maxSize = NSSize(width: CGFloat(defaultSettingsWindowWidth), height: CGFloat(defaultSettingsWindowHeight))
        window.collectionBehavior = [.participatesInCycle]
        window.level = .normal
        
        let settingsVC = SettingsHostingController(initialTab: tab)
        window.contentViewController = settingsVC
        
        let windowController = NSWindowController(window: window)
        window.delegate = self
        settingsWindowController = windowController
        
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func windowWillClose(_ notification: Notification) {
        settingsWindowController = nil
    }
}
#endif
