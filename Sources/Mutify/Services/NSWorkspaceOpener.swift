import AppKit
import Foundation

/// Tiny shim so non-UI files don't need to import AppKit.
enum NSWorkspaceOpener {
    @MainActor
    @discardableResult
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// Opens the first URL that works. System Settings pane identifiers have
    /// been renamed across macOS releases and the old ones simply fail.
    @MainActor
    @discardableResult
    static func openFirst(_ strings: [String]) -> Bool {
        for string in strings {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) { return true }
        }
        return false
    }
}
