import Foundation

/// Why the current decision is what it is. Every mute event can explain itself.
public enum Reason: Equatable, Sendable {
    case paused
    case setupIncomplete
    case overrideUntil(Date)
    case overrideIndefinite
    case overrideUntilNetworkChange(ssid: String)
    case placeUnavailable
    case noOutputDevice
    case outputIsPrivate(device: String)
    case ssidAllowListed(String)
    case ssidMuteListed(String)
    case ssidUnlisted(String)
    case noWiFi
}

public struct PolicyResult: Equatable, Sendable {
    public var decision: Decision
    /// False when Mutify is deliberately standing down: paused, overridden, or
    /// unable to tell where it is.
    public var enforcing: Bool
    public var reason: Reason
    public var outputClass: OutputClass?

    public init(decision: Decision, enforcing: Bool, reason: Reason, outputClass: OutputClass? = nil) {
        self.decision = decision
        self.enforcing = enforcing
        self.reason = reason
        self.outputClass = outputClass
    }

    /// True only when Mutify itself is holding the volume down.
    public var isMuting: Bool { enforcing && decision == .mute }

    /// Whether a volume Mutify lowered may be put back now.
    ///
    /// Being allowed only because headphones are plugged in does not count: the
    /// speakers are still somewhere they have to stay quiet, and raising them
    /// would arm a trap for the moment the headphones come out.
    public var permitsRestore: Bool {
        guard decision == .allow else { return false }
        if case .outputIsPrivate = reason { return false }
        return true
    }
}

/// The whole decision, as a pure function. No I/O lives here on purpose: every
/// scenario in the PRD is a unit test that needs no Wi-Fi, café or headphones.
public enum PolicyEngine {

    /// What the device looks like before the user's own classification is applied.
    public static func heuristicClass(_ output: OutputContext) -> OutputClass {
        switch output.transport {
        case .builtIn:
            return output.isHeadphoneDataSource ? .headphones : .speakers
        case .bluetooth:
            // Usually AirPods or a headset. A Bluetooth speaker is the exception
            // and is what the per-device override exists for.
            return .headphones
        case .hdmi, .displayPort, .airPlay:
            return .speakers
        case .usb, .virtual, .aggregate, .thunderbolt, .other:
            return .unknown
        }
    }

    /// The classification actually used, after user overrides and the
    /// unclassified-device default.
    public static func resolvedClass(_ output: OutputContext, settings: Settings) -> OutputClass {
        if let override = settings.deviceClassOverrides[output.uid], override != .unknown {
            return override
        }
        let heuristic = heuristicClass(output)
        if heuristic == .unknown {
            return settings.unknownDeviceClass == .unknown ? .speakers : settings.unknownDeviceClass
        }
        return heuristic
    }

