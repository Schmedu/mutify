import Foundation
import Testing
@testable import MutifyCore

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func speakers(uid: String = "builtin") -> OutputContext {
    OutputContext(uid: uid, name: "MacBook Pro Speakers", transport: .builtIn)
}

private func wiredHeadphones() -> OutputContext {
    OutputContext(uid: "builtin", name: "MacBook Pro Speakers", transport: .builtIn, isHeadphoneDataSource: true)
}

private func airPods() -> OutputContext {
    OutputContext(uid: "airpods", name: "Eduard's AirPods Pro", transport: .bluetooth)
}

private func monitor() -> OutputContext {
    OutputContext(uid: "dell", name: "DELL U2414H", transport: .hdmi)
}

private func blackHole() -> OutputContext {
    OutputContext(uid: "blackhole", name: "BlackHole 64ch", transport: .virtual)
}

private func settings(
    allow: [String] = [],
    mute: [String] = [],
    unknownNetwork: PlacePolicy = .mute,
    unknownDevice: OutputClass = .speakers,
    enabled: Bool = true,
    deviceOverrides: [String: OutputClass] = [:],
    setUp: Bool = true
) -> Settings {
    Settings(
        masterEnabled: enabled,
        unknownNetworkPolicy: unknownNetwork,
        unknownDeviceClass: unknownDevice,
        allowList: allow,
        muteList: mute,
        deviceClassOverrides: deviceOverrides,
        hasCompletedOnboarding: setUp
    )
}

private func evaluate(
    place: PlaceSignal,
    output: OutputContext? = speakers(),
    settings s: Settings = settings(),
    override: Override = .none
) -> PolicyResult {
    PolicyEngine.evaluate(place: place, output: output, settings: s, override: override, now: now)
}

// MARK: - The PRD scenarios

@Suite("Scenarios from the PRD")
struct ScenarioTests {

    @Test("S1: café network on neither list is muted")
    func unlistedNetworkMutes() {
        let result = evaluate(place: .network(NetworkIdentity(ssid: "Cafe-Guest")), settings: settings(allow: ["HomeWifi"]))
        #expect(result.decision == .mute)
        #expect(result.enforcing)
        #expect(result.reason == .networkUnlisted("Cafe-Guest"))
    }

    @Test("S2: AirPods dying mid-session falls back to speakers and mutes")
    func fallbackToSpeakersMutes() {
        let s = settings(allow: ["HomeWifi"])
        let before = evaluate(place: .network(NetworkIdentity(ssid: "Cafe-Guest")), output: airPods(), settings: s)
        let after = evaluate(place: .network(NetworkIdentity(ssid: "Cafe-Guest")), output: speakers(), settings: s)
        #expect(before.decision == .allow)
        #expect(after.decision == .mute)
    }

    @Test("S3: headphones are never touched, wherever we are")
    func headphonesAreLeftAlone() {
        for device in [airPods(), wiredHeadphones()] {
            let result = evaluate(place: .network(NetworkIdentity(ssid: "Cafe-Guest")), output: device)
            #expect(result.decision == .allow)
            #expect(result.enforcing, "still armed, just nothing to do")
            #expect(result.reason == .outputIsPrivate(device: device.name))
        }
    }

    @Test("S7: an allow-listed network lets sound through")
    func allowListedNetwork() {
        let result = evaluate(place: .network(NetworkIdentity(ssid: "OfficeWifi")), settings: settings(allow: ["OfficeWifi"]))
        #expect(result.decision == .allow)
        #expect(result.reason == .networkAllowListed("OfficeWifi"))
    }

    @Test("S8: a mute-listed network is muted")
    func muteListedNetwork() {
        let result = evaluate(place: .network(NetworkIdentity(ssid: "ClientGuest")), settings: settings(mute: ["ClientGuest"]))
        #expect(result.decision == .mute)
        #expect(result.reason == .networkMuteListed("ClientGuest"))
    }

    @Test("S6: a hotspot with no Wi-Fi network at all follows the unknown policy")
    func noWiFiFollowsDefault() {
        #expect(evaluate(place: .noWiFi).decision == .mute)
        #expect(evaluate(place: .noWiFi, settings: settings(unknownNetwork: .allow)).decision == .allow)
    }
}

