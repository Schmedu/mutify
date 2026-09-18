import Foundation
import MutifyCore
import UserNotifications

/// Mute notices with a one-click way out. Only available when running as a real
/// bundled app — from a bare binary UNUserNotificationCenter has no bundle to
/// attach to.
@MainActor
final class NotificationService: NSObject {
    static let allowThirtyAction = "MUTIFY_ALLOW_30"
    static let muteCategory = "MUTIFY_MUTED"

    var onAllowThirtyMinutes: (() -> Void)?

    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
    private var isAuthorized = false

    func configure() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(
            identifier: Self.allowThirtyAction,
            title: "Allow sound for 30 minutes",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.muteCategory,
            actions: [action],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor [weak self] in self?.isAuthorized = granted }
        }
    }

    func postMuted(reason: String, device: String) {
        guard isAvailable, isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Sound muted"
        content.body = "\(reason). Output is \(device)."
        content.categoryIdentifier = Self.muteCategory
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.actionIdentifier
        Task { @MainActor [weak self] in
            if identifier == NotificationService.allowThirtyAction {
                self?.onAllowThirtyMinutes?()
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
