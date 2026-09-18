import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import MutifyCore
import Network

/// Answers "where am I?" — today that means the Wi-Fi network name.
///
/// Reading the SSID needs Location Services authorization on macOS 14 and later,
/// and there is no way around it: without the grant, CoreWLAN returns nil and
/// `ipconfig getsummary` answers with the literal string `<redacted>`. Mutify
/// treats both as "unknown" and stands down rather than guessing.
@MainActor
final class PlaceMonitor: NSObject {

    var onEvent: ((Trigger) -> Void)?

    private let wifiClient = CWWiFiClient.shared()
    /// Created on first use, never during app start-up: a CLLocationManager
    /// built before NSApplication has finished launching never connects to
    /// locationd, and then authorization requests vanish without a prompt.
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    private var pathMonitor: NWPathMonitor?
    private var pathUsesWiFi = false
    private var cachedSnapshot: (value: NetworkSnapshot, at: Date)?
    private var pathHasNetwork = false
    private var locationBurstTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// Set when macOS refuses a request without showing anything, which happens
    /// when an earlier prompt is still outstanding somewhere.
    private(set) var promptSeemsStuck = false

    /// Reads the live status, creating the manager if this is the first ask.
    func refreshAuthorizationStatus() {
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Current place

    func currentPlace() -> PlaceSignal {
        let snapshot = networkSnapshot()
        let identity = NetworkIdentity(ssid: snapshot.ssid, routerMAC: snapshot.routerMAC)
        if identity.isIdentifiable { return .network(identity) }

        // Nothing to go on. Say which kind of nothing it is: being on a network
        // we can't identify is not the same as being on none.
        guard let interface = wifiClient.interface(), interface.powerOn() else {
            return pathHasNetwork ? .unavailable : .noWiFi
        }
        let associated = interface.interfaceMode() != .none || pathUsesWiFi
        return associated ? .unavailable : .noWiFi
    }

    private struct NetworkSnapshot {
        var ssid: String?
        var routerMAC: String?
    }

    /// Both lookups are cheap but not free; a few seconds of cache covers the
    /// bursts of events that arrive when a network changes.
    private func networkSnapshot() -> NetworkSnapshot {
        if let cached = cachedSnapshot, Date().timeIntervalSince(cached.at) < 5 {
            return cached.value
        }
        let snapshot = NetworkSnapshot(ssid: readSSID(), routerMAC: Self.defaultGatewayMAC())
        cachedSnapshot = (snapshot, Date())
        return snapshot
    }

    /// The network name, if macOS is willing to say. It only is with Location
    /// access — CoreWLAN returns nil without it and `ipconfig` answers
    /// `<redacted>`, so both go through the same sanitiser.
    private func readSSID() -> String? {
        guard let interface = wifiClient.interface(), interface.powerOn() else { return nil }
        if let ssid = NetworkName.clean(interface.ssid()) { return ssid }
        return NetworkName.clean(Self.runIPConfig(interface: interface.interfaceName ?? "en0"))
    }

    /// The Wi-Fi networks this Mac has saved.
    ///
    /// `networksetup` still answers this one honestly without Location access —
    /// it just won't say which of them you're on. Good enough to let someone
    /// name a network from a list of real names instead of typing it.
    static func preferredNetworkNames(interface: String = "en0") -> [String] {
        guard let output = run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", interface]) else {
            return []
        }
        return output
            .split(separator: "\n")
            .dropFirst()  // "Preferred networks on en0:"
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { NetworkName.clean($0) }
    }

    /// The default gateway's hardware address: no permission, no prompt, and it
    /// tells apart two networks that share a name.
    static func defaultGatewayMAC() -> String? {
        guard let route = run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        var gateway: String?
        for line in route.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "gateway" else { continue }
            gateway = parts[1].trimmingCharacters(in: .whitespaces)
            break
        }
        guard let gateway, !gateway.isEmpty else { return nil }

