import AppKit
import Foundation
import MutifyCore
import Observation
import os

/// Wires the monitors to the policy engine and applies what it decides.
@MainActor
@Observable
final class AppState {

    // MARK: - Observable state

    var settings: Settings
    private(set) var place: PlaceSignal = .noWiFi
    private(set) var output: OutputContext?
    private(set) var result: PolicyResult
    private(set) var override: Override = .none
    private(set) var muteRecords: [String: MuteRecord] = [:]
    private(set) var currentVolume: Double?
    private(set) var locationPermissionMissing = false
    private(set) var loginItemEnabled = false

    var activity: [ActivityEntry] { logger.entries }

    // MARK: - Collaborators

    @ObservationIgnored private let audio = AudioController()
    @ObservationIgnored private let places = PlaceMonitor()
    @ObservationIgnored private let triggers = TriggerHub()
    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private let logger = ActivityLogger()
    @ObservationIgnored private let log = Logger(subsystem: "com.schmedu.mutify", category: "state")

    @ObservationIgnored private var pendingEvaluation: Task<Void, Never>?
    @ObservationIgnored private var pendingTrigger: Trigger = .launch
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var retryTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lastSavedSettings: Settings
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        lastSavedSettings = loaded
        result = PolicyResult(decision: .allow, enforcing: false, reason: .paused)

