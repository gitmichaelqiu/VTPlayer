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
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        window.tabbingIdentifier = "dev.mqiu.VTPlayer"
        window.tabbingMode = .preferred
    }
}
#endif

#Preview {
    ContentView()
}
