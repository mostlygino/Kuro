# Kuro on Omarchy

Kuro's bar and look on [Omarchy](https://omarchy.org) 4.5 or later, whose desktop runs in one Quickshell
process (`omarchy-shell`). The Mac's SketchyBar bar is rebuilt here as an Omarchy shell **bar plugin**
(`kuro.bar`, kind `bar`), so it replaces Omarchy's bar the supported way, and Omarchy falls back to its own if
this ever fails to load.

```sh
git clone https://github.com/mostlygino/Kuro.git ~/src/Kuro
~/src/Kuro/linux/omarchy/install.sh            # on
~/src/Kuro/linux/omarchy/install.sh --off      # back to Omarchy's bar and look
~/src/Kuro/linux/omarchy/install.sh --status
```

| Part | On the Mac | Here |
|---|---|---|
| Workspaces | AeroSpace, numbered per screen | Hyprland, Omarchy's block of ten per monitor, numbered 1 to 10 |
| The app in focus | its icon and name, `void` on an empty screen | the same, from Hyprland and the desktop entries |
| Now Playing | `mediawatch` on `media-control` | MPRIS: a spinning cover disc, title ~ artist, click plays or pauses |
| Keep awake | the capsule, `caffeinate` | the capsule, Omarchy's idle service (`omarchy-shell idle`) |
| Vitals | the ghost, from Vitals | the ghost, from `/proc`: the same heat scale and dead band |
| Network | four dots, a port on a cable | the same, from NetworkManager |
| Tailscale, battery | shield and ring | the same, where Tailscale is installed and there is a battery |
| Clock | 12-hour, a card with the month | the same card, ISO weeks down the side |

The marks are drawn in QML (`*Mark.qml`), not by the Mac's Swift renderers, which need Core Graphics. Which
badges show comes from the same `~/.config/kuro/settings` line the Mac reads (`badges=...`). Cards open on a
click, or from a key binding: `qs ipc -p /usr/share/omarchy/shell call kuro card clock` (also `caffeinate`,
`vitals`, `wifi`, `tailscale`, `battery`; `close`).

`hypr/kuro.lua` is Kuro's look in Hyprland: 40 px gaps round the edge, 16 between windows, and the window in
focus marked in Kuro's white (a glow from the shadow, because a virtual GPU draws Hyprland's borders without
their corner arcs). It loads after `looknfeel.lua`, so it wins.

The bar's face is [Mulish](https://github.com/googlefonts/mulish) (SIL Open Font License, `kuro-bar/fonts/`):
the Mac bar's Avenir Next is Apple's and cannot be shipped.

Developing: Quickshell caches a plugin's QML types for the life of the shell, so after an edit run
`omarchy-restart-shell`.
