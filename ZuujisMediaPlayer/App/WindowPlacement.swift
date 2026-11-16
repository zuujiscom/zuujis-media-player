// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Puts the main window back where it was closed, on the screen it was on.
///
/// SwiftUI restores the window's size, but it opens the window on whichever
/// display has the keyboard focus at that moment and shifts the saved
/// position across to it: a window left on the second screen came back on
/// the first one whenever the app was started from there. So the frame is
/// kept here, under our own key, and put back when a main window first shows.
@MainActor
enum WindowPlacement {
    private static let key = "mainWindowFrame"
    /// Main windows already put back. Only these have their moves recorded:
    /// the misplaced frame a new window starts with must not be saved.
    private static let placed = NSHashTable<NSWindow>.weakObjects()
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ body: @escaping @MainActor (NSWindow) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { if isMain(window) { body(window) } }
            })
        }
        observe(NSWindow.didBecomeKeyNotification, place)
        observe(NSWindow.didBecomeMainNotification, place)
        observe(NSWindow.didChangeOcclusionStateNotification, place)
        observe(NSWindow.didMoveNotification, record)
        observe(NSWindow.didResizeNotification, record)
        observe(NSWindow.willCloseNotification, record)
    }

    /// The player window, not the visualizer, the queue or Settings.
    private static func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(ZuujisMediaPlayerApp.mainWindowID) == true
    }

    private static func place(_ window: NSWindow) {
        guard !placed.contains(window), window.isVisible else { return }
        placed.add(window)
        guard let text = UserDefaults.standard.string(forKey: key) else { return }
        let frame = NSRectFromString(text)
        // Only if that place still exists: the screen may have been unplugged.
        let onScreen = NSScreen.screens.contains { screen in
            let shared = screen.visibleFrame.intersection(frame)
            return shared.width >= 200 && shared.height >= 100
        }
        guard onScreen, frame.width >= 200, frame.height >= 200, window.frame != frame else { return }
        window.setFrame(frame, display: true)
    }

    private static func record(_ window: NSWindow) {
        guard placed.contains(window), !window.styleMask.contains(.fullScreen),
              !window.isMiniaturized else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
    }
}
