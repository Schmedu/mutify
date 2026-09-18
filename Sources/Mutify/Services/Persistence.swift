import Foundation
import MutifyCore
import os

enum Paths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Mutify", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var stateFile: URL { supportDirectory.appendingPathComponent("state.json") }

    static var logDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Logs/Mutify", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var logFile: URL { logDirectory.appendingPathComponent("mutify.log") }
}

/// What Mutify remembers about a volume it lowered, so it can put it back.
struct MuteRecord: Codable, Equatable, Sendable {
    var deviceUID: String
    var previousVolume: Double
    var at: Date
}

struct PersistedState: Codable, Equatable, Sendable {
    var override: Override = .none
    /// Device UID → the volume Mutify lowered on it. One per device: muting the
    /// speakers and then a monitor must not lose the speakers' level.
    var muteRecords: [String: MuteRecord] = [:]

    init(override: Override = .none, muteRecords: [String: MuteRecord] = [:]) {
        self.override = override
        self.muteRecords = muteRecords
    }

    enum CodingKeys: String, CodingKey {
        case override, muteRecords, muteRecord
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        override = try c.decodeIfPresent(Override.self, forKey: .override) ?? .none
        if let records = try c.decodeIfPresent([String: MuteRecord].self, forKey: .muteRecords) {
            muteRecords = records
        } else if let single = try c.decodeIfPresent(MuteRecord.self, forKey: .muteRecord) {
            muteRecords = [single.deviceUID: single]
        } else {
            muteRecords = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(override, forKey: .override)
        try c.encode(muteRecords, forKey: .muteRecords)
    }
}

enum SettingsStore {
    static let log = Logger(subsystem: "com.schmedu.mutify", category: "settings")

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settingsFile) else { return Settings() }
        do {
            var settings = try JSONDecoder().decode(Settings.self, from: data)
            if settings.schemaVersion > Settings.currentSchemaVersion {
                // A newer version wrote this. Keep it safe instead of mangling it.
                backup(Paths.settingsFile)
                log.error("Settings file is from a newer version; starting from defaults")
                return Settings()
            }
            settings.schemaVersion = Settings.currentSchemaVersion
            return settings
        } catch {
            backup(Paths.settingsFile)
            log.error("Could not read settings (\(error.localizedDescription)); starting from defaults")
            return Settings()
        }
    }

    static func save(_ settings: Settings) {
        write(settings, to: Paths.settingsFile)
    }

    static func loadState() -> PersistedState {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    static func saveState(_ state: PersistedState) {
        write(state, to: Paths.stateFile)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func backup(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = url.deletingPathExtension().appendingPathExtension("\(stamp).bak.json")
        try? FileManager.default.moveItem(at: url, to: target)
    }
}

/// Keeps the last N decisions in memory for the Activity tab and appends every
/// one to a rotating file, so surprising behaviour can be explained after the fact.
@MainActor
final class ActivityLogger {
    private(set) var entries: [ActivityEntry] = []
    private let limit = 50
    private let maxFileBytes = 1_000_000

    init() {
        entries = []
    }

    func record(_ entry: ActivityEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        appendToFile(entry)
    }

    func clear() {
        entries.removeAll()
    }

    private func appendToFile(_ entry: ActivityEntry) {
        let url = Paths.logFile
        rotateIfNeeded(url)
        guard let data = (entry.logLine + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxFileBytes
        else { return }
        let archive = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: archive)
        try? FileManager.default.moveItem(at: url, to: archive)
    }
}
