//
//  VTPlayerApp.swift
//  VTPlayer
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

extension Notification.Name {
    static let openVideoFileTriggered = Notification.Name("openVideoFileTriggered")
    static let toggleLeftSidebarTriggered = Notification.Name("toggleLeftSidebarTriggered")
    static let toggleRightSidebarTriggered = Notification.Name("toggleRightSidebarTriggered")
    static let recentVideosDidChange = Notification.Name("recentVideosDidChange")
}

@main
struct VTPlayerApp: App {
    #if os(macOS)
    init() {
        NSWindow.allowsAutomaticWindowTabbing = true
    }
    #endif

    #if os(macOS)
    private static func createTab() {
        guard let currentWindow = NSApp.keyWindow else { return }
        let existingWindows = NSApp.windows

        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)

        let attachNewWindow = {
            guard let newWindow = NSApp.windows.first(where: { candidate in
                candidate !== currentWindow && !existingWindows.contains(where: { $0 === candidate })
            }) else { return }

            // SwiftUI creates the scene window first. Keep it out of the
            // window list while AppKit attaches it to the current tab group.
            newWindow.orderOut(nil)
            newWindow.tabbingIdentifier = currentWindow.tabbingIdentifier
            newWindow.tabbingMode = .preferred
            currentWindow.addTabbedWindow(newWindow, ordered: .above)
            currentWindow.tabGroup?.selectedWindow = newWindow
            newWindow.makeKeyAndOrderFront(nil)
        }

        attachNewWindow()
        DispatchQueue.main.async(execute: attachNewWindow)
    }
    #endif

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
                Button("New Tab") {
                    Self.createTab()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("Open Video...") {
                    NotificationCenter.default.post(name: .openVideoFileTriggered, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Show/Hide Tab Bar") {
                    if let window = NSApp.mainWindow ?? NSApp.keyWindow {
                        WindowChromeBridge.toggleTabBar(in: window)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
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
