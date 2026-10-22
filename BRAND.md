# Name, icon and artwork

Kuro's **source code** is free software under the [GNU Affero General Public License, version 3 or any
later version](LICENSE) (AGPL-3.0-or-later). That covers the configs, the plugins, the Swift and C helpers,
and the scripts that draw the badges and the docs.

The **Kuro name and its brand assets are not covered by that licence.** They stay © 2026 Gino de Graaff
(mostlygino), all rights reserved:

- the name "Kuro" and "黒" used as the name of this desktop;
- the icon (the obsidian tile with 黒 inlaid) in `docs/brand/`: `master.png`, `icon.png`, `favicon-32.png`
  and `favicon.ico`;
- the README banners and showcase cards in `docs/brand/` (`readme-*.svg`, `readme-theme.json`);
- the screenshots and recordings in `docs/`: `bar-left.png`, `bar-right.png`, `card-*.png`, `anatomy.png`,
  `highlights.png`, `motion.gif`, `app-*.png`, and the mostlygino footer mark;
- the app icon built from `docs/brand/master.png` into `Kuro.app` (`scripts/build-app.sh`).

The scripts that make some of these (`docs/brand/readme_art.py`, `docs/make_*.py`) are AGPL code. What the
badge renderers in `sketchybar/assets/*.swift` draw on your own bar is yours.

You're welcome to show them when you write about, review or link to Kuro. If you **fork** Kuro and distribute
your fork, give it a different name and icon, so people can tell the two apart. The code is yours to use under
the AGPL either way.

## Third-party work

Kuro runs on, and does not include: [SketchyBar](https://github.com/FelixKratz/SketchyBar) and
[JankyBorders](https://github.com/FelixKratz/JankyBorders) by Felix Kratz,
[AeroSpace](https://github.com/nikitabobko/AeroSpace) by Nikita Bobko, and
[media-control](https://github.com/ungive/media-control). The keybindings follow
[Omarchy](https://omarchy.org)'s. The vitals ghost is drawn after [NeoHtop](https://github.com/Abdenasser/neohtop)'s
icon. Service marks in the Now Playing pill (YouTube, Netflix and the rest) belong to their owners. The Omarchy bar's
face is [Mulish](https://github.com/googlefonts/mulish) by the Mulish Project Authors, under the SIL Open Font
License 1.1 (`linux/omarchy/kuro-bar/fonts/OFL.txt`).