// MARK: - Place resolution

@Suite("Place policy")
struct PlacePolicyTests {

    @Test("Deny wins when an SSID is on both lists")
    func denyWins() {
        let result = evaluate(
            place: .network(NetworkIdentity(ssid: "Both")),
            settings: settings(allow: ["Both"], mute: ["Both"])
        )
        #expect(result.decision == .mute)
        #expect(result.reason == .networkMuteListed("Both"))
    }

    @Test("Matching ignores case and surrounding whitespace")
    func matchingIsForgiving() {
        let result = evaluate(
            place: .network(NetworkIdentity(ssid: "homewifi")),
            settings: settings(allow: ["  HomeWifi  "])
        )
        #expect(result.decision == .allow)
    }

    @Test("Not knowing the network stands down instead of muting everything")
    func unavailablePlaceStandsDown() {
        let result = evaluate(place: .unavailable)
        #expect(result.decision == .allow)
        #expect(result.enforcing == false)
        #expect(result.reason == .placeUnavailable)
    }

    @Test("An unlisted network can be set to allow instead")
    func unknownNetworkPolicyCanBeFlipped() {
        let result = evaluate(
            place: .network(NetworkIdentity(ssid: "Whatever")),
            settings: settings(unknownNetwork: .allow)
        )
        #expect(result.decision == .allow)
        #expect(result.reason == .networkUnlisted("Whatever"))
    }
}

// MARK: - Output classification

@Suite("Output classification")
struct OutputClassTests {

    @Test("Built-in speakers are room-audible; the same device with the headphone jack in use is not")
    func builtInDataSourceDecides() {
        #expect(PolicyEngine.heuristicClass(speakers()) == .speakers)
        #expect(PolicyEngine.heuristicClass(wiredHeadphones()) == .headphones)
    }

    @Test("A monitor over HDMI counts as speakers")
    func hdmiIsSpeakers() {
        #expect(evaluate(place: .network(NetworkIdentity(ssid: "Cafe")), output: monitor()).decision == .mute)
    }

    @Test("Virtual devices follow the unclassified-device setting")
    func virtualDevicesFollowSetting() {
        let asSpeakers = evaluate(
            place: .network(NetworkIdentity(ssid: "Cafe")),
            output: blackHole(),
            settings: settings(unknownDevice: .speakers)
        )
        let asPrivate = evaluate(
            place: .network(NetworkIdentity(ssid: "Cafe")),
            output: blackHole(),
            settings: settings(unknownDevice: .headphones)
        )
        #expect(asSpeakers.decision == .mute)
        #expect(asPrivate.decision == .allow)
    }

    @Test("A per-device classification beats the heuristics")
    func deviceOverrideWins() {
        // A Bluetooth desk speaker: looks private, is not.
        let speaker = OutputContext(uid: "bt-speaker", name: "Kitchen Speaker", transport: .bluetooth)
        let result = evaluate(
            place: .network(NetworkIdentity(ssid: "Cafe")),
            output: speaker,
            settings: settings(deviceOverrides: ["bt-speaker": .speakers])
        )
        #expect(result.decision == .mute)
    }

    @Test("No output device at all means nothing to enforce")
    func noOutputDevice() {
        let result = evaluate(place: .network(NetworkIdentity(ssid: "Cafe")), output: nil)
        #expect(result.enforcing == false)
        #expect(result.reason == .noOutputDevice)
    }
}

// MARK: - Overrides

@Suite("Overrides and the master switch")
struct OverrideTests {

    @Test("Pausing Mutify stops enforcement everywhere")
    func pauseStandsDown() {
        let result = evaluate(place: .network(NetworkIdentity(ssid: "Cafe")), settings: settings(enabled: false))
        #expect(result.enforcing == false)
        #expect(result.reason == .paused)
    }

    @Test("Nothing is muted before the user has finished setup")
    func setupGate() {
        let result = evaluate(place: .network(NetworkIdentity(ssid: "Cafe")), settings: settings(setUp: false))
        #expect(result.decision == .allow)
        #expect(result.enforcing == false)
        #expect(result.reason == .setupIncomplete)
    }

