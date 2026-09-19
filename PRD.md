# Mutify — Product Requirements Document

**Status:** Draft v1 · **Date:** 2026-09-18 · **Owner:** Eddie
**Platform:** macOS 26+ (Tahoe), Apple Silicon · Swift 6 / SwiftUI menu-bar app

---

## 1. Problem

Sound escapes the laptop at the worst possible moment. AirPods die mid-video in a
café, the lid opens in a co-working space and a paused YouTube tab resumes, a
Slack huddle joins on speakers in a library. The fix is always the same manual
ritual: remember to turn the volume down *before* leaving home.

Mutify automates that ritual: **when the Mac is not at a place I trust and the
sound would come out of the built-in speakers, the output volume is 0.**

## 2. Goals

- G1 — Zero accidental sound from built-in speakers outside trusted networks/places.
- G2 — Never interfere when sound is private anyway (headphones, AirPods).
- G3 — One click to say "I know, let me have sound for a bit" (temporary disable).
- G4 — Trustworthy and legible: always show *why* it muted; never surprise.
- G5 — Invisible when idle: no dock icon, negligible CPU/RAM, launches at login.

## 3. Non-goals (v1)

- Per-app volume control, muting notifications/Focus modes, or Do Not Disturb.
- Muting the microphone (different problem, possible later).
- Controlling input devices, display brightness, or Bluetooth device switching.
- iCloud sync of settings across Macs; iOS companion app.
- App Store distribution.

## 4. Users & primary scenarios

Single user (me), one MacBook, several regular places.

| # | Scenario | Expected behaviour |
|---|---|---|
| S1 | Leave home, open lid at a café on `Cafe-Guest` | Volume set to 0 within ~2 s of wake |
| S2 | AirPods battery dies at the café → output falls back to speakers | Volume set to 0 immediately on device change |
| S3 | Plug in headphones / connect AirPods anywhere | Nothing happens; volume untouched |
| S4 | Come home, join `HomeWifi` | Volume restored to what it was before Mutify muted it |
| S5 | Café, needs to play a demo out loud | Menu bar → "Allow sound for 15 min" |
| S6 | Tethered to phone hotspot on a train | Unknown network → muted (default policy) |
| S7 | Office network where sound *is* fine | `OfficeWifi` on the allow list → sound allowed |
| S8 | Client office where sound is definitely *not* fine | `ClientGuest` on the mute list → always muted |

## 5. Core concepts

**Place signal** — Where the Mac is. v1 uses the Wi-Fi SSID; v1.1 adds optional
location geofences.

**Output class** — What the sound would come out of: `speakers` (audible to the
room), `private` (headphones/AirPods), or `unknown` (virtual/aggregate devices).

**Policy decision** — `allow` or `mute`, derived from place + output class +
override state.

**Override** — A user-initiated temporary or indefinite suspension of enforcement.

## 6. Decision model

### 6.1 Place → policy

Two SSID lists, plus a fallback:

1. SSID is on the **Mute list** → `mute`
2. SSID is on the **Allow list** → `allow`
3. SSID is known but on neither list → **default policy for unknown networks** (default: `mute`)
4. Not connected to Wi-Fi (Ethernet only, or offline) → **default policy for unknown networks**
5. SSID cannot be determined because Location permission is missing/denied →
   **enforcement pauses**, menu bar shows a warning state (see FR-14)

**Deny wins:** if an SSID somehow appears on both lists, `mute` wins. Same rule
applies once geofences land: any matching mute rule beats any matching allow rule.

Rationale for 3 & 4: the user's stated intent is "allowed on these networks,
otherwise not". The unknown-network default is a setting, so it can be flipped
to "allow" by someone who prefers an explicit blocklist-only model.

Rationale for 5: an app that mutes everything because a permission is missing
feels broken. *Not knowing where we are* is different from *knowing we're
somewhere unlisted* and is surfaced loudly instead of enforced silently.

### 6.2 Output class → enforcement

Enforcement only applies when the current default output device classifies as
`speakers`.

