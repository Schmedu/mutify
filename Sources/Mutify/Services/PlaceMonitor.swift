import CoreLocation
import CoreWLAN
import Foundation
import MutifyCore
import Network

/// Answers "where am I?" — today that means the Wi-Fi network name.
///
/// Reading the SSID through CoreWLAN needs Location Services authorization on
/// macOS 14 and later. `ipconfig getsummary` still reports it without that
/// permission, so it serves as a fallback: Mutify stays useful if the user says
/// no, and simply works better if they say yes.
@MainActor
final class PlaceMonitor: NSObject {

    var onEvent: ((Trigger) -> Void)?

    private let wifiClient = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private var pathMonitor: NWPathMonitor?
    private var pathUsesWiFi = false
    private var cachedFallbackSSID: (value: String?, at: Date)?
    private var locationBurstTask: Task<Void, Never>?

    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Current place

    func currentPlace() -> PlaceSignal {
        guard let interface = wifiClient.interface() else { return .noWiFi }
        guard interface.powerOn() else { return .noWiFi }

        if let ssid = interface.ssid(), !ssid.isEmpty {
            return .wifi(ssid: ssid)
        }
        if let ssid = fallbackSSID(interfaceName: interface.interfaceName), !ssid.isEmpty {
            return .wifi(ssid: ssid)
        }

        // Associated with something we can't name: that is a permission problem,
        // not a "there is no network" situation, and the two must not be confused.
        let associated = interface.interfaceMode() != .none || pathUsesWiFi
        return associated ? .unavailable : .noWiFi
    }

    /// `ipconfig getsummary en0` prints `SSID : <name>` when associated.
    private func fallbackSSID(interfaceName: String?) -> String? {
        if let cached = cachedFallbackSSID, Date().timeIntervalSince(cached.at) < 5 {
            return cached.value
        }
        let name = interfaceName ?? "en0"
        let value = Self.runIPConfig(interface: name)
        cachedFallbackSSID = (value, Date())
        return value
    }

    private static func runIPConfig(interface: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        process.arguments = ["getsummary", interface]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SSID :") else { continue }
            let value = trimmed.dropFirst("SSID :".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pathUsesWiFi = usesWiFi
                self.cachedFallbackSSID = nil
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
    }

    private func handleWiFiEvent() {
        cachedFallbackSSID = nil
        onEvent?(.networkChange)
    }

    // MARK: - Location permission

    var needsLocationPermission: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorized: return false
        default: return true
        }
    }

    func requestLocationPermission() {
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
            self.authorizationStatus = status
            self.cachedFallbackSSID = nil
            self.onEvent?(.networkChange)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to do: the SSID fallback covers us, and the UI already shows
        // the authorization state.
    }
}
