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
        var tabBarWasVisible: Bool?

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
            }

            observedView = view
            window = view.window
            guard let window else { return }

            window.tabbingIdentifier = NSWindow.TabbingIdentifier("VTPlayer")
            window.tabbingMode = .preferred

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
            synchronize()
        }

        @objc private func fullScreenChanged() {
            synchronize()
        }

        @objc private func windowBecameKey() {
            synchronize()
        }

        private func synchronize() {
            guard let window else { return }
            let isFullScreen = window.styleMask.contains(.fullScreen)

            if isFullScreen {
                if tabBarWasVisible == nil {
                    tabBarWasVisible = window.tabGroup?.isTabBarVisible
                }
                window.tabGroup?.isTabBarVisible = false
                window.backgroundColor = .black
                window.appearance = NSAppearance(named: .darkAqua)
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.toolbarStyle = .unified
                setTitlebarBackground(on: window, color: .black)
            } else {
                if let tabBarWasVisible {
                    window.tabGroup?.isTabBarVisible = tabBarWasVisible
                    self.tabBarWasVisible = nil
                }
                window.backgroundColor = .windowBackgroundColor
                window.appearance = nil
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.toolbarStyle = .unified
                setTitlebarBackground(on: window, color: .windowBackgroundColor)
            }

            onFullScreenChanged(isFullScreen)
        }

        private func setTitlebarBackground(on window: NSWindow, color: NSColor) {
            guard let closeButton = window.standardWindowButton(.closeButton) else { return }
            let titlebarView = closeButton.superview?.superview
            titlebarView?.wantsLayer = true
            titlebarView?.layer?.backgroundColor = color.cgColor
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