        let state = SettingsStore.loadState()
        override = state.override
        muteRecords = state.muteRecords
    }

    // MARK: - Lifecycle

    func start() {
        places.refreshAuthorizationStatus()
        audio.onEvent = { [weak self] trigger in self?.schedule(trigger) }
        places.onEvent = { [weak self] trigger in self?.schedule(trigger) }
        triggers.onEvent = { [weak self] trigger in
            guard let self else { return }
            self.schedule(trigger)
            // The audio stack isn't always ready the instant the Mac wakes.
            if trigger == .wake || trigger == .unlock { self.scheduleWakeRetries() }
        }
        notifications.onAllowThirtyMinutes = { [weak self] in
            self?.startOverride(.thirtyMinutes)
        }

        audio.startListening()
        places.start()
        triggers.start()
        notifications.configure()
        loginItemEnabled = LoginItem.isEnabled

        observeSettings()
        evaluate(trigger: .launch)
    }

    func stop() {
        audio.stopListening()
        places.stop()
        triggers.stop()
    }

    // MARK: - Evaluation

    /// Coalesces bursts of events — joining a network fires several at once.
    private func schedule(_ trigger: Trigger) {
        pendingTrigger = trigger
        pendingEvaluation?.cancel()
        pendingEvaluation = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.evaluate(trigger: self.pendingTrigger)
        }
    }

    func evaluate(trigger: Trigger) {
        let now = Date()
        let newPlace = places.currentPlace()
        let newOutput = audio.currentOutput

        // Note what we've seen, without writing when nothing actually changed —
        // a no-op write would bounce straight back in here as a settings change.
        if let identity = newPlace.identity, settings.isUnseen(identity) {
            settings.noteSeen(network: identity)
        }
        if let device = newOutput, settings.seenDevices[device.uid] != device.name {
            settings.noteSeen(device: device)
        }

        if override != .none, !override.isActive(now: now, place: newPlace) {
            override = .none
            persistState()
        }

        let outcome = PolicyEngine.evaluate(
            place: newPlace,
            output: newOutput,
            settings: settings,
            override: override,
            now: now
        )

        place = newPlace
        output = newOutput
        result = outcome
        currentVolume = audio.currentVolume
        locationPermissionMissing = places.needsLocationPermission

        apply(outcome, trigger: trigger)
        scheduleOverrideExpiry()
    }

    private func apply(_ outcome: PolicyResult, trigger: Trigger) {
        guard outcome.isMuting else {
            restoreWhatWeLowered(result: outcome, trigger: trigger)
            return
        }

        // In "mute on changes" mode a volume the user raised by hand stands
        // until something else changes.
        guard trigger.permitsMuting(mode: settings.enforcementMode) else { return }

        guard let device = output else { return }
        let volume = audio.currentVolume ?? 0
        let alreadySilent = volume <= 0.0001 || (audio.currentDeviceIsMuted ?? false)

        if alreadySilent {
            // Nothing to do — and nothing to claim: if we didn't lower it, we
            // don't get to raise it later.
            return
        }

        muteRecords[device.uid] = MuteRecord(deviceUID: device.uid, previousVolume: volume, at: Date())
        let worked = audio.silence()
        currentVolume = audio.currentVolume
        persistState()

        record(
            trigger: trigger,
            action: worked ? .muted : .noChange,
            detail: worked
                ? outcome.reason.shortDescription
                : "device refused volume change (\(outcome.reason.shortDescription))"
        )

        if worked, settings.notifyOnMute {
            notifications.postMuted(
                reason: outcome.reason.headline(decision: outcome.decision),
                device: device.name
            )
        }
    }

    /// Puts back every volume Mutify lowered, on the devices it lowered them on —
    /// those devices need not be the current output.
    private func restoreWhatWeLowered(result outcome: PolicyResult, trigger: Trigger) {
        guard !muteRecords.isEmpty else { return }

        // Allowed only because the output happens to be private? The speakers are
        // still somewhere they must stay down. Keep the note for later.
        guard outcome.permitsRestore else { return }

        guard settings.restoreVolume else {
            muteRecords.removeAll()
            persistState()
            return
        }

        var restored: [String] = []
        var dropped = false

        for (uid, lowered) in muteRecords {
            // A note older than a week is more likely to surprise than to help.
            if Date().timeIntervalSince(lowered.at) > 7 * 24 * 3600 {
                muteRecords[uid] = nil
                dropped = true
                continue
            }
            // Device unplugged: keep the note until it comes back.
            guard audio.deviceExists(uid: uid) else { continue }
            // Volume no longer where we left it: the user has taken over.
            guard let current = audio.volume(ofDeviceWithUID: uid), current <= 0.0001 else {
                muteRecords[uid] = nil
                dropped = true
                continue
            }

            var target = lowered.previousVolume
            if let cap = settings.restoreCap { target = min(target, cap) }
            guard target > 0.0001 else {
                muteRecords[uid] = nil
                dropped = true
                continue
            }

            if audio.restore(volume: target, onDeviceWithUID: uid) {
                muteRecords[uid] = nil
                restored.append("\(Int((target * 100).rounded()))%")
            }
        }

        if !restored.isEmpty || dropped {
            currentVolume = audio.currentVolume
            persistState()
        }
        if !restored.isEmpty {
            record(trigger: trigger, action: .restored, detail: "back to \(restored.joined(separator: ", "))")
        }
    }

    /// Right after wake the default device can still be settling.
    private func scheduleWakeRetries() {
        retryTasks.forEach { $0.cancel() }
        retryTasks = [0.5, 2.0, 5.0].map { delay in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.evaluate(trigger: .retry)
            }
        }
    }

    // MARK: - User actions

    func startOverride(_ option: OverrideOption) {
        guard let value = option.makeOverride(now: Date(), place: place) else { return }
        override = value
        persistState()
        record(trigger: .userAction, action: .standDown, detail: option.title)
        evaluate(trigger: .userAction)
    }

    func cancelOverride() {
        guard override != .none else { return }
        override = .none
        persistState()
        record(trigger: .userAction, action: .noChange, detail: "override cancelled")
        evaluate(trigger: .userAction)
    }

    /// Finishes first-run setup. Nothing is enforced before this happens.
    func completeSetup(allowCurrentNetwork: Bool) {
        if allowCurrentNetwork, let ssid = place.ssid {
            settings.add(ssid, to: .allow)
        }
        settings.hasCompletedOnboarding = true
        record(trigger: .userAction, action: .noChange, detail: "setup finished")
    }

    func setPaused(_ paused: Bool) {
        settings.masterEnabled = !paused
        record(trigger: .userAction, action: paused ? .standDown : .noChange,
               detail: paused ? "Mutify paused" : "Mutify resumed")
    }

    func addCurrentNetwork(to policy: PlacePolicy) {
        guard let identity = place.identity else { return }
        settings.add(identity, to: policy)
    }

    /// Gives the current network a name of its own — the only way to tell
    /// router-identified networks apart in the lists.
    func labelCurrentNetwork(_ label: String) {
        guard let key = place.identity?.primaryKey else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            settings.networkLabels.removeValue(forKey: key)
        } else {
            settings.networkLabels[key] = trimmed
        }
    }

    /// Saved Wi-Fi names, for naming a network macOS won't name for us.
    func knownNetworkNames() -> [String] {
        PlaceMonitor.preferredNetworkNames()
    }

    var currentNetworkName: String? {
        place.identity?.displayName(labels: settings.networkLabels)
    }

    var currentNetworkPolicy: PlacePolicy? {
        place.identity.flatMap { settings.policy(for: $0) }
    }

    func setLoginItem(_ enabled: Bool) {
        loginItemEnabled = LoginItem.setEnabled(enabled)
    }

    func requestLocationPermission() {
        places.requestLocationPermission()
    }

    var locationStatusDescription: String { places.authorizationDescription }

    var canPromptForLocation: Bool { places.canPrompt }

    /// True when macOS took the request but showed nothing.
    var locationPromptSeemsStuck: Bool { places.promptSeemsStuck }

    func clearStuckLocationPrompt() { places.clearStuckPromptAndRetry() }

    func openLocationSettings() {
        places.openLocationSettings()
    }

    /// Mutes the current output on request.
    ///
    /// Deliberately records nothing to restore later: a mute the user asked for
    /// is theirs to undo. Recording it would leave headphones — which Mutify
    /// never mutes on its own, and so has no natural moment to unmute — holding
    /// a volume that only comes back by accident.
    func muteNow() {
        guard output != nil else { return }
        audio.silence()
        currentVolume = audio.currentVolume
        persistState()
        record(trigger: .userAction, action: .muted, detail: "muted by hand")
    }

    // MARK: - Plumbing

    private func record(trigger: Trigger, action: ActivityAction, detail: String) {
        logger.record(
            ActivityEntry(
                trigger: trigger,
                action: action,
                ssid: currentNetworkName,
                device: output?.name,
                detail: detail
            )
        )
    }

    private func persistState() {
        SettingsStore.saveState(PersistedState(override: override, muteRecords: muteRecords))
    }

    private func scheduleOverrideExpiry() {
        expiryTask?.cancel()
        guard let expiry = override.expiry else { return }
        let interval = expiry.timeIntervalSinceNow
        guard interval > 0 else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval + 0.5))
            guard !Task.isCancelled else { return }
            self?.evaluate(trigger: .timer)
        }
    }

    /// Saves settings and re-evaluates whenever anything in `settings` changes,
    /// wherever the change came from — menu, Settings window, or code.
    private func observeSettings() {
        withObservationTracking {
            _ = settings
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    private func settingsChanged() {
        guard settings != lastSavedSettings else { return }
        lastSavedSettings = settings
        saveTask?.cancel()
        let snapshot = settings
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            SettingsStore.save(snapshot)
            _ = self
        }
        schedule(.settingsChange)
    }
}