| Device situation | Class | Enforced? |
|---|---|---|
| `MacBook Pro Speakers` (transport Built-in, data source = speakers) | speakers | yes |
| 3.5 mm headphones in the built-in jack (transport Built-in, data source = headphones) | private | no |
| AirPods / Bluetooth headset (transport Bluetooth) | private | no |
| HDMI/DisplayPort monitor with speakers (e.g. `DELL U2414H`) | speakers | yes |
| USB DAC / audio interface | unknown → user-classified | per setting |
| Virtual devices (`BlackHole 64ch`, `Microsoft Teams Audio`, `PRISM Lens Audio`) | unknown → user-classified | per setting |

Transport type alone is not enough: on Macs with a headphone jack the built-in
device stays `Built-in` and only the **data source** changes, so data source must
be checked (FR-5). This machine has 5+ virtual devices, so per-device
classification is a v1 requirement, not a nicety.

### 6.3 Final decision

```
decision = mute  ⟺  enforcementActive
                    AND outputClass resolves to "speakers"
                    AND placePolicy == mute
```
where `enforcementActive` = master switch on ∧ no active override ∧ place signal available.

### 6.4 Enforcement modes

- **On change (default).** Apply mute whenever a trigger event fires (network
  change, output device change, wake, unlock, launch, periodic re-check). Does
  *not* react to the user turning the volume back up — raising the volume is an
  explicit human decision and is respected until the next trigger event.
- **Strict.** Additionally re-mutes on volume-change events, i.e. the volume
  cannot be raised at all while in a mute state. When Mutify re-mutes in this
  mode it posts a notification with a "Allow for 30 min" action, so the escape
  hatch is one click away instead of a fight with the OS.

## 7. Functional requirements

### Muting engine

- **FR-1** Mutify sets the default output device's volume scalar to **0** (as opposed to
  only toggling the mute flag) so the change is visible in the volume HUD and
  in Control Center. Where the device also exposes a mute property, it is set
  as well; both are cleared on restore.
- **FR-2** Mutify records the pre-mute volume. When the decision flips to `allow`,
  it restores that value — but only if the volume is still 0, i.e. only if
  nobody changed it in the meantime. *Setting: "Restore volume when I'm back" (default on).*
- **FR-3** Optional cap on restore ("never restore above N %", default off) so
  coming home from a loud session doesn't blast the room.
- **FR-4** Mutify never raises the volume in any situation other than FR-2.
- **FR-5** Output classification uses transport type **and** data source, with a
  user-editable classification per device (Speakers / Private / Ignore) stored by
  device UID, seeded from the heuristics in §6.2.
- **FR-6** After wake, the audio device may not be ready immediately; re-apply the
  decision at +0.5 s, +2 s and +5 s with idempotent writes.

### Place detection

- **FR-7** Read the current SSID via CoreWLAN (`CWWiFiClient.interface().ssid()`),
  which on macOS 14+ requires Location Services authorization (§10).
- **FR-8** Maintain two user-editable lists: **Allow** and **Mute**. Entries are
  SSID strings, with optional case-insensitive matching and an optional
  wildcard suffix (`Cafe-*`) — wildcard support is v1.1.
- **FR-9** One-click "Add current network to Allow / Mute list" from the menu bar,
  and a picker of recently seen networks in Settings (so lists can be built
  without physically being there).
- **FR-10** Setting: policy for unknown networks / no Wi-Fi (`mute` default | `allow`).
- **FR-11** Re-evaluate on: SSID change, Wi-Fi link change, Wi-Fi power change,
  network path change (`NWPathMonitor`), system wake, screen unlock, session
  activation, default-output-device change, output data-source change, app launch,
  settings change, and a 60 s safety-net timer.

### Overrides (temporary disable)

- **FR-12** From the menu bar: **Allow sound for 15 min / 1 hour / until tomorrow
  morning / until I leave this network**. An active override shows a live
  countdown in the menu and a distinct menu bar icon.
