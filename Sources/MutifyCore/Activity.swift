import Foundation

/// What caused a re-evaluation. Also decides whether a mute may be *applied*:
/// in `onChange` mode a volume change never triggers a re-mute.
public enum Trigger: String, Codable, Sendable {
    case launch
    case networkChange
    case outputDeviceChange
    case wake
    case unlock
    case volumeChange
    case settingsChange
    case userAction
    case timer
    case retry

    public var title: String {
        switch self {
        case .launch: return "Launch"
        case .networkChange: return "Network changed"
        case .outputDeviceChange: return "Output changed"
        case .wake: return "Wake"
        case .unlock: return "Unlock"
        case .volumeChange: return "Volume changed"
        case .settingsChange: return "Settings changed"
        case .userAction: return "You"
        case .timer: return "Periodic check"
        case .retry: return "Retry after wake"
        }
    }

    /// `onChange` mode ignores volume changes; strict mode acts on them too.
    public func permitsMuting(mode: EnforcementMode) -> Bool {
        guard self == .volumeChange else { return true }
        return mode == .strict
    }
}

public enum ActivityAction: String, Codable, Sendable {
    case muted
    case restored
    case noChange
    case standDown

    public var title: String {
        switch self {
        case .muted: return "Muted"
        case .restored: return "Restored volume"
        case .noChange: return "No change"
        case .standDown: return "Stood down"
        }
    }
}

public struct ActivityEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var date: Date
    public var trigger: Trigger
    public var action: ActivityAction
    public var ssid: String?
    public var device: String?
    public var detail: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        trigger: Trigger,
        action: ActivityAction,
        ssid: String?,
        device: String?,
        detail: String
    ) {
        self.id = id
        self.date = date
        self.trigger = trigger
        self.action = action
        self.ssid = ssid
        self.device = device
        self.detail = detail
    }

    public var logLine: String {
        let stamp = ISO8601DateFormatter().string(from: date)
        return "\(stamp)\t\(trigger.rawValue)\t\(action.rawValue)\tssid=\(ssid ?? "-")\tdevice=\(device ?? "-")\t\(detail)"
    }
}

/// The "Allow sound for…" menu items.
public enum OverrideOption: String, CaseIterable, Sendable, Identifiable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case untilTomorrow
    case untilNetworkChange

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fifteenMinutes: return "Allow sound for 15 minutes"
        case .thirtyMinutes: return "Allow sound for 30 minutes"
        case .oneHour: return "Allow sound for 1 hour"
        case .untilTomorrow: return "Allow sound until tomorrow morning"
        case .untilNetworkChange: return "Allow sound until I leave this network"
        }
    }

    /// Builds the concrete override. `nil` when the option doesn't apply — e.g.
    /// "until I leave this network" with no network to leave.
    public func makeOverride(now: Date, place: PlaceSignal, calendar: Calendar = .current) -> Override? {
        switch self {
        case .fifteenMinutes: return .until(now.addingTimeInterval(15 * 60))
        case .thirtyMinutes: return .until(now.addingTimeInterval(30 * 60))
        case .oneHour: return .until(now.addingTimeInterval(60 * 60))
        case .untilTomorrow:
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = 7
            components.minute = 0
            guard let todayAtSeven = calendar.date(from: components) else { return nil }
            let target = todayAtSeven > now ? todayAtSeven : calendar.date(byAdding: .day, value: 1, to: todayAtSeven)
            return target.map { Override.until($0) }
        case .untilNetworkChange:
            guard let key = place.identity?.primaryKey else { return nil }
            return .untilNetworkChange(key: key)
        }
    }
}
