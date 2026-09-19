# Marketing pictures

Ready to post. Every screenshot is the real app — no mock-ups, no redrawn UI.

| File | Size | Use |
|---|---|---|
| `01-hero.png` | 2400×1350 | The main one: muted in a café, with the General pane |
| `02-menu.png` | 2400×1350 | The menu bar menu and its escape hatches |
| `03-networks.png` | 2400×1350 | Allow list, mute list, deny wins |
| `04-devices.png` | 2400×1350 | Headphones are never touched |
| `05-square.png` | 1600×1600 | Square crop for a carousel cover or an avatar-shaped slot |
| `06-icon.png` | 1600×1600 | The icon on its own, light background |

`screenshots/` holds the bare window captures behind those, at 2× with
transparent rounded corners — drop them on any background you like.

## The Mac in the pictures

The state is made up, so no real network name or device ever ends up in a
post: a café called "Café Kollektiv", a home and a studio on the allow list, a
library and an airport on the mute list. It comes from a screenshot-only build
that seeds `AppState` and opens one pane, kept outside this repo — nothing in
the shipping app knows about it.

To retake them, build that variant with a `MUTIFY_SHOT` scenario
(`cafe`, `home`, `headphones`, `allowed`), `MUTIFY_SHOT_PANE` (0–3) and
`MUTIFY_SHOT_HEIGHT`, capture the window by id with
`screencapture -x -o -l<id>`, then composite.
