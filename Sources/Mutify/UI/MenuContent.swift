import AppKit
import MutifyCore
import SwiftUI

/// The menu bar menu. Its first two lines always say what Mutify is doing and why.
struct MenuContent: View {
    @Bindable var state: AppState

    var body: some View {
        Text(state.headline)
        Text(state.subline)

        Divider()

        if state.needsSetup {
            Button("Finish setting up…") { SettingsWindow.show() }
        }

        if state.locationPermissionMissing, state.place == .unavailable {
            Button("Grant Location access…") { state.requestLocationPermission() }
            Button("Open System Settings…") { state.openLocationSettings() }
        }

        if state.isOverrideActive {
            Button("Resume muting now") { state.cancelOverride() }
        } else {
            ForEach(availableOverrides) { option in
                Button(option.title) { state.startOverride(option) }
            }
        }

        Divider()

        if let name = state.currentNetworkName {
            let policy = state.currentNetworkPolicy
            if policy != .allow {
                Button("Add “\(name)” to Allow list") { state.addCurrentNetwork(to: .allow) }
            }
            if policy != .mute {
                Button("Add “\(name)” to Mute list") { state.addCurrentNetwork(to: .mute) }
            }
        }

        Button("Mute now") { state.muteNow() }

        Divider()

        Button(state.settings.masterEnabled ? "Pause Mutify" : "Resume Mutify") {
            state.setPaused(state.settings.masterEnabled)
        }

        Button("Settings…") { SettingsWindow.show() }
            .keyboardShortcut(",", modifiers: .command)

        Button("Quit Mutify") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var availableOverrides: [OverrideOption] {
        OverrideOption.allCases.filter { option in
            option != .untilNetworkChange || state.place.identity != nil
        }
    }
}
