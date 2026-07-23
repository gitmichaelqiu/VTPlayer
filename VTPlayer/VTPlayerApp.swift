//
//  VTPlayerApp.swift
//  VTPlayer
//

import SwiftUI

extension Notification.Name {
    static let openVideoFileTriggered = Notification.Name("openVideoFileTriggered")
    static let toggleLeftSidebarTriggered = Notification.Name("toggleLeftSidebarTriggered")
    static let toggleRightSidebarTriggered = Notification.Name("toggleRightSidebarTriggered")
}

@main
struct VTPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About VTPlayer") {
                    SettingsWindowManager.shared.showSettings(tab: .about)
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    SettingsWindowManager.shared.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            CommandGroup(after: .newItem) {
                Button("Open Video...") {
                    NotificationCenter.default.post(name: .openVideoFileTriggered, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Left Sidebar") {
                    NotificationCenter.default.post(name: .toggleLeftSidebarTriggered, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                
                Button("Toggle Right Sidebar") {
                    NotificationCenter.default.post(name: .toggleRightSidebarTriggered, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        #endif
    }
}
