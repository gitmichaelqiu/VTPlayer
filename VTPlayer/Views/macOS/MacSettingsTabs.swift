#if os(macOS)
import SwiftUI
import Combine
import AppKit

struct GeneralSettingsTab: View {
    @AppStorage("VTShowFileExtensions") private var showFileExtensions = true
    @AppStorage("VTAlwaysDarkOnPlayback") private var alwaysDarkOnPlayback = false
    @AppStorage("VTDefaultContinueVideoPlayback") private var defaultContinueVideoPlayback = true
    @State private var automaticallyChecksForUpdates = false
    @State private var automaticallyDownloadsUpdates = false

    var body: some View {
        SettingsContainer(.general) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection("User Interface") {
                    SettingsRow(
                        "Show file extensions",
                        helperText: "Show or hide file extensions."
                    ) {
                        Toggle("", isOn: $showFileExtensions)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsRow(
                        "Continue video playback",
                        helperText: "Resume new videos from their saved position."
                    ) {
                        Toggle("", isOn: $defaultContinueVideoPlayback)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsRow(
                        "Always use dark mode when playing",
                        helperText: "Use dark styling during playback."
                    ) {
                        Toggle("", isOn: $alwaysDarkOnPlayback)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                SettingsSection("Updates") {
                    SettingsRow(
                        "Automatically check for updates"
                    ) {
                        Toggle("", isOn: $automaticallyChecksForUpdates)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(!VTPlayerUpdater.shared.isConfigured)
                            .onChange(of: automaticallyChecksForUpdates) { _, value in
                                VTPlayerUpdater.shared.automaticallyChecksForUpdates = value
                            }
                    }

                    if automaticallyChecksForUpdates {
                        VStack(spacing: 0) {
                            Divider()

                            SettingsRow(
                                "Automatically download updates"
                            ) {
                                Toggle("", isOn: $automaticallyDownloadsUpdates)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .disabled(!VTPlayerUpdater.shared.isConfigured)
                                    .onChange(of: automaticallyDownloadsUpdates) { _, value in
                                        VTPlayerUpdater.shared.automaticallyDownloadsUpdates = value
                                    }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Divider()

                    SettingsRow(
                        "Check for updates",
                    ) {
                        Button("Check Now") {
                            VTPlayerUpdater.shared.checkForUpdates()
                        }
                        .disabled(!VTPlayerUpdater.shared.isConfigured)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: automaticallyChecksForUpdates)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onAppear {
                automaticallyChecksForUpdates = VTPlayerUpdater.shared.automaticallyChecksForUpdates
                automaticallyDownloadsUpdates = VTPlayerUpdater.shared.automaticallyDownloadsUpdates
            }
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
    @AppStorage("VTEnhancedFrameCacheMemoryMB") private var enhancedFrameCacheMemoryMB = 1_024

    var body: some View {
        SettingsContainer(.enhancements) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection("Neural Engine Enhancements") {
                    SettingsRow(
                        "Frame Interpolation",
                        helperText: "Increase the video frame rate."
                    ) {
                        Picker("", selection: $defaultFILevel) {
                            Text("Off").tag(0)
                            Text("2x").tag(2)
                            Text("4x").tag(4)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                        .padding(.trailing, -20)
                    }

                    Divider()

                    SettingsRow(
                        "Enhanced frame cache",
                        helperText: "Maximum memory for enhanced-frame prebuffering."
                    ) {
                        HStack(spacing: 10) {
                            Slider(value: Binding(
                                get: { Double(min(max(enhancedFrameCacheMemoryMB, 256), 4_096)) },
                                set: { enhancedFrameCacheMemoryMB = Int($0.rounded()) }
                            ), in: 256...4_096, step: 256)
                            .frame(width: 150)

                            Text(enhancedFrameCacheMemoryMB >= 1_024
                                 ? String(format: "%.1f GB", Double(enhancedFrameCacheMemoryMB) / 1_024.0)
                                 : "\(enhancedFrameCacheMemoryMB) MB")
                                .font(.subheadline.monospacedDigit())
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                }

                SettingsSection("Postprocessing") {
                    SliderSettingsRow(
                        "Motion Blur",
                        helperText: "Apply motion blur.",
                        value: Binding(
                            get: { Double(defaultMBLevel) },
                            set: { defaultMBLevel = Int($0) }
                        ),
                        range: 0.0...100.0,
                        defaultValue: 0.0,
                        step: 5.0,
                        valueString: { $0 > 0 ? String(format: "%.0f", $0) : String(localized: "Off") }
                    )

                    Divider()

                    SliderSettingsRow(
                        "Denoise",
                        helperText: "Reduce video noise.",
                        value: $defaultDNLevel,
                        range: 0.0...1.0,
                        defaultValue: 0.0,
                        step: 0.05,
                        valueString: { $0 > 0 ? String(format: "%.2f", $0) : String(localized: "Off") }
                    )
                }

                SettingsSection("Color & Image Adjustments") {
                    VStack(spacing: 0) {
                        SliderSettingsRow(
                            "Sharpness",
                            value: $defaultSharpness,
                            range: 0.0...2.0,
                            defaultValue: 0.0,
                            step: 0.05
                        )

                        Divider()

                        SliderSettingsRow(
                            "HDR Boost",
                            helperText: "Expand luminance for HDR displays.",
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
                                helperText: "Adjust HDR color intensity.",
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
                        AboutLinkRow(title: "Author's website", url: "https://mqiu.dev")
                        AboutLinkRow(title: "Author's GitHub", url: "https://github.com/gitmichaelqiu")
                    }
                }
                .id("GitHub / Support")

                VStack(alignment: .leading, spacing: 16) {
                    Text("More Apps")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(spacing: 12) {
                        OtherAppRow(
                            imageName: "DesktopRenamerIcon_Default",
                            darkImageName: "DesktopRenamerIcon_Dark",
                            appName: "DesktopRenamer",
                            description: "The essential tool for naming and organizing your desktop spaces.",
                            url: "https://desktoprenamer.mqiu.dev"
                        )

                        OtherAppRow(
                            imageName: "OptClickerIcon_Default",
                            darkImageName: "OptClickerIcon_Dark",
                            appName: "OptClicker",
                            description: "Let you right-click with the Option key.",
                            url: "https://optclicker.mqiu.dev"
                        )

                        OtherAppRow(
                            imageName: "SpaceSwitcherIcon_Default",
                            darkImageName: "SpaceSwitcherIcon_Dark",
                            appName: "SpaceSwitcher",
                            description: "Control which app and dock to show in each space.",
                            url: "https://spaceswitcher.mqiu.dev"
                        )
                    }
                }
                .id("More Apps")

                VStack(alignment: .leading, spacing: 12) {
                    Text("Acknowledgements")
                        .font(.headline)
                        .foregroundColor(.primary)

                    AboutButtonRow(title: "Acknowledgement.pdf", action: openAcknowledgements)
                }
                .id("Acknowledgements")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            navigationState.register(
                title: "GitHub / Support",
                tab: .about,
                keywords: ["github", "website", "developer", "contact", "support", "apps", "acknowledgements"]
            )
        }
        .onDisappear {
            navigationState.unregister(title: "GitHub / Support", tab: .about)
        }
    }

    private func openAcknowledgements() {
        guard let url = Bundle.main.url(forResource: "Acknowledgement", withExtension: "pdf") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}

struct AboutLinkRow: View {
    let title: LocalizedStringKey
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

struct AboutButtonRow: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundColor(isHovering ? .accentColor : .secondary)
                Spacer()
                Image(systemName: "doc.fill")
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

struct OtherAppRow: View {
    let imageName: String
    let darkImageName: String
    let appName: String
    let description: LocalizedStringKey
    let url: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 16) {
                ZStack {
                    let selectedImageName = colorScheme == .dark ? darkImageName : imageName
                    if let nsImage = NSImage(named: selectedImageName) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "app.dashed")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                            .foregroundColor(.secondary)
                    }
                }
                .shadow(color: .black.opacity(isHovering ? 0.2 : 0.1), radius: isHovering ? 6 : 2, x: 0, y: 2)
                .scaleEffect(isHovering ? 1.05 : 1.0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .font(.custom("Syncopate-Bold", size: 17))
                        .foregroundColor(.primary)

                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if isHovering {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Color.accentColor.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovering ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
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
            // Recreate the hosting root when a specific tab is requested;
            // MacSettingsView's initial tab is intentionally immutable after
            // construction.
            if tab != .general {
                window.close()
                settingsWindowController = nil
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
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
