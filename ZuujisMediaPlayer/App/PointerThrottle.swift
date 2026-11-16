// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Thins out pointer movement before the windows see it.
///
/// Measured: every mouse-moved event makes SwiftUI hit-test the whole main
/// window to find what is under the pointer (`HoverEventDispatcher`), about
/// 2.5 ms a time. At the sixty events a second a moving pointer sends, that
/// alone was 10-15% CPU.
///
/// While the pointer keeps moving, one event in every tenth of a second goes
/// through. When it slows or stops, the newest position is delivered a
/// moment later, so what it rests on lights up without a visible wait. Only
/// plain movement is thinned; clicks, drags and scrolling are untouched.
@MainActor
enum PointerThrottle {
    /// Between events passed on while the pointer is moving.
    private static let interval: TimeInterval = 0.1
    /// How long after the last movement its position is delivered.
    private static let settle: TimeInterval = 0.04
    private static var monitor: Any?
    private static var lastSent: TimeInterval = 0
    private static var held: NSEvent?
    private static var flush: DispatchWorkItem?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { filter(event) }
        }
    }

    private static func filter(_ event: NSEvent) -> NSEvent? {
        flush?.cancel()
        flush = nil
        if event.timestamp - lastSent >= interval {
            lastSent = event.timestamp
            held = nil
            return event
        }
        // Too soon: keep it, and deliver it if nothing newer follows.
        held = event
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let event = held else { return }
                held = nil
                flush = nil
                lastSent = ProcessInfo.processInfo.systemUptime
                // Straight to the window: `NSApp.sendEvent` would come back
                // through this monitor.
                event.window?.sendEvent(event)
            }
        }
        flush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
        return nil
    }
}