    public static func evaluate(
        place: PlaceSignal,
        output: OutputContext?,
        settings: Settings,
        override: Override,
        now: Date
    ) -> PolicyResult {
        // 1. Master switch.
        guard settings.masterEnabled else {
            return PolicyResult(decision: .allow, enforcing: false, reason: .paused)
        }

        // 2. Until the user has said where home is, muting would be guesswork.
        guard settings.hasCompletedOnboarding else {
            return PolicyResult(decision: .allow, enforcing: false, reason: .setupIncomplete)
        }

        // 3. A running override beats everything below it.
        if override.isActive(now: now, place: place) {
            let reason: Reason
            switch override {
            case .until(let date): reason = .overrideUntil(date)
            case .indefinite: reason = .overrideIndefinite
            case .untilNetworkChange(let ssid): reason = .overrideUntilNetworkChange(ssid: ssid)
            case .none: reason = .paused
            }
            return PolicyResult(decision: .allow, enforcing: false, reason: reason)
        }

        // 4. Not knowing where we are is different from being somewhere unlisted.
        //    Muting everything because a permission is missing would feel broken,
        //    so stand down loudly instead.
        if place == .unavailable {
            return PolicyResult(decision: .allow, enforcing: false, reason: .placeUnavailable)
        }

        guard let output else {
            return PolicyResult(decision: .allow, enforcing: false, reason: .noOutputDevice)
        }

        // 5. Nothing to enforce if the room can't hear it anyway.
        let outputClass = resolvedClass(output, settings: settings)
        guard outputClass == .speakers else {
            return PolicyResult(
                decision: .allow,
                enforcing: true,
                reason: .outputIsPrivate(device: output.name),
                outputClass: outputClass
            )
        }

        // 6. The place decides. Deny wins.
        switch place {
        case .wifi(let ssid):
            switch settings.policy(forSSID: ssid) {
            case .mute:
                return PolicyResult(decision: .mute, enforcing: true, reason: .ssidMuteListed(ssid), outputClass: outputClass)
            case .allow:
                return PolicyResult(decision: .allow, enforcing: true, reason: .ssidAllowListed(ssid), outputClass: outputClass)
            case nil:
                return PolicyResult(
                    decision: settings.unknownNetworkPolicy == .mute ? .mute : .allow,
                    enforcing: true,
                    reason: .ssidUnlisted(ssid),
                    outputClass: outputClass
                )
            }
        case .noWiFi:
            return PolicyResult(
                decision: settings.unknownNetworkPolicy == .mute ? .mute : .allow,
                enforcing: true,
                reason: .noWiFi,
                outputClass: outputClass
            )
        case .unavailable:
            return PolicyResult(decision: .allow, enforcing: false, reason: .placeUnavailable)
        }
    }
}

// MARK: - Human-readable reasons

extension Reason {
    /// The line at the top of the menu. Plain language, no jargon.
    public func headline(decision: Decision) -> String {
        switch self {
        case .paused:
            return "Mutify is paused"
        case .setupIncomplete:
            return "Not set up yet — nothing is being muted"
        case .overrideUntil(let date):
            return "Sound allowed until \(Reason.timeFormatter.string(from: date))"
        case .overrideIndefinite:
            return "Sound allowed until you switch Mutify back on"
        case .overrideUntilNetworkChange(let ssid):
            return "Sound allowed while you're on “\(ssid)”"
        case .placeUnavailable:
            return "Standing down — can't tell which network you're on"
        case .noOutputDevice:
            return "Standing down — no audio output device"
        case .outputIsPrivate(let device):
            return "Sound allowed — \(device) is private"
        case .ssidAllowListed(let ssid):
            return "Sound allowed — “\(ssid)” is on your allow list"
        case .ssidMuteListed(let ssid):
            return "Muted — “\(ssid)” is on your mute list"
        case .ssidUnlisted(let ssid):
            return decision == .mute
                ? "Muted — “\(ssid)” isn't on your allow list"
                : "Sound allowed — “\(ssid)” isn't on your mute list"
        case .noWiFi:
            return decision == .mute
                ? "Muted — not on a known Wi-Fi network"
                : "Sound allowed — not on a known Wi-Fi network"
        }
    }

    /// Short form for the activity log and notifications.
    public var shortDescription: String {
        switch self {
        case .paused: return "paused"
        case .setupIncomplete: return "setup not finished"
        case .overrideUntil(let date): return "override until \(Reason.timeFormatter.string(from: date))"
        case .overrideIndefinite: return "override, indefinite"
        case .overrideUntilNetworkChange(let ssid): return "override while on \(ssid)"
        case .placeUnavailable: return "network unknown"
        case .noOutputDevice: return "no output device"
        case .outputIsPrivate(let device): return "\(device) is private"
        case .ssidAllowListed(let ssid): return "\(ssid) allow-listed"
        case .ssidMuteListed(let ssid): return "\(ssid) mute-listed"
        case .ssidUnlisted(let ssid): return "\(ssid) unlisted"
        case .noWiFi: return "no Wi-Fi"
        }
    }

    public static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
