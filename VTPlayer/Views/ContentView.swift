//
//  ContentView.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VTPlayerView()
            #if os(macOS)
            .frame(minWidth: 800, minHeight: 600)
            .background(WindowTabConfigurator())
            #endif
    }
}

#if os(macOS)
private struct WindowTabConfigurator: NSViewRepresentable {
    final class Coordinator {
        weak var window: NSWindow?
        var tabBarWasVisible = false
        var observers: [NSObjectProtocol] = []

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            self.window = window
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in self?.enterFullscreen() })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in self?.exitFullscreen() })
        }

        private func enterFullscreen() {
            guard let window, window.tabbedWindows != nil else { return }
            tabBarWasVisible = true
            window.toggleTabBar(nil)
        }

        private func exitFullscreen() {
            guard tabBarWasVisible, let window, window.tabbedWindows == nil else { return }
            tabBarWasVisible = false
            window.toggleTabBar(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        context.coordinator.attach(to: window)
        window.tabbingIdentifier = "dev.mqiu.VTPlayer"
        window.tabbingMode = .preferred
    }
}
#endif

#Preview {
    ContentView()
}
