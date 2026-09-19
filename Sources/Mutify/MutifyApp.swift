import AppKit
import MutifyCore
import SwiftUI

@main
struct MutifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra(isInserted: $state.settings.showMenuBarIcon) {
            MenuContent(state: state)
        } label: {
            Image(nsImage: MenuBarIcon.image(named: state.statusSymbol))
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        // Diagnostics run without starting the menu bar app at all.
        if Probe.shouldRun(CommandLine.arguments) {
            MainActor.assumeIsolated { Probe.run(CommandLine.arguments) }
            exit(0)
        }

        // Only hand the model over here. Everything that touches the system
        // waits for applicationDidFinishLaunching — CoreLocation in particular
        // is inert if it's set up any earlier.
        let state = self.state
        MainActor.assumeIsolated { AppEnvironment.state = state }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no window on launch.
        NSApp.setActivationPolicy(.accessory)
        reportStatusItemPlacement()

        guard let state = AppEnvironment.state else { return }
        state.start()

        // Only a genuine first run gets to take over the screen. A missing
        // permission is reported in the menu bar and waited on — an app that
        // grabs focus every time it launches is an app you end up quitting.
        if state.isFirstRun {
            SettingsWindow.show()
        }

        // Test hook: does the permission prompt actually appear? Standing in for
        // a click on "Ask me now", so the flow can be checked on a machine
        // nobody is working on.
        let askedOnCommandLine = CommandLine.arguments.contains("--ask-location")
        if askedOnCommandLine || ProcessInfo.processInfo.environment["MUTIFY_ASK_LOCATION"] == "1" {
            SettingsWindow.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                state.requestLocationPermission()
            }
        }
    }

    /// `MUTIFY_DEBUG_STATUS=1` reports where the menu bar icon ended up. A full
    /// menu bar parks new items in a region that is never drawn, which otherwise
    /// looks exactly like the app failing to start.
    func reportStatusItemPlacement() {
        guard ProcessInfo.processInfo.environment["MUTIFY_DEBUG_STATUS"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            var report = "NSApp.windows: \(NSApp.windows.count)\n"
            for window in NSApp.windows {
                report += "  \(type(of: window))  frame=\(window.frame)  visible=\(window.isVisible)\n"
            }
            FileHandle.standardError.write(Data(report.utf8))
        }
    }

    /// Opening Mutify again while it's already running brings up Settings. On a
    /// full menu bar the icon can end up with nowhere to be drawn, and this is
    /// then the only way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindow.show()
        return true
    }

}

enum MenuBarIcon {
    /// SF Symbol names vary by OS version; fall back rather than show nothing.
    @MainActor
    static func image(named name: String) -> NSImage {
        let candidates = [name, "speaker.wave.2", "speaker"]
        for candidate in candidates {
            if let image = NSImage(systemSymbolName: candidate, accessibilityDescription: "Mutify") {
                image.isTemplate = true
                return image
            }
        }
        return NSImage(size: NSSize(width: 16, height: 16))
    }
}
