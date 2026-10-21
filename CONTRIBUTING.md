# Contributing to Kuro

Thanks for taking a look. Kuro is a personal macOS desktop made public: SketchyBar, AeroSpace and
JankyBorders, with drawn badges and native helpers. Fixes and ideas of every size are welcome.

## Before you start

- **Bugs:** open an issue with the bug template. Say which macOS version, how many screens, and whether the
  bar was freshly reloaded (`sketchybar --reload`).
- **Features:** open an issue first, so we can agree on the shape before you write code.
- **Security problems:** don't open a public issue. See [SECURITY.md](SECURITY.md).

## Run it

You need macOS 26, the Xcode command line tools, and Homebrew. [`install.sh`](install.sh) installs the rest and
links the configs from this checkout, backing up anything it replaces. Each helper in `sketchybar/assets/`
compiles itself on first use, so there is no build step.

```sh
scripts/check.sh                          # what CI runs; run it before every pull request
sketchybar/assets/render_test.sh          # the golden images of every drawn badge state
python3 docs/make_keys.py                 # after changing a binding in aerospace.toml
scripts/build-app.sh                      # the Kuro app, into build/Kuro.app
open build/Kuro.app --args --demo fresh   # its setup on a made-up Mac; nothing is run
docs/make_app_shots.sh                    # the README's app screenshots, from --demo
```

The app (`app/`, SwiftUI) drives Kuro's own scripts rather than repeating them:
`install.sh`, `scripts/kuro-apply.sh`, `scripts/check.sh`. Anything it runs is a
`Process` with an argument list, never a shell string, and it writes only settings
values the bar would accept (`app/Sources/Kuro/Settings.swift`, `sketchybar/colors.sh`).

## Pull requests

- One change per pull request. Small is good.
- A drawn badge changed on purpose: run `render_test.sh --bless` and say so in the pull request.
- A binding changed: regenerate `docs/KEYS.md`, `keys.html` and `keys.png` with `make_keys.py`; never edit
  them by hand.
- Match the code around you: comment density, naming, idiom. Comments say *why*, and what was tried.
- Copy and docs: British English, short sentences, plain words.
- Nothing leaves the Mac that the user did not ask for: no telemetry, no analytics.
- Screenshots: blur anything private (window titles, network names, contacts).

## Licence

By contributing you license your work under [AGPL-3.0-or-later](LICENSE), the same licence as the rest of the
code. There is no contributor licence agreement. The Kuro name, icon and artwork are not part of that licence;
see [BRAND.md](BRAND.md).