- **FR-13** **Pause Mutify** (indefinite master off) and **Resume**, plus cancel of
  any running override. Overrides survive app restart (stored with an absolute
  expiry timestamp) but a machine restart clears an indefinite pause only if the
  user opted into "always resume at login" (default off — a pause is a pause).
- **FR-13a** "Until I leave this network" resolves the moment the SSID changes to
  anything else, making it the natural "I'm home-ish for now" option.

### Status & transparency

- **FR-14** Menu bar icon states, distinguishable at a glance:
  `armed & allowed` (speaker), `muted by Mutify` (speaker with slash, filled),
  `override active` (speaker with a clock/dot), `paused` (dimmed),
  `needs attention` (exclamation badge — Location permission missing).
- **FR-15** The menu's first line always states the current reason in plain
  language, e.g. *"Muted — on 'Cafe-Guest', which isn't on your allow list"*,
  *"Sound allowed — AirPods Pro connected"*, *"Sound allowed for 12 more minutes"*.
- **FR-16** Recent activity log: last 50 decisions with timestamp, SSID, output
  device and action. Visible in Settings; makes surprising behaviour debuggable
  and builds trust. Also written to a rotating log file for support.
- **FR-17** Optional notification when Mutify mutes (default on for the first
  week, then a "don't show again" affordance), always carrying a "Allow for
  30 min" action button.

### Settings & lifecycle

- **FR-18** Launch at login via `SMAppService.mainApp`, toggleable in Settings.
- **FR-19** Settings window with tabs: **General** (master switch, login item,
  enforcement mode, unknown-network policy, restore behaviour), **Networks**
  (both lists, current SSID, recently seen networks), **Devices** (output device
  classification), **Places** (geofences, v1.1), **Activity** (log), **About**.
- **FR-20** No Dock icon (`LSUIElement`), no main window; Settings opens on demand.
- **FR-21** First-run onboarding: request Location permission with a clear
  explanation, detect the current SSID and offer "This is home — allow sound
  here", explain the unknown-network default, offer to enable launch at login.
- **FR-22** All settings stored locally in a versioned `Codable` struct
  (`~/Library/Application Support/Mutify/settings.json`, atomic writes).
  Export/import as JSON for backup. Nothing leaves the machine.

### v1.1 (explicitly deferred, designed for)

- **FR-23** Location geofences: named places with a coordinate + radius, each
  carrying an `allow` or `mute` policy, evaluated with the deny-wins rule of §6.1.
  Uses `CLLocationManager` region monitoring (Always authorization).
- **FR-24** Global hotkey for "Allow sound for 15 min".
- **FR-25** Time-of-day rules ("mute after 22:00 even at home").
- **FR-26** Calendar/Focus integration ("allow while in a scheduled meeting").

## 8. Architecture

Small, testable modules behind a pure decision core.

```
MutifyApp (SwiftUI, MenuBarExtra)
├─ AppState (@Observable) ────── current decision, reason, override, permissions
├─ PolicyEngine  ← PURE FUNCTION, fully unit-tested
│     (PlaceSignal, OutputClass, Settings, OverrideState, Date) -> Decision
├─ PlaceMonitor   — CoreWLAN + NWPathMonitor + (v1.1) CoreLocation → PlaceSignal
├─ AudioController — CoreAudio: default device, transport/data source,
│                    volume get/set, mute get/set, property listeners
├─ TriggerHub     — NSWorkspace wake/unlock, timers, fans all events into one
│                   debounced (250 ms) re-evaluation
├─ OverrideStore  — timed + indefinite overrides, persisted with absolute expiry
├─ SettingsStore  — versioned Codable, atomic file writes
└─ ActivityLog    — ring buffer + rotating file
```

Key architectural rule: **`PolicyEngine` performs no I/O.** Every scenario in §4
and every row of §6 becomes a unit test that constructs inputs and asserts a
`Decision`, so behaviour can be verified without a Wi-Fi network, a café or a
pair of AirPods.

CoreAudio specifics: default output via `kAudioHardwarePropertyDefaultOutputDevice`,
classification via `kAudioDevicePropertyTransportType` +
`kAudioDevicePropertyDataSource`, volume via `kAudioDevicePropertyVolumeScalar`
(master element, falling back to per-channel writes on devices without a master
element), plus listeners on default-device, volume, mute and data-source changes.

