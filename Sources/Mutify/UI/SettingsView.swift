import AppKit
import MutifyCore
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            GeneralTab(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            NetworksTab(state: state)
                .tabItem { Label("Networks", systemImage: "wifi") }
            DevicesTab(state: state)
                .tabItem { Label("Devices", systemImage: "hifispeaker") }
            ActivityTab(state: state)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 520)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            if state.needsSetup {
                Section {
                    SetupCard(state: state)
                }
            }

            Section("Right now") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.headline).fontWeight(.medium)
                    Text(state.subline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !state.needsSetup {
                    HStack {
                        if state.isOverrideActive {
                            Button("Resume muting now") { state.cancelOverride() }
                        } else {
                            Button("Allow 15 min") { state.startOverride(.fifteenMinutes) }
                            Button("Allow 1 hour") { state.startOverride(.oneHour) }
                            if state.place.ssid != nil {
                                Button("Allow until I leave this network") {
                                    state.startOverride(.untilNetworkChange)
                                }
                            }
                        }
                        Spacer()
                        Button("Mute now") { state.muteNow() }
                    }
                }
            }

            if state.locationPermissionMissing {
                Section {
                    LocationPermissionRow(state: state)
                }
            }

            Section("Behaviour") {
                Toggle("Mute when I'm away", isOn: $state.settings.masterEnabled)

                Picker("Hold the volume down", selection: $state.settings.enforcementMode) {
                    ForEach(EnforcementMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(state.settings.enforcementMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Networks on neither list", selection: $state.settings.unknownNetworkPolicy) {
                    Text("Mute (safer)").tag(PlacePolicy.mute)
                    Text("Allow sound").tag(PlacePolicy.allow)
                }
                Text("Also applies when there's no Wi-Fi at all — Ethernet, or offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Coming back") {
                Toggle("Restore my volume when sound is allowed again", isOn: $state.settings.restoreVolume)
                Toggle("Never restore above a limit", isOn: capEnabled)
                    .disabled(!state.settings.restoreVolume)
                if let cap = state.settings.restoreCap {
                    HStack {
                        Slider(value: capValue, in: 0.05...1.0)
                        Text("\(Int((cap * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .disabled(!state.settings.restoreVolume)
                }
            }

            Section("System") {
                Toggle("Notify me when Mutify mutes", isOn: $state.settings.notifyOnMute)
                Toggle("Launch at login", isOn: Binding(
                    get: { state.loginItemEnabled },
                    set: { state.setLoginItem($0) }
                ))
                .disabled(!LoginItem.isAvailable)
                if !LoginItem.isAvailable {
                    Text("Available once Mutify runs as an installed app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var capEnabled: Binding<Bool> {
        Binding(
            get: { state.settings.restoreCap != nil },
            set: { state.settings.restoreCap = $0 ? 0.5 : nil }
        )
    }

    private var capValue: Binding<Double> {
        Binding(
            get: { state.settings.restoreCap ?? 0.5 },
            set: { state.settings.restoreCap = $0 }
        )
    }
}

/// First run: Mutify stays quiet until it knows which network is home.
private struct SetupCard: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Finish setting up", systemImage: "hand.wave")
                .fontWeight(.medium)
            if let ssid = state.place.ssid {
                Text("You're on “\(ssid)”. If this is a place where sound is fine, allow it here — everywhere else will be muted whenever sound would come out of the speakers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Sound is fine on “\(ssid)”") {
                        state.completeSetup(allowCurrentNetwork: true)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Not here — start muting") {
                        state.completeSetup(allowCurrentNetwork: false)
                    }
                }
            } else {
                Text("Mutify can't see a Wi-Fi network right now. You can add networks by hand on the Networks tab, then start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Start muting") { state.completeSetup(allowCurrentNetwork: false) }
                    .buttonStyle(.borderedProminent)
            }
            Text("Nothing is muted until you choose.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct LocationPermissionRow: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Mutify needs Location access to work", systemImage: "location.slash")
                .fontWeight(.medium)
            Text("macOS won't tell any app the name of the Wi-Fi network without it — it answers “<redacted>” instead. Until you grant access Mutify can't tell one network from another, so it stands down and mutes nothing. Your location never leaves this Mac; Mutify only ever reads the network name.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Status: \(state.locationStatusDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if state.canPromptForLocation {
                    Button("Ask me now") { state.requestLocationPermission() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Open System Settings") { state.openLocationSettings() }
            }
        }
    }
}

// MARK: - Networks

private struct NetworksTab: View {
    @Bindable var state: AppState
    @State private var newAllow = ""
    @State private var newMute = ""
    @State private var networkLabel = ""

    var body: some View {
        Form {
            Section("Current network") {
                if let identity = state.place.identity {
                    LabeledContent(identity.displayName(labels: state.settings.networkLabels)) {
                        HStack {
                            Button("Allow here") { state.addCurrentNetwork(to: .allow) }
                                .disabled(state.currentNetworkPolicy == .allow)
                            Button("Mute here") { state.addCurrentNetwork(to: .mute) }
                                .disabled(state.currentNetworkPolicy == .mute)
                        }
                    }
                    if identity.ssid == nil {
                        HStack {
                            TextField("Give this network a name", text: $networkLabel)
                                .onSubmit { state.labelCurrentNetwork(networkLabel) }
                            Button("Save") { state.labelCurrentNetwork(networkLabel) }
                                .disabled(networkLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Text("macOS won't reveal the Wi-Fi name without Location access, so Mutify recognises this network by its router instead. The name is just for you.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(state.place == .unavailable
                         ? "On a network, but nothing identifies it yet."
                         : "Not connected to a network.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Allow list — sound may play here") {
                SSIDList(entries: state.settings.allowList, labels: state.settings.networkLabels) { state.settings.remove($0) }
                AddField(text: $newAllow, placeholder: "Network name") {
                    state.settings.add(newAllow, to: .allow)
                    newAllow = ""
                }
            }

            Section("Mute list — always muted here") {
                SSIDList(entries: state.settings.muteList, labels: state.settings.networkLabels) { state.settings.remove($0) }
                AddField(text: $newMute, placeholder: "Network name") {
                    state.settings.add(newMute, to: .mute)
                    newMute = ""
                }
                Text("A network on both lists is muted. Deny wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !unlistedSeen.isEmpty {
                Section("Networks you've been on") {
                    ForEach(unlistedSeen, id: \.self) { ssid in
                        LabeledContent(NetworkIdentity.describe(key: ssid, labels: state.settings.networkLabels)) {
                            HStack {
                                Button("Allow") { state.settings.add(ssid, to: .allow) }
                                Button("Mute") { state.settings.add(ssid, to: .mute) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var unlistedSeen: [String] {
        state.settings.seenNetworks
            .filter { state.settings.policy(forKeys: [$0]) == nil }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

private struct SSIDList: View {
    let entries: [String]
    var labels: [String: String] = [:]
    let remove: (String) -> Void

    var body: some View {
        if entries.isEmpty {
            Text("Empty").foregroundStyle(.secondary)
        } else {
            ForEach(entries, id: \.self) { ssid in
                HStack {
                    Text(NetworkIdentity.describe(key: ssid, labels: labels))
                    Spacer()
                    Button {
                        remove(ssid)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(ssid)")
                }
            }
        }
    }
}

private struct AddField: View {
    @Binding var text: String
    let placeholder: String
    let add: () -> Void

    var body: some View {
        HStack {
            TextField(placeholder, text: $text)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - Devices

private struct DevicesTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("This is what the room can hear") {
                Text("Mutify only acts when sound would come out of something the room can hear. Bluetooth headsets and headphones in the jack are left alone. Virtual and USB devices can't be judged from their type, so classify them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Devices I haven't classified", selection: $state.settings.unknownDeviceClass) {
                    Text("Treat as speakers (safer)").tag(OutputClass.speakers)
                    Text("Treat as private").tag(OutputClass.headphones)
                }
            }

            Section("Devices seen") {
                if state.settings.seenDevices.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                } else {
                    ForEach(devices, id: \.uid) { device in
                        DeviceRow(state: state, uid: device.uid, name: device.name)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var devices: [(uid: String, name: String)] {
        state.settings.seenDevices
            .map { (uid: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct DeviceRow: View {
    @Bindable var state: AppState
    let uid: String
    let name: String

    var body: some View {
        LabeledContent {
            Picker("", selection: binding) {
                Text("Automatic").tag(OutputClass.unknown)
                Text("Speakers").tag(OutputClass.speakers)
                Text("Private").tag(OutputClass.headphones)
            }
            .labelsHidden()
            .frame(width: 140)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                if state.output?.uid == uid {
                    Text("Current output").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var binding: Binding<OutputClass> {
        Binding(
            get: { state.settings.deviceClassOverrides[uid] ?? .unknown },
            set: { newValue in
                if newValue == .unknown {
                    state.settings.deviceClassOverrides.removeValue(forKey: uid)
                } else {
                    state.settings.deviceClassOverrides[uid] = newValue
                }
            }
        )
    }
}

// MARK: - Activity

private struct ActivityTab: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.activity.isEmpty {
                Spacer()
                Text("Nothing yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(state.activity) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.action.title).fontWeight(.medium)
                            Text("· \(entry.trigger.title)").foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.date, style: .time)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(entry.detail).font(.caption)
                        Text([entry.ssid, entry.device].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                Text("The full history is kept in ~/Library/Logs/Mutify.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.logFile])
                }
            }
            .padding(12)
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Mutify").font(.title.weight(.semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Everything stays on this Mac. Mutify makes no network requests, collects nothing, and stores your network names only in its own settings file.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
