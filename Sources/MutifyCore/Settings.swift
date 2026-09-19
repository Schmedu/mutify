import Foundation

/// Everything the user can configure. Persisted as JSON; decoding is tolerant of
/// missing keys so an older settings file keeps working after an update.
public struct Settings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var masterEnabled: Bool
    public var enforcementMode: EnforcementMode
    /// Applied to networks on neither list, and when there is no Wi-Fi at all.
    public var unknownNetworkPolicy: PlacePolicy
    /// Applied to output devices the heuristics can't classify.
    public var unknownDeviceClass: OutputClass
    public var allowList: [String]
    public var muteList: [String]
    /// Device UID → user's classification. Beats the heuristics.
    public var deviceClassOverrides: [String: OutputClass]
    public var restoreVolume: Bool
    /// 0...1, or nil for "restore exactly what it was".
    public var restoreCap: Double?
    public var notifyOnMute: Bool
    /// Network keys seen before, so lists can be built without being there.
    public var seenNetworks: [String]
    /// Network key → a name the user gave it. Matters for networks identified
    /// only by their router, which have no name of their own.
    public var networkLabels: [String: String]
    /// Device UID → last known name, for the Devices tab.
    public var seenDevices: [String: String]
    public var hasCompletedOnboarding: Bool
    /// The menu bar icon is Mutify's only visible surface, so it's on by
    /// default — but it's a spot in a crowded bar, and the app runs just as
    /// well without it. Opening Mutify again brings the window back.
    public var showMenuBarIcon: Bool

    public init(
        schemaVersion: Int = Settings.currentSchemaVersion,
        masterEnabled: Bool = true,
        enforcementMode: EnforcementMode = .onChange,
        unknownNetworkPolicy: PlacePolicy = .mute,
        unknownDeviceClass: OutputClass = .speakers,
        allowList: [String] = [],
        muteList: [String] = [],
        deviceClassOverrides: [String: OutputClass] = [:],
        restoreVolume: Bool = true,
        restoreCap: Double? = nil,
        notifyOnMute: Bool = true,
        seenNetworks: [String] = [],
        networkLabels: [String: String] = [:],
        seenDevices: [String: String] = [:],
        hasCompletedOnboarding: Bool = false,
        showMenuBarIcon: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.masterEnabled = masterEnabled
        self.enforcementMode = enforcementMode
        self.unknownNetworkPolicy = unknownNetworkPolicy
        self.unknownDeviceClass = unknownDeviceClass
        self.allowList = allowList
        self.muteList = muteList
        self.deviceClassOverrides = deviceClassOverrides
        self.restoreVolume = restoreVolume
        self.restoreCap = restoreCap
        self.notifyOnMute = notifyOnMute
        self.seenNetworks = seenNetworks
        self.networkLabels = networkLabels
        self.seenDevices = seenDevices
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.showMenuBarIcon = showMenuBarIcon
    }

    // Hand-written so that a key added in a future version — or removed in an
    // older one — never makes the whole file unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        masterEnabled = try c.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? d.masterEnabled
        enforcementMode = try c.decodeIfPresent(EnforcementMode.self, forKey: .enforcementMode) ?? d.enforcementMode
        unknownNetworkPolicy = try c.decodeIfPresent(PlacePolicy.self, forKey: .unknownNetworkPolicy) ?? d.unknownNetworkPolicy
        unknownDeviceClass = try c.decodeIfPresent(OutputClass.self, forKey: .unknownDeviceClass) ?? d.unknownDeviceClass
        allowList = try c.decodeIfPresent([String].self, forKey: .allowList) ?? d.allowList
        muteList = try c.decodeIfPresent([String].self, forKey: .muteList) ?? d.muteList
        deviceClassOverrides = try c.decodeIfPresent([String: OutputClass].self, forKey: .deviceClassOverrides) ?? d.deviceClassOverrides
        restoreVolume = try c.decodeIfPresent(Bool.self, forKey: .restoreVolume) ?? d.restoreVolume
        restoreCap = try c.decodeIfPresent(Double.self, forKey: .restoreCap)
        notifyOnMute = try c.decodeIfPresent(Bool.self, forKey: .notifyOnMute) ?? d.notifyOnMute
        seenNetworks = try c.decodeIfPresent([String].self, forKey: .seenNetworks) ?? d.seenNetworks
        networkLabels = try c.decodeIfPresent([String: String].self, forKey: .networkLabels) ?? d.networkLabels
        seenDevices = try c.decodeIfPresent([String: String].self, forKey: .seenDevices) ?? d.seenDevices
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? d.showMenuBarIcon
    }

    // MARK: - List helpers

    public static func normalized(_ ssid: String) -> String {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func list(_ list: [String], contains key: String) -> Bool {
        let needle = normalized(key)
        guard !needle.isEmpty else { return false }
        return list.contains { normalized($0).caseInsensitiveCompare(needle) == .orderedSame }
    }

    public static func list(_ list: [String], containsAny keys: [String]) -> Bool {
        keys.contains { Settings.list(list, contains: $0) }
    }

    public mutating func add(_ key: String, to policy: PlacePolicy) {
        let value = Settings.normalized(key)
        guard !value.isEmpty, !NetworkName.isPlaceholder(value) else { return }
        remove(key)
        switch policy {
        case .allow: allowList.append(value)
        case .mute: muteList.append(value)
        }
        allowList.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        muteList.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Adds every way this network can be recognised, so the entry survives
    /// macOS starting — or stopping — to reveal the name.
    public mutating func add(_ identity: NetworkIdentity, to policy: PlacePolicy) {
        for key in identity.keys { add(key, to: policy) }
    }

    public mutating func remove(_ ssid: String) {
        let value = Settings.normalized(ssid)
        allowList.removeAll { Settings.normalized($0).caseInsensitiveCompare(value) == .orderedSame }
        muteList.removeAll { Settings.normalized($0).caseInsensitiveCompare(value) == .orderedSame }
    }

    /// Which list a single key is on, if any.
    public func policy(forSSID ssid: String) -> PlacePolicy? {
        policy(forKeys: [ssid])
    }

    /// Which list a network is on, if any. Deny wins.
    public func policy(forKeys keys: [String]) -> PlacePolicy? {
        if Settings.list(muteList, containsAny: keys) { return .mute }
        if Settings.list(allowList, containsAny: keys) { return .allow }
        return nil
    }

    public func policy(for identity: NetworkIdentity) -> PlacePolicy? {
        policy(forKeys: identity.keys)
    }

    public mutating func noteSeen(ssid: String) {
        let value = Settings.normalized(ssid)
        guard !value.isEmpty, !NetworkName.isPlaceholder(value),
              !Settings.list(seenNetworks, contains: value) else { return }
        seenNetworks.append(value)
        if seenNetworks.count > 50 { seenNetworks.removeFirst(seenNetworks.count - 50) }
    }

    public mutating func noteSeen(network: NetworkIdentity) {
        for key in network.keys { noteSeen(ssid: key) }
    }

    /// True when any of this network's keys is new to us.
    public func isUnseen(_ network: NetworkIdentity) -> Bool {
        network.keys.contains { !Settings.list(seenNetworks, contains: $0) }
    }

    public mutating func noteSeen(device: OutputContext) {
        seenDevices[device.uid] = device.name
    }
}