    @Test("A timed override allows sound until it expires, then muting resumes")
    func timedOverrideExpires() {
        let override = Override.until(now.addingTimeInterval(900))
        let during = evaluate(place: .network(NetworkIdentity(ssid: "Cafe")), override: override)
        #expect(during.decision == .allow)
        #expect(during.enforcing == false)

        let after = PolicyEngine.evaluate(
            place: .network(NetworkIdentity(ssid: "Cafe")),
            output: speakers(),
            settings: settings(),
            override: override,
            now: now.addingTimeInterval(901)
        )
        #expect(after.decision == .mute)
    }

    @Test("“Until I leave this network” ends the moment the network changes")
    func networkChangeEndsOverride() {
        let override = Override.untilNetworkChange(key: "Cafe-Guest")
        #expect(override.isActive(now: now, place: .network(NetworkIdentity(ssid: "Cafe-Guest"))))
        #expect(override.isActive(now: now, place: .network(NetworkIdentity(ssid: "CAFE-GUEST"))), "case shouldn't end it")
        #expect(!override.isActive(now: now, place: .network(NetworkIdentity(ssid: "Somewhere else"))))
        #expect(!override.isActive(now: now, place: .noWiFi))
        #expect(!override.isActive(now: now, place: .unavailable))
    }

    @Test("“Until tomorrow morning” lands on the next 07:00")
    func untilTomorrowMorning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!

        let evening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 22))!
        guard case .until(let target)? = OverrideOption.untilTomorrow.makeOverride(
            now: evening, place: .noWiFi, calendar: calendar
        ) else {
            Issue.record("expected a timed override")
            return
        }
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: target)
        #expect(parts.day == 19)
        #expect(parts.hour == 7)

        // Before 07:00 it means *this* morning, not a day later.
        let earlyMorning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 5))!
        guard case .until(let sameDay)? = OverrideOption.untilTomorrow.makeOverride(
            now: earlyMorning, place: .noWiFi, calendar: calendar
        ) else {
            Issue.record("expected a timed override")
            return
        }
        #expect(calendar.dateComponents([.day], from: sameDay).day == 18)
    }

    @Test("“Until I leave this network” isn't offered without a network")
    func networkOverrideNeedsANetwork() {
        #expect(OverrideOption.untilNetworkChange.makeOverride(now: now, place: .noWiFi) == nil)
        #expect(OverrideOption.untilNetworkChange.makeOverride(now: now, place: .network(NetworkIdentity(ssid: "X"))) != nil)
    }
}

// MARK: - Enforcement modes

@Suite("Enforcement modes")
struct EnforcementModeTests {

    @Test("Only strict mode reacts to the user turning the volume back up")
    func volumeChangesOnlyMatterInStrictMode() {
        #expect(Trigger.volumeChange.permitsMuting(mode: .onChange) == false)
        #expect(Trigger.volumeChange.permitsMuting(mode: .strict))
    }

    @Test("Every other trigger applies in both modes")
    func otherTriggersAlwaysApply() {
        for trigger in Trigger.allTriggersExceptVolume {
            #expect(trigger.permitsMuting(mode: .onChange))
            #expect(trigger.permitsMuting(mode: .strict))
        }
    }
}

extension Trigger {
    static var allTriggersExceptVolume: [Trigger] {
        [.launch, .networkChange, .outputDeviceChange, .wake, .unlock, .settingsChange, .userAction, .timer, .retry]
    }
}

// MARK: - Settings

@Suite("Settings")
struct SettingsTests {

    @Test("Adding to one list removes the SSID from the other")
    func addingMovesBetweenLists() {
        var s = Settings()
        s.add("HomeWifi", to: .allow)
        #expect(s.policy(forSSID: "HomeWifi") == .allow)
        s.add("homewifi", to: .mute)
        #expect(s.policy(forSSID: "HomeWifi") == .mute)
        #expect(s.allowList.isEmpty)
        #expect(s.muteList.count == 1)
    }

    @Test("Blank names are ignored")
    func blankNamesIgnored() {
        var s = Settings()
        s.add("   ", to: .allow)
        #expect(s.allowList.isEmpty)
    }

    @Test("Seen networks are remembered once and capped")
    func seenNetworksAreCapped() {
        var s = Settings()
        for index in 0..<60 { s.noteSeen(ssid: "net-\(index)") }
        s.noteSeen(ssid: "net-59")
        #expect(s.seenNetworks.count == 50)
        #expect(s.seenNetworks.last == "net-59")
    }

