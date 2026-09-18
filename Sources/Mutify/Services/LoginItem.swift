import Foundation
import ServiceManagement
import os

/// Launch at login, via the modern SMAppService path.
enum LoginItem {
    private static let log = Logger(subsystem: "com.schmedu.mutify", category: "loginitem")

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns the state actually achieved, which can differ from what was asked
    /// when the user has to approve it in System Settings first.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isAvailable else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription)")
        }
        return SMAppService.mainApp.status == .enabled
    }
}
