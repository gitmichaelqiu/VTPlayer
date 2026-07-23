import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if canImport(PhotosUI)
import PhotosUI
import UniformTypeIdentifiers
#endif

struct QLModelStatusView: View {
    let modelManager: VTModelManager

    var body: some View {
        let modelStatus = modelManager.status
        LabeledContent("QL Model", value: modelStatusLabel(modelStatus))
            .foregroundStyle(modelStatusColor(modelStatus))
        if case .downloading(let progress) = modelStatus {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 200)
        }
    }

    private func modelStatusLabel(_ status: VTModelManager.Status) -> String {
        switch status {
        case .notChecked: return "Not Checked"
        case .ready: return "Ready"
        case .downloadRequired: return "Download Required"
        case .downloading(let progress): return String(format: "Downloading (%.0f%%)", progress * 100)
        case .failed(let error): return "Failed: \(error)"
        }
    }

    private func modelStatusColor(_ status: VTModelManager.Status) -> Color {
        switch status {
        case .ready: return .green
        case .downloading: return .orange
        case .downloadRequired, .notChecked: return .secondary
        case .failed: return .red
        }
    }
}

/// Helper view for blur/visual effect backgrounds.
#if os(macOS)
struct WindowChromeBridge: NSViewRepresentable {
    let onFullScreenChanged: (Bool) -> Void

    // WindowGroup hosts its tab chrome in AppKit's NSTabBar views. Keep this
    // fallback limited to the explicit tab-bar command; fullscreen is left to
    // SwiftUI's documented toolbar hover behavior.
    static func toggleTabBar(in window: NSWindow) {
        let hidden = tabBarViews(in: window).first?.isHidden ?? false
        setTabBarHidden(!hidden, in: window)
    }

    static func setTabBarHidden(_ hidden: Bool, in window: NSWindow) {
        tabBarViews(in: window).forEach { $0.isHidden = hidden }
    }

    private static func tabBarViews(in window: NSWindow) -> [NSView] {
        guard let root = window.contentView?.superview else { return [] }
        var matches: [NSView] = []

        func visit(_ view: NSView) {
            let className = NSStringFromClass(type(of: view))
            if className == "NSTabBar" || className == "NSTabBarNewTabButton" {
                matches.append(view)
            }
            view.subviews.forEach(visit)
        }

        visit(root)
        return matches
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFullScreenChanged: onFullScreenChanged)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onFullScreenChanged = onFullScreenChanged
        context.coordinator.attach(to: nsView)
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView)
        }
    }

    final class Coordinator: NSObject {
        var onFullScreenChanged: (Bool) -> Void
        weak var observedView: NSView?
        weak var window: NSWindow?

        init(onFullScreenChanged: @escaping (Bool) -> Void) {
            self.onFullScreenChanged = onFullScreenChanged
        }

        func attach(to view: NSView) {
            guard view.window !== window else {
                synchronize()
                return
            }

            if let oldWindow = window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: oldWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: oldWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: oldWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: oldWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: oldWindow)
            }

            observedView = view
            window = view.window
            guard let window else { return }

            window.tabbingIdentifier = NSWindow.TabbingIdentifier("VTPlayer")

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(fullScreenChanged),
                name: NSWindow.didEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(fullScreenChanged),
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowBecameKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowBecameKey),
                name: NSWindow.didBecomeMainNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowBecameKey),
                name: NSWindow.didResizeNotification,
                object: window
            )
            synchronize()
            scheduleToolbarCleanup(for: window)
        }

        @objc private func fullScreenChanged() {
            synchronize()
        }

        @objc private func windowBecameKey() {
            synchronize()
            if let window {
                scheduleToolbarCleanup(for: window)
            }
        }

        private func scheduleToolbarCleanup(for window: NSWindow) {
            for delay in [0.0, 0.05, 0.2, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.hideDocumentControls(in: window)
                    self.removeDefaultSidebarToggle(from: window)
                }
            }
        }

        private func synchronize() {
            guard let window else { return }
            hideDocumentControls(in: window)
            removeDefaultSidebarToggle(from: window)
            let isFullScreen = window.styleMask.contains(.fullScreen)

            if isFullScreen {
                window.backgroundColor = .black
                window.appearance = NSAppearance(named: .darkAqua)
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.toolbarStyle = .unified
                setTitlebarBackground(on: window, color: .black)
            } else {
                window.backgroundColor = .windowBackgroundColor
                window.appearance = nil
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.toolbarStyle = .unified
                setTitlebarBackground(on: window, color: .windowBackgroundColor)
            }

            onFullScreenChanged(isFullScreen)
        }

        private func removeDefaultSidebarToggle(from window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            let sidebarIdentifier = NSToolbarItem.Identifier.toggleSidebar
            while let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == sidebarIdentifier }) {
                toolbar.removeItem(at: index)
            }
        }

        private func hideDocumentControls(in window: NSWindow) {
            window.standardWindowButton(.documentIconButton)?.isHidden = true
            window.standardWindowButton(.documentVersionsButton)?.isHidden = true
        }

        private func setTitlebarBackground(on window: NSWindow, color: NSColor) {
            guard let closeButton = window.standardWindowButton(.closeButton) else { return }
            var view: NSView? = closeButton
            while let current = view {
                current.wantsLayer = true
                current.layer?.backgroundColor = color.cgColor
                view = current.superview
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: PlatformVisualEffectMaterial
    let blendingMode: PlatformVisualEffectBlendingMode

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
#else
struct VisualEffectView: UIViewRepresentable {
    let material: PlatformVisualEffectMaterial
    let blendingMode: PlatformVisualEffectBlendingMode

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}
#endif

extension View {
    @ViewBuilder
    func macOnHover(perform action: @escaping (Bool) -> Void) -> some View {
        #if os(macOS)
        self.onHover(perform: action)
        #else
        self
        #endif
    }

    @ViewBuilder
    func macWindowToolbarFullScreenVisibility() -> some View {
        #if os(macOS)
        self.windowToolbarFullScreenVisibility(.onHover)
        #else
        self
        #endif
    }

    @ViewBuilder
    func macNavigationBarTitleDisplayMode() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#if canImport(PhotosUI)
struct PhotosMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { receivedData in
            let fileURL = receivedData.file
            let isAccessing = fileURL.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(fileURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: copy.path) {
                try? FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: fileURL, to: copy)
            return .init(url: copy)
        }
    }
}
#endif
