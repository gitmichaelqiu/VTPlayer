//
//  VTPlayerApp.swift
//  VTPlayer
//

import SwiftUI

@main
struct VTPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        Settings {
            MacSettingsView()
                .frame(width: CGFloat(defaultSettingsWindowWidth), height: CGFloat(defaultSettingsWindowHeight))
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}