    @Test("A settings file missing keys still loads, with defaults")
    func decodingToleratesMissingKeys() throws {
        let json = #"{"allowList":["HomeWifi"],"masterEnabled":false}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.allowList == ["HomeWifi"])
        #expect(decoded.masterEnabled == false)
        #expect(decoded.unknownNetworkPolicy == .mute, "default preserved")
        #expect(decoded.restoreVolume, "default preserved")
    }

    @Test("Settings survive a round trip")
    func roundTrip() throws {
        var s = Settings()
        s.add("HomeWifi", to: .allow)
        s.add("ClientGuest", to: .mute)
        s.deviceClassOverrides["blackhole"] = .headphones
        s.restoreCap = 0.4
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded == s)
    }
}

// MARK: - Restoring

@Suite("Putting the volume back")
struct RestoreTests {

    @Test("Headphones going in doesn't hand the speakers their volume back")
    func privateOutputDoesNotRestoreSpeakers() {
        // At a café with AirPods in: sound is allowed, but the speakers must stay
        // down or they'd blast the room the moment the AirPods come out.
        let result = evaluate(place: .network(NetworkIdentity(ssid: "Cafe")), output: airPods())
        #expect(result.decision == .allow)
        #expect(result.permitsRestore == false)
    }

    @Test("Reaching an allowed network puts the volume back")
    func allowedPlaceRestores() {
        let result = evaluate(place: .network(NetworkIdentity(ssid: "HomeWifi")), settings: settings(allow: ["HomeWifi"]))
        #expect(result.permitsRestore)
    }

    @Test("Overrides, pausing and unknown networks all put the volume back")
    func standingDownRestores() {
        #expect(evaluate(place: .network(NetworkIdentity(ssid: "Cafe")), override: .indefinite).permitsRestore)
        #expect(evaluate(place: .network(NetworkIdentity(ssid: "Cafe")), settings: settings(enabled: false)).permitsRestore)
        #expect(evaluate(place: .unavailable).permitsRestore)
    }

    @Test("A mute decision never restores anything")
    func muteDoesNotRestore() {
        #expect(evaluate(place: .network(NetworkIdentity(ssid: "Cafe"))).permitsRestore == false)
    }
}

// MARK: - Network names

@Suite("Network names")
struct NetworkNameTests {

    @Test("macOS's stand-in for a name it won't reveal is not a network name")
    func placeholdersAreRejected() {
        #expect(NetworkName.clean("<redacted>") == nil)
        #expect(NetworkName.clean("  <REDACTED> ") == nil)
        #expect(NetworkName.clean("<private>") == nil)
        #expect(NetworkName.clean("") == nil)
        #expect(NetworkName.clean(nil) == nil)
        #expect(NetworkName.clean("  HomeWifi ") == "HomeWifi")
    }

    @Test("A placeholder can never end up on a list, even typed by hand")
    func placeholdersNeverReachLists() {
        var s = Settings()
        s.add("<redacted>", to: .allow)
        s.noteSeen(ssid: "<redacted>")
        #expect(s.allowList.isEmpty)
        #expect(s.seenNetworks.isEmpty)
    }

    @Test("Allow-listing an unreadable name would allow-list every unreadable network")
    func placeholderWouldBeCatastrophic() {
        // Guarding the lists is what stops one unnamed café from allowing them all.
        var s = Settings(hasCompletedOnboarding: true)
        s.add("<redacted>", to: .allow)
        #expect(s.policy(forSSID: "<redacted>") == nil)
    }
}

// MARK: - Network identity

@Suite("Telling networks apart")
struct NetworkIdentityTests {

    @Test("A network with no readable name is still recognised by its router")
    func routerIdentifiesNetwork() {
        let identity = NetworkIdentity(ssid: nil, routerMAC: "3C:37:86:1A:2B:3C")
        #expect(identity.isIdentifiable)
        #expect(identity.keys == ["router:3c:37:86:1a:2b:3c"])

        var s = settings()
        s.add(identity, to: .allow)
        let result = evaluate(place: .network(identity), settings: s)
        #expect(result.decision == .allow)
    }

