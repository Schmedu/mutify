import CoreAudio
import Foundation
import MutifyCore

/// `Mutify --probe` prints exactly what Mutify can see: the network, every
/// output device, how each one is classified, and what the policy would decide.
/// `--probe-write <name>` additionally round-trips one device's volume, which is
/// the quickest way to find out whether a device accepts being turned down.
@MainActor
enum Probe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("--probe")
            || arguments.contains("--probe-write")
            || arguments.contains("--probe-as")
    }

    static func run(_ arguments: [String]) {
        let settings = SettingsStore.load()
        let state = SettingsStore.loadState()
        let places = PlaceMonitor()
        let place = places.currentPlace()
        let audio = AudioController()

        print("Mutify diagnostics")
        print(String(repeating: "─", count: 52))

        print("Place")
        switch place {
        case .network(let identity):
            let policy = settings.policy(for: identity).map(\.rawValue)
                ?? "unlisted → \(settings.unknownNetworkPolicy.rawValue)"
            print("  \(identity.displayName(labels: settings.networkLabels))  [\(policy)]")
            print("  name: \(identity.ssid ?? "not readable without Location access")")
            print("  router: \(identity.routerMAC ?? "unknown")")
            print("  matches list entries: \(identity.keys.joined(separator: ", "))")
        case .noWiFi:
            print("  No network → \(settings.unknownNetworkPolicy.rawValue)")
        case .unavailable:
            print("  On a network, but nothing identifies it")
        }
        print("  Location authorization: \(places.authorizationDescription)")

        print("\nOutput devices")
        let defaultDevice = AudioController.defaultOutputDevice()
        for device in AudioController.allOutputDevices() {
            let context = AudioController.describe(device)
            let resolved = PolicyEngine.resolvedClass(context, settings: settings)
            let heuristic = PolicyEngine.heuristicClass(context)
            let marker = device == defaultDevice ? "▶" : " "
            let volume = AudioController.volume(device).map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a"
            let muted = AudioController.muted(device).map { $0 ? "muted" : "unmuted" } ?? "no mute control"
            print("  \(marker) \(context.name)")
            print("      transport \(context.transport.rawValue), \(heuristic.rawValue) → \(resolved.rawValue)")
            print("      volume \(volume), \(muted)")
            if let source = AudioController.dataSourceName(device) {
                print("      data source: \(source)")
            }
            print("      uid: \(context.uid)")
        }

        print("\nDecision")
        let result = PolicyEngine.evaluate(
            place: place,
            output: audio.currentOutput,
            settings: settings,
            override: state.override,
            now: Date()
        )
        print("  \(result.decision.rawValue), enforcing: \(result.enforcing)")
        print("  \(result.reason.headline(decision: result.decision))")
        for record in state.muteRecords.values.sorted(by: { $0.deviceUID < $1.deviceUID }) {
            print("  Remembered volume: \(Int((record.previousVolume * 100).rounded()))% on \(record.deviceUID)")
        }

        if let index = arguments.firstIndex(of: "--probe-as"), index + 1 < arguments.count {
            whatIf(matching: arguments[index + 1], place: place, settings: settings, override: state.override)
        }

        if let index = arguments.firstIndex(of: "--probe-write"), index + 1 < arguments.count {
            roundTrip(matching: arguments[index + 1], defaultDevice: defaultDevice)
        }
    }

    /// Answers "what happens when my headphones die?" without changing anything.
    private static func whatIf(matching needle: String, place: PlaceSignal, settings: Settings, override: Override) {
        print("\nIf the output were…")
        let matches = AudioController.allOutputDevices()
            .map(AudioController.describe)
            .filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.uid.localizedCaseInsensitiveContains(needle) }
        guard let context = matches.first else {
            print("  No device matching “\(needle)”")
            return
        }
        let result = PolicyEngine.evaluate(
            place: place, output: context, settings: settings, override: override, now: Date()
        )
        print("  \(context.name): \(result.decision.rawValue), enforcing: \(result.enforcing)")
        print("  \(result.reason.headline(decision: result.decision))")
    }

    /// Proves a device really accepts being turned down — and puts it back.
    private static func roundTrip(matching needle: String, defaultDevice: AudioObjectID?) {
        print("\nVolume round-trip")
        let matches = AudioController.allOutputDevices().filter { device in
            let context = AudioController.describe(device)
            return context.name.localizedCaseInsensitiveContains(needle)
                || context.uid.localizedCaseInsensitiveContains(needle)
        }
        guard let device = matches.first else {
            print("  No device matching “\(needle)”")
            return
        }

        let context = AudioController.describe(device)
        if device == defaultDevice {
            print("  ⚠︎ \(context.name) is the current output — anything playing will go quiet for a moment.")
        }
        guard let before = AudioController.volume(device) else {
            print("  \(context.name) exposes no volume control")
            return
        }

        AudioController.setVolume(device, 0)
        AudioController.setMuted(device, true)
        let silenced = AudioController.volume(device) ?? -1
        let mutedFlag = AudioController.muted(device)

        AudioController.setMuted(device, false)
        AudioController.setVolume(device, before)
        let after = AudioController.volume(device) ?? -1

        print("  \(context.name)")
        print("  before \(percent(before)) → silenced \(percent(silenced)) (mute flag: \(mutedFlag.map(String.init(describing:)) ?? "n/a")) → restored \(percent(after))")
        let ok = silenced <= 0.0001 && abs(after - before) < 0.01
        print("  \(ok ? "✓ this device can be muted and restored" : "✗ device did not behave as expected")")
    }

    private static func percent(_ value: Double) -> String {
        value < 0 ? "n/a" : "\(Int((value * 100).rounded()))%"
    }
}
