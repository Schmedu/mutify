import AppKit
import Foundation

/// Tiny shim so non-UI files don't need to import AppKit.
enum NSWorkspaceOpener {
    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
