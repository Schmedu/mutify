import AppKit
import SwiftUI

/// Mutify's window, owned outright rather than left to SwiftUI's `Settings`
/// scene. With no Dock icon — and a menu bar icon that a full menu bar can hide
/// entirely — this window has to open every single time it's asked for.
@MainActor
enum SettingsWindow {
    private static var controller: NSWindowController?

    static func show() {
        guard let state = AppEnvironment.state else { return }

        if controller == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: state))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Mutify"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 620, height: 520))
            window.center()
            controller = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        controller?.window?.center()
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}

/// The one piece of global state: the app's model, so the delegate and the
/// window can reach it.
@MainActor
enum AppEnvironment {
    static var state: AppState?
}