        guard let arp = run("/usr/sbin/arp", ["-n", gateway]) else { return nil }
        return NetworkIdentity.parseMAC(fromARP: arp)
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func runIPConfig(interface: String) -> String? {
        guard let output = run("/usr/sbin/ipconfig", ["getsummary", interface]) else { return nil }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SSID :") else { continue }
            return NetworkName.clean(String(trimmed.dropFirst("SSID :".count)))
        }
        return nil
    }

    // MARK: - Monitoring

    func start() {
        wifiClient.delegate = self
        for event in [CWEventType.ssidDidChange, .linkDidChange, .powerDidChange, .bssidDidChange] {
            try? wifiClient.startMonitoringEvent(with: event)
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let usesWiFi = path.usesInterfaceType(.wifi)
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pathUsesWiFi = usesWiFi
                self.pathHasNetwork = satisfied
                self.cachedSnapshot = nil
                self.onEvent?(.networkChange)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.schmedu.mutify.path"))
        pathMonitor = monitor
    }

    func stop() {
        try? wifiClient.stopMonitoringAllEvents()
        pathMonitor?.cancel()
        pathMonitor = nil
        locationBurstTask?.cancel()
        clearActivationObserver()
    }

    private func handleWiFiEvent() {
        cachedSnapshot = nil
        onEvent?(.networkChange)
    }

    // MARK: - Location permission

    /// Distinguishes "never asked" from "asked and refused" — they need
    /// different things from the user.
    var authorizationDescription: String {
        switch authorizationStatus {
        case .notDetermined: return "not asked yet"
        case .restricted: return "restricted by policy"
        case .denied: return "denied — must be changed in System Settings"
        case .authorizedAlways: return "granted"
        @unknown default: return "unknown (\(authorizationStatus.rawValue))"
        }
    }

    var canPrompt: Bool { authorizationStatus == .notDetermined }

    var needsLocationPermission: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorized: return false
        default: return true
        }
    }

    /// Asks for Location access — but only while the app is actually active.
    /// macOS silently drops the prompt otherwise, which looks exactly like the
    /// request never happening.
    func requestLocationPermission() {
        guard canPrompt else {
            // Already answered once: only System Settings can change it now.
            openLocationSettings()
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)

        if NSApplication.shared.isActive {
            performLocationRequest()
        } else {
            waitForActivation()
        }
    }

    private func waitForActivation() {
        guard activationObserver == nil else { return }
        Self.trace("app not active yet; waiting for activation")
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clearActivationObserver()
                self.performLocationRequest()
            }
        }
    }

    private func clearActivationObserver() {
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
            activationObserver = nil
        }
    }

    private func performLocationRequest() {
        promptSeemsStuck = false
        Self.trace("requesting: status=\(locationManager.authorizationStatus.rawValue) servicesEnabled=\(CLLocationManager.locationServicesEnabled()) active=\(NSApp.isActive)")
        locationManager.requestAlwaysAuthorization()
        // Asking alone doesn't always surface the prompt for a background-only
        // app; a short location burst does, and costs nothing.
        locationBurstTask?.cancel()
        locationBurstTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            self.locationManager.startUpdatingLocation()
            try? await Task.sleep(for: .seconds(3))
            self.locationManager.stopUpdatingLocation()
        }
    }

    nonisolated static func trace(_ message: String) {
        let line = "[location] \(Date()) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        // Also to disk: launched through LaunchServices there is no stderr to read.
        let url = Paths.logDirectory.appendingPathComponent("debug.log")
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    func openLocationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
        NSWorkspaceOpener.open(url)
    }
}

// MARK: - CoreWLAN events (delivered off the main actor)

extension PlaceMonitor: CWEventDelegate {
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.handleWiFiEvent() }
    }

    nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.handleWiFiEvent() }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.handleWiFiEvent() }
    }

    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.handleWiFiEvent() }
    }
}

// MARK: - Location authorization

extension PlaceMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            PlaceMonitor.trace("authorization changed to \(status.rawValue)")
            self.authorizationStatus = status
            self.cachedSnapshot = nil
            self.onEvent?(.networkChange)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        PlaceMonitor.trace("location failed: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]")
        // kCLErrorDenied while the status is still "not determined" means the
        // request was refused without a dialog — macOS allows only one
        // outstanding prompt per app, and an earlier one is still pending
        // somewhere, possibly on another display or off-screen entirely.
        guard nsError.domain == kCLErrorDomain, nsError.code == CLError.denied.rawValue else { return }
        Task { @MainActor [weak self] in
            guard let self, self.authorizationStatus == .notDetermined else { return }
            self.promptSeemsStuck = true
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        PlaceMonitor.trace("location updated (\(locations.count))")
    }
}
