import Foundation

/// Guards against macOS's own placeholders being mistaken for network names.
///
/// Without Location authorization macOS doesn't fail the lookup — it answers
/// with the literal string `<redacted>`, from CoreWLAN and from
/// `ipconfig getsummary` alike. Storing that as an SSID would be worse than
/// having no name at all: allow-listing it would silently allow-list every
/// network whose name we can't read.
public enum NetworkName {
    static let placeholders: Set<String> = [
        "<redacted>",
        "<removed>",
        "<private>",
        "redacted",
        "unknown ssid",
    ]

    /// Returns a usable network name, or nil when there isn't one.
    public static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !placeholders.contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    /// True when the name is one macOS hands out in place of the real one.
    public static func isPlaceholder(_ raw: String) -> Bool {
        placeholders.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
