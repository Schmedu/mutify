import Foundation

/// What a place says about whether sound may play.
public enum PlacePolicy: String, Codable, CaseIterable, Sendable {
    case allow
    case mute
}

/// How hard Mutify holds the volume down while a mute decision stands.
public enum EnforcementMode: String, Codable, CaseIterable, Sendable {
    /// Mute on events (network change, output change, wake, launch). A volume the
    /// user raises by hand is respected until the next event.
    case onChange
    /// Additionally re-mute whenever the volume goes back up.
    case strict

    public var title: String {
        switch self {
        case .onChange: return "Mute on changes"
        case .strict: return "Keep muted (strict)"
        }
    }

    public var explanation: String {
        switch self {
        case .onChange:
            return "Mutes when the network, the output device or the wake state changes. If you turn the volume back up yourself, Mutify leaves it alone until the next change."
        case .strict:
            return "Also turns the volume back down whenever it goes up. Use “Allow sound…” when you need sound on purpose."
        }
    }
}

/// Whether the room can hear what the Mac plays.
public enum OutputClass: String, Codable, CaseIterable, Sendable {
    /// Audible to everyone around — built-in speakers, a monitor, a desk speaker.
    case speakers
    /// Private — headphones, earbuds, a headset.
    case headphones
    /// Can't tell from the device alone (virtual devices, USB interfaces).
    case unknown

    public var title: String {
        switch self {
        case .speakers: return "Speakers (room hears it)"
        case .headphones: return "Headphones (private)"
        case .unknown: return "Not classified"
        }
    }
}

/// Coarse CoreAudio transport, mapped away from the raw four-char codes.
public enum TransportKind: String, Codable, Sendable {
    case builtIn
    case bluetooth
    case usb
    case hdmi
    case displayPort
    case airPlay
    case virtual
    case aggregate
    case thunderbolt
    case other
}

/// Everything the policy needs to know about the current default output device.
public struct OutputContext: Equatable, Sendable, Codable {
    public var uid: String
    public var name: String
    public var transport: TransportKind
    /// Built-in devices keep the `builtIn` transport when headphones are in the
    /// jack; only the data source changes. Without this, wired headphones get muted.
    public var isHeadphoneDataSource: Bool

    public init(uid: String, name: String, transport: TransportKind, isHeadphoneDataSource: Bool = false) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.isHeadphoneDataSource = isHeadphoneDataSource
    }
}

/// Where we are, as far as we can tell.
public enum PlaceSignal: Equatable, Sendable {
    /// Associated with a Wi-Fi network whose name we could read.
    case wifi(ssid: String)
    /// Definitely not on Wi-Fi: Ethernet only, Wi-Fi off, or offline.
    case noWiFi
    /// Associated with *something* we can't name — almost always a missing
    /// Location permission. Deliberately different from `noWiFi`.
    case unavailable

    public var ssid: String? {
        if case .wifi(let ssid) = self { return ssid }
        return nil
    }
}

public enum Decision: String, Equatable, Sendable {
    case mute
    case allow
}

/// A user-initiated suspension of enforcement.
public enum Override: Equatable, Sendable, Codable {
    case none
    /// Sound allowed until this moment.
    case until(Date)
    /// Master switch off until switched back on.
    case indefinite
    /// Sound allowed until the Mac joins a different network.
    case untilNetworkChange(ssid: String)

    public func isActive(now: Date, place: PlaceSignal) -> Bool {
        switch self {
        case .none:
            return false
        case .until(let date):
            return now < date
        case .indefinite:
            return true
        case .untilNetworkChange(let ssid):
            // Still on the same network → still active. Anything else ends it,
            // including losing Wi-Fi entirely.
            return place.ssid?.caseInsensitiveCompare(ssid) == .orderedSame
        }
    }

    public var expiry: Date? {
        if case .until(let date) = self { return date }
        return nil
    }
}
