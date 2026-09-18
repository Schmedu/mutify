import AppKit
import SwiftUI

/// Mutify's window, owned outright rather than left to SwiftUI's `Settings`
/// scene. With no Dock icon — and a menu bar icon that a full menu bar can hide
/// entirely — this window has to open every single time it's asked for.
@MainActor
enum SettingsWindow {
    private static var controller: NSWindowController?
    private static let delegate = WindowDelegate()

    static func show() {
        guard let state = AppEnvironment.state else { return }

        if controller == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: state))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Mutify"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = delegate
            window.setContentSize(NSSize(width: 620, height: 520))
            window.center()
            controller = NSWindowController(window: window)
        }

        // An accessory app can't pull itself to the front on macOS 14+, and a
        // window nobody can see is no use — least of all when it's the one
        // asking for the permission the app needs. Becoming a regular app for
        // as long as the window is open is the supported way through.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        controller?.window?.orderFrontRegardless()
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Back to living in the menu bar only.
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// The one piece of global state: the app's model, so the delegate and the
/// window can reach it.
@MainActor
enum AppEnvironment {
    static var state: AppState?
}
