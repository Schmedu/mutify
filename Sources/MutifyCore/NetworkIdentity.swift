import Foundation

/// How Mutify tells one network from another.
///
/// The obvious answer is the SSID, and macOS won't give it up without Location
/// access — it answers `<redacted>` instead, everywhere, to every tool. The
/// router's MAC address needs no permission at all, and is the better
/// identifier anyway: two cafés both called "FRITZ!Box" are two networks, and
/// this tells them apart.
public struct NetworkIdentity: Equatable, Sendable, Codable {
    /// The friendly name, when macOS is willing to say it.
    public var ssid: String?
    /// The default gateway's hardware address, lowercased.
    public var routerMAC: String?

    public init(ssid: String? = nil, routerMAC: String? = nil) {
        self.ssid = NetworkName.clean(ssid)
        self.routerMAC = routerMAC.map { $0.lowercased() }
    }

    public static func routerKey(_ mac: String) -> String { "router:\(mac.lowercased())" }

    /// Every identifier this network answers to.
    ///
    /// A network matches a list if *any* of its keys is on it. That's what keeps
    /// an entry added today — while only the router is known — working later,
    /// once Location access makes the name readable too.
    public var keys: [String] {
        var result: [String] = []
        if let ssid { result.append(ssid) }
        if let routerMAC { result.append(Self.routerKey(routerMAC)) }
        return result
    }

    /// What to store when this network is added to a list.
    public var primaryKey: String? { keys.first }

    public var isIdentifiable: Bool { !keys.isEmpty }

    public func displayName(labels: [String: String] = [:]) -> String {
        for key in keys {
            if let label = labels[key], !label.isEmpty { return label }
        }
        if let ssid { return ssid }
        if let routerMAC {
            return "Unnamed network (router …\(routerMAC.suffix(8)))"
        }
        return "Unknown network"
    }

    /// Pulls the hardware address out of an `arp -n` line, e.g.
    /// `? (192.168.1.1) at 3c:37:86:1a:2b:3c on en0 ifscope [ethernet]`.
    /// Returns nil for `(incomplete)` entries, which is what an unresolved
    /// neighbour looks like just after joining a network.
    public static func parseMAC(fromARP output: String) -> String? {
        guard let atRange = output.range(of: " at ") else { return nil }
        let rest = output[atRange.upperBound...]
        guard let field = rest.split(separator: " ").first else { return nil }
        let parts = String(field).lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }

        var octets: [String] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 2, part.allSatisfy(\.isHexDigit) else { return nil }
            // arp prints 1:2:3:a:b:c; pad so the key is always the same shape.
            octets.append(part.count == 1 ? "0\(part)" : String(part))
        }
        return octets.joined(separator: ":")
    }

    /// How a stored list entry should read in the UI.
    public static func describe(key: String, labels: [String: String] = [:]) -> String {
        if let label = labels[key], !label.isEmpty { return "\(label) (router …\(key.suffix(8)))" }
        guard key.hasPrefix("router:") else { return key }
        return "Unnamed network (router …\(key.suffix(8)))"
    }
}