// MARK: - Presentation helpers

extension AppState {
    var headline: String {
        if place == .unavailable {
            return "Standing down — can't identify this network"
        }
        return result.reason.headline(decision: result.decision)
    }

    var subline: String {
        var parts: [String] = []
        switch place {
        case .network(let identity):
            parts.append("Network: \(identity.displayName(labels: settings.networkLabels))")
        case .noWiFi: parts.append("No network")
        case .unavailable: parts.append("Network: unidentifiable")
        }
        if let output {
            let classification = PolicyEngine.resolvedClass(output, settings: settings)
            let suffix = classification == .speakers ? "speakers" : "private"
            parts.append("Output: \(output.name) (\(suffix))")
        }
        return parts.joined(separator: " · ")
    }

    var statusSymbol: String {
        if locationPermissionMissing, place == .unavailable { return "exclamationmark.triangle.fill" }
        if !settings.masterEnabled || !settings.hasCompletedOnboarding { return "pause.circle" }
        if override != .none { return "speaker.zzz.fill" }
        return result.isMuting ? "speaker.slash.fill" : "speaker.wave.2"
    }

    var isOverrideActive: Bool { override != .none }

    var needsSetup: Bool { !settings.hasCompletedOnboarding }

    /// True only before Mutify has ever been configured — not merely when
    /// something is missing.
    var isFirstRun: Bool { !settings.hasCompletedOnboarding && settings.seenDevices.isEmpty }

    var overrideDescription: String? {
        switch override {
        case .none: return nil
        case .until(let date): return "Sound allowed until \(Reason.timeFormatter.string(from: date))"
        case .indefinite: return "Sound allowed indefinitely"
        case .untilNetworkChange(let ssid): return "Sound allowed while on “\(ssid)”"
        }
    }

    /// Devices seen before that the heuristics can't classify — the ones worth
    /// asking the user about.
    var ambiguousDevices: [(uid: String, name: String)] {
        settings.seenDevices
            .filter { settings.deviceClassOverrides[$0.key] == nil }
            .map { (uid: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
