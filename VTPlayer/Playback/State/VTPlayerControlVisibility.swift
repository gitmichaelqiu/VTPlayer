import SwiftUI
#if os(macOS)
import AppKit
#endif

extension VTPlayerViewModel {
    #if os(macOS)
    @objc func windowWillChangeFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === (NSApp.mainWindow ?? NSApp.keyWindow),
              isPlaying, !isPaused, let videoURL else { return }
        fullscreenResumeURL = videoURL
        fullscreenTransitionWindow = window
        pause()
    }

    private func resumeAfterFullScreenTransition(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === fullscreenTransitionWindow, let url = fullscreenResumeURL else { return }
        fullscreenResumeURL = nil
        fullscreenTransitionWindow = nil
        guard videoURL == url, isPaused, isPlaying else { return }
        play()
    }

    @objc func windowDidEnterFullScreen(_ notification: Notification) {
        self.isFullScreen = true
        (notification.object as? NSWindow)?.acceptsMouseMovedEvents = true
        resumeAfterFullScreenTransition(notification)
        self.userActivityDetected()
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            window.backgroundColor = .black
        }
    }
    
    @objc func windowDidExitFullScreen(_ notification: Notification) {
        self.isFullScreen = false
        resumeAfterFullScreenTransition(notification)
        self.showControls = true
        if self.cursorHidden {
            NSCursor.unhide()
            self.cursorHidden = false
        }
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            window.backgroundColor = .windowBackgroundColor
        }
    }
    #endif
    
    func userActivityDetected() {
        let shouldAutoHide = isPlaying && !isPaused
        
        if shouldAutoHide {
            self.showControls = true
            #if os(macOS)
            if self.cursorHidden {
                NSCursor.unhide()
                self.cursorHidden = false
            }
            #endif
            startInactivityTimer()
        } else {
            self.showControls = true
            #if os(macOS)
            if self.cursorHidden {
                NSCursor.unhide()
                self.cursorHidden = false
            }
            #endif
            inactivityTask?.cancel()
        }
    }
    
    /// Toggles controls visibility — used on iOS to keep the navigation bar
    /// in sync with VideoPlayer's native transport controls which also toggle on tap.
    func toggleControls() {
        if showControls {
            showControls = false
            inactivityTask?.cancel()
        } else {
            showControls = true
            startInactivityTimer()
        }
    }
    
    func startInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            guard !Task.isCancelled, let self = self else { return }
            #if os(iOS)
            let shouldHide = self.isPlaying && !self.isPaused
            #else
            let shouldHide = self.isPlaying && !self.isPaused && !self.isHoveringControlBar && !self.isConfigurationPopoverPresented
            #endif
            if shouldHide {
                self.showControls = false
                 #if os(macOS)
                 let initialPointerLocation = NSEvent.mouseLocation
                 let pointerInWindow = (self.renderer.window ?? NSApp.keyWindow)?.frame.contains(initialPointerLocation) == true
                 if !self.cursorHidden && (self.isHoveringVideo || pointerInWindow) {
                     NSCursor.hide()
                     self.cursorHidden = true
                 }
                 while !Task.isCancelled && !self.showControls {
                     try? await Task.sleep(nanoseconds: 100_000_000)
                     guard !Task.isCancelled else { return }
                     if NSEvent.mouseLocation != initialPointerLocation || !NSApp.isActive {
                         self.userActivityDetected()
                         return
                     }
                 }
                 #endif
            }
        }
    }

}
