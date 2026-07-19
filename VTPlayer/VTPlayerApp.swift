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
        }
        #endif
    }
}
