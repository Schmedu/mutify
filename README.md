# Mutify

A macOS menu bar app that sets the output volume to **0** whenever you're
somewhere sound isn't welcome and the sound would come out of speakers the room
can hear. Headphones are never touched. See [PRD.md](PRD.md) for the reasoning
behind every rule.

## How it decides

```
mute  ⟺  set up and not paused
         AND no override running
         AND the output device is room-audible
         AND the Wi-Fi network isn't on the allow list
```

| Situation | Result |
|---|---|
| Network on the **mute list** | muted (deny wins over the allow list) |
| Network on the **allow list** | sound allowed |
| Network on neither, or no network at all | your "unknown networks" setting — muted by default |
| Nothing identifies the network | stands down, with a warning — never mutes on a guess |
| AirPods, headset, headphones in the jack | left alone, wherever you are |
| Built-in speakers, a monitor over HDMI | treated as room-audible |
| Virtual/USB devices | classified by you on the **Devices** tab |

**Temporary escape hatches:** allow sound for 15/30 minutes, an hour, until
tomorrow morning, or until you leave this network — plus an indefinite pause.
A volume Mutify lowered is put back when sound is allowed again, on the device it
lowered it on, and only if you haven't changed it yourself in the meantime.

## Build and install

```sh
./Scripts/build.sh            # builds build/Mutify.app
./Scripts/build.sh --install  # …and moves it to /Applications and launches it
swift test                    # the decision engine's test suite
```

It signs with a Developer ID certificate if you have one, otherwise a
development certificate, otherwise ad-hoc.

## If the menu bar icon doesn't appear

macOS parks new menu bar items to the left of the notch when the bar is full, in
a region it never draws — the item exists, it just can't be seen. This is a
system limitation, not an app bug, and it affects any newly launched menu bar
app on a crowded Mac.

**Opening Mutify again (double-click it in Finder, or `open -a Mutify`) always
brings up its window**, and every control from the menu is also in that window,
so the app stays fully usable either way. To get the icon back, quit a menu bar
app or install a menu bar manager such as Ice.

The icon can also be turned off on purpose — *General ▸ Show the icon in the
menu bar*. Mutify keeps muting without it; opening the app again is then the way
back to its window.

## How Mutify tells networks apart

The obvious answer is the Wi-Fi name, and macOS won't give it up. Since macOS 14
an app without Location Services access doesn't get an error when it asks — it
gets the literal string `<redacted>`, from CoreWLAN, from `ipconfig getsummary`
and from `system_profiler` alike. Treating that as a network name would be
worse than useless: allow-listing it would allow-list every network whose name
can't be read.

So Mutify identifies a network by **its router's hardware address**, which needs
no permission at all and is the better identifier anyway — two cafés both called
"FRITZ!Box" are two different networks, and this tells them apart. Networks
identified this way show up as *"Unnamed network (router …2b:3c)"*, and you can
give them a name of your own on the Networks tab.

Granting Location access is still worth it: the real Wi-Fi name then appears
instead. A network is matched by **either** identifier, so entries added before
the grant keep working after it.

Nothing about your location or your networks ever leaves the machine.

## Diagnostics

```sh
/Applications/Mutify.app/Contents/MacOS/Mutify --probe
```
prints the network, every output device with its classification, and the decision
Mutify would make right now.

```sh
… --probe-as "MacBook Pro Speakers"   # what happens when my AirPods die?
… --ask-location                       # trigger the Location permission prompt
… --probe-write "MacBook Pro Speakers" # can this device be muted and restored?
MUTIFY_DEBUG_STATUS=1 …                # where the menu bar icon was placed
```

`--probe-write` briefly silences the named device and puts it back; it warns
first if that device is the current output.

## Where things live

| | |
|---|---|
| Settings | `~/Library/Application Support/Mutify/settings.json` |
| Runtime state (override, remembered volumes) | `…/Mutify/state.json` |
| Activity log | `~/Library/Logs/Mutify/mutify.log` |

## Layout

- `Sources/MutifyCore` — the decision engine. Pure functions, no I/O, no frameworks.
- `Sources/Mutify` — CoreAudio, CoreWLAN, CoreLocation, the menu and the window.
- `Tests/MutifyCoreTests` — one test per rule and per scenario in the PRD.