## 9. UX sketch

```
🔇 Mutify
─────────────────────────────────────────────
 Muted — "Cafe-Guest" isn't on your allow list
 Output: MacBook Pro Speakers
─────────────────────────────────────────────
 Allow sound for 15 minutes          ⌘1
 Allow sound for 1 hour              ⌘2
 Allow until tomorrow morning
 Allow until I leave this network
─────────────────────────────────────────────
 Add "Cafe-Guest" to Allow list
 Add "Cafe-Guest" to Mute list
─────────────────────────────────────────────
 Pause Mutify
 Settings…                           ⌘,
 Quit                                ⌘Q
```

## 10. Permissions & privacy

| Permission | Why | If denied |
|---|---|---|
| **Location** (`NSLocationUsageDescription`) | macOS 14+ requires it to read the Wi-Fi SSID at all; also needed for v1.1 geofences | Enforcement pauses, menu bar shows the attention badge, Settings shows a "Open System Settings" button (FR-14) |
| **Notifications** | Mute notices and the "Allow for 30 min" action | Feature silently unavailable; everything else works |
| **Login item** (`SMAppService`) | Launch at login | Toggle reflects the real state; user can approve later in System Settings |

Privacy stance: **everything stays on the device.** No network requests, no
analytics, no telemetry. SSIDs and coordinates are stored only in the local
settings file. This is worth stating in the About tab — the app asks for
location, which deserves an explicit, verifiable answer about what it does with it.

## 11. Edge cases

| Case | Handling |
|---|---|
| Wake with audio stack not yet ready | Retry schedule per FR-6 |
| Phone hotspot with an SSID that looks like home | Normal SSID matching; users can list the hotspot explicitly |
| Two SSIDs with the same name (home + café both "FRITZ!Box") | v1 accepts the collision; v1.1 can pin an entry to a BSSID |
| SSID on both lists | Mute wins (§6.1) |
| Volume raised manually while muted | "On change" mode respects it until the next trigger; Strict mode re-mutes + notifies |
| Mid-call on speakers when a mute triggers | Mute applies as specified; the notification's "Allow for 30 min" is the one-click recovery |
| Default output switches to a virtual device (BlackHole/Teams) | Uses the stored classification for that device UID; unclassified devices follow the "unknown device" setting (default: treat as speakers) and prompt once |
| Ethernet-only / offline | Treated as unknown network → default policy |
| Multiple Wi-Fi interfaces | Use the primary interface from `CWWiFiClient.interface()` |
| App updated / settings schema changed | Versioned settings with migration; unknown future version → back up file and start from defaults rather than crash |
| User quits the app | Nothing is enforced; the volume is left exactly as it is (no unmute on quit) |

## 12. Success criteria

- SC1 — In scenarios S1–S3, the correct volume state is reached within **2 seconds**
  of the triggering event, measured from the activity log.
- SC2 — Zero false mutes over a week of normal use (no mute while headphones are
  the output; no mute on an allow-listed network).
- SC3 — Idle CPU < 0.5 % averaged over an hour; resident memory < 50 MB.
- SC4 — `PolicyEngine` has ≥ 95 % line coverage, with a test per row of §6.1/§6.2
  and per scenario in §4.
- SC5 — Every mute event has a human-readable reason string in the menu and log.

## 13. Milestones

| # | Deliverable | Content |
|---|---|---|
| M0 | Skeleton | Xcode project, `MenuBarExtra`, LSUIElement, settings store, static menu |
| M1 | Audio engine | Device enumeration, classification, volume read/write, listeners, manual mute/unmute from the menu |
| M2 | Place engine | Location permission flow, SSID read, both lists, Networks settings tab |
| M3 | Policy + triggers | `PolicyEngine`, `TriggerHub`, live status line, icon states, unit tests |
| M4 | Overrides | Timed + indefinite, countdown, persistence, "until I leave this network" |
| M5 | Polish | Notifications + action button, activity log, onboarding, launch at login, app icon |
| M6 | v1.1 | Geofences, global hotkey, BSSID pinning, wildcards |

