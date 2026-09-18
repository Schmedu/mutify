import AppKit
import Foundation
import MutifyCore

/// Funnels every "something happened, look again" signal from the system into a
/// single callback: wake, unlock, session switches, and a periodic safety net.
@MainActor
final class TriggerHub {
    var onEvent: ((Trigger) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    func start() {
        stop()
        let workspace = NSWorkspace.shared.notificationCenter

        observe(workspace, NSWorkspace.didWakeNotification, .wake)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .wake)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .unlock)

        let distributed = DistributedNotificationCenter.default()
        let unlockToken = distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.unlock) }
        }
        observers.append(unlockToken)

        // Safety net in case an event is ever missed. 60s keeps it invisible in
        // Activity Monitor while bounding how long a wrong state can last.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.timer) }
        }
        RunLoop.main.add(timer, forMode: .common)
        timer.tolerance = 10
        self.timer = timer
    }

    func stop() {
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            workspace.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private func observe(_ center: NotificationCenter, _ name: NSNotification.Name, _ trigger: Trigger) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(trigger) }
        }
        observers.append(token)
    }
}