    @Test("Nothing to identify it by means standing down, not muting")
    func unidentifiableNetwork() {
        let identity = NetworkIdentity(ssid: "<redacted>", routerMAC: nil)
        #expect(identity.isIdentifiable == false)
    }

    @Test("An entry added before the name was readable keeps working after")
    func eitherKeyMatches() {
        // Allow-listed today, when only the router is known…
        var s = settings()
        s.add(NetworkIdentity(routerMAC: "aa:bb:cc:dd:ee:ff"), to: .allow)

        // …and still allow-listed once Location access reveals the name.
        let named = NetworkIdentity(ssid: "HomeWifi", routerMAC: "aa:bb:cc:dd:ee:ff")
        #expect(s.policy(for: named) == .allow)
        #expect(evaluate(place: .network(named), settings: s).decision == .allow)
    }

    @Test("Two networks sharing a name are still two networks")
    func sameNameDifferentRouter() {
        var s = settings()
        s.add(NetworkIdentity(ssid: "FRITZ!Box", routerMAC: "11:11:11:11:11:11"), to: .allow)

        let elsewhere = NetworkIdentity(ssid: "FRITZ!Box", routerMAC: "22:22:22:22:22:22")
        // The shared name still matches — that's the SSID doing its job — but the
        // router key gives the user a way to be precise.
        #expect(s.policy(forKeys: ["router:22:22:22:22:22:22"]) == nil)
        #expect(elsewhere.keys.contains("router:22:22:22:22:22:22"))
    }

    @Test("Mute wins across identities too")
    func denyWinsAcrossKeys() {
        var s = settings()
        s.add("HomeWifi", to: .allow)
        s.add("router:aa:bb:cc:dd:ee:ff", to: .mute)
        let identity = NetworkIdentity(ssid: "HomeWifi", routerMAC: "aa:bb:cc:dd:ee:ff")
        #expect(s.policy(for: identity) == .mute)
    }

    @Test("Hardware addresses are read and normalised out of arp output")
    func macParsing() {
        #expect(NetworkIdentity.parseMAC(fromARP: "? (192.168.1.1) at 3c:37:86:1a:2b:3c on en0 ifscope [ethernet]")
                == "3c:37:86:1a:2b:3c")
        // arp drops leading zeroes; the key must not depend on that.
        #expect(NetworkIdentity.parseMAC(fromARP: "? (10.0.0.1) at 1:2:3:a:b:c on en0 [ethernet]")
                == "01:02:03:0a:0b:0c")
        #expect(NetworkIdentity.parseMAC(fromARP: "? (10.0.0.1) at (incomplete) on en0") == nil)
        #expect(NetworkIdentity.parseMAC(fromARP: "nothing useful here") == nil)
    }

    @Test("A router-only network reads as something a person can act on")
    func displayNames() {
        let identity = NetworkIdentity(routerMAC: "3c:37:86:1a:2b:3c")
        #expect(identity.displayName().contains("2b:3c"))
        #expect(identity.displayName(labels: ["router:3c:37:86:1a:2b:3c": "Home"]) == "Home")
        #expect(NetworkIdentity(ssid: "HomeWifi").displayName() == "HomeWifi")
    }
}

// MARK: - Explanations

@Suite("Reasons")
struct ReasonTests {

    @Test("Every decision can say why in plain language")
    func everyReasonHasAHeadline() {
        let reasons: [Reason] = [
            .paused,
            .setupIncomplete,
            .overrideUntil(now),
            .overrideIndefinite,
            .overrideUntilNetworkChange(network: "Cafe"),
            .placeUnavailable,
            .noOutputDevice,
            .outputIsPrivate(device: "AirPods"),
            .networkAllowListed("Home"),
            .networkMuteListed("Client"),
            .networkUnlisted("Cafe"),
            .noWiFi,
        ]
        for reason in reasons {
            #expect(!reason.headline(decision: .mute).isEmpty)
            #expect(!reason.shortDescription.isEmpty)
        }
    }

    @Test("The unlisted-network line matches what actually happened")
    func unlistedHeadlineFollowsTheDecision() {
        #expect(Reason.networkUnlisted("Cafe").headline(decision: .mute).contains("Muted"))
        #expect(Reason.networkUnlisted("Cafe").headline(decision: .allow).contains("allowed"))
    }
}