Ship-worthy for daily personal use at **M5**.

## 14. Build & distribution

- Xcode project in this repo, Swift 6, minimum target macOS 26.
- App Sandbox on, with the location entitlement; nothing here needs to escape it.
- Signed with a Developer ID certificate and notarized, delivered as a DMG — an
  unsigned build would need a Gatekeeper override on every update, which is
  friction not worth accepting for an app that is meant to be invisible.
- Bundle id `com.schmedu.mutify`.

## 14a. Addendum — network identity (2026-09-18, after first build)

FR-7 assumed the SSID was obtainable. It isn't: without Location Services macOS
returns the literal string `<redacted>` rather than failing, from every interface
tried (CoreWLAN, `ipconfig getsummary`, `system_profiler SPAirPortDataType`).
Storing that as a network name would silently merge every unidentifiable network
into one allow-listable entry — the worst possible failure for this app.

The permission itself proved unreliable to obtain: macOS suppresses the prompt
for a background-only app that isn't frontmost, and refuses it outright for one
launched from an SSH session (`kCLErrorDenied` with the status still
"not determined").

So network identity is now a **set of keys**, not a name:

- `router:<gateway MAC>` — the default gateway's hardware address, read with no
  permission at all, and stable per network.
- the SSID, when Location access makes it readable.

A network matches a list if **any** of its keys is on it, so an entry added
before the grant keeps working after it. This also resolves the "two networks
named FRITZ!Box" row in §11, which SSIDs alone could not. Networks without a
readable name are displayed as *"Unnamed network (router …2b:3c)"* and can be
given a label by the user.

Location access is now an enhancement (friendly names), not a requirement.

## 14b. Addendum — how it actually builds (2026-09-19)

§14 described an intention; this is the shape it took.

- **SwiftPM, not an Xcode project.** `Scripts/build.sh` compiles with `swift
  build` and assembles the bundle, Info.plist and icon by hand. Nothing about
  the app needs Xcode's build system, and a shell script is readable.
- **Minimum target macOS 14**, not 26 — nothing in the app requires anything
  newer, and raising the floor only costs users. arm64 only; a universal binary
  is one flag away (`--arch arm64 --arch x86_64`) if an Intel Mac ever asks.
- **No App Sandbox.** With App Store distribution a non-goal (§3), the sandbox
  buys nothing here: Developer ID plus notarization is what Gatekeeper asks for,
  and the app reads the default gateway's hardware address, which the sandbox
  would complicate for no gain. Hardened runtime is on, as notarization requires.
- **`--release` does the whole chain**: Developer ID signature with a secure
  timestamp, notarization, and the ticket stapled into both the app and the DMG,
  so a Mac that is offline the first time it opens Mutify still gets a verdict.
  It refuses before compiling when the certificate or the notary credentials
  aren't there, rather than producing a build that only runs on this Mac.

Still missing before handing it to anyone: a licence, and some way to update —
every new version is currently a manual download.

## 15. Open questions

1. **Default enforcement mode** — this PRD picks "On change" as the default for
   v1 (respects a deliberate manual volume change until the next trigger). If the
   real-world failure mode turns out to be "I turned it up and forgot", Strict
   should become the default.
2. **Unclassified/virtual output devices** — default assumed here is "treat as
   speakers" (safer). Given the number of virtual devices on this Mac, the
   opposite default may produce fewer annoyances; decide after M1.
3. **HDMI display speakers** — currently classed as speakers (audible to the
   room). Correct for a monitor, wrong for a TV at home where sound is fine —
   though at home the SSID would allow sound anyway, so this likely resolves itself.
4. **Restore volume** — default on. Should there be a cap (FR-3) enabled by
   default, e.g. 50 %?
5. **Geofences in v1?** — Wi-Fi alone covers S1–S8. Location is already permitted
   for SSID reading, so geofences are cheap to add; the question is whether
   they earn their UI complexity.
