# Design

## Shared app design standard

Read [Skeuomorphic app design](docs/design/APP_DESIGN.md) before changing identity artwork or material treatments. It defines the shared standard for object choice, lighting, small-size legibility, accessible UI, asset delivery and visual review. This app’s existing platform, interaction and token decisions remain in force.

## README presentation

The banner and feature cards use the app icon’s material palette in light and dark. The source is `docs/brand/readme-theme.json`; regenerate with `python3 docs/brand/readme_art.py`. Keep product screenshots literal, copy grounded in the README, and confidential details out of the artwork.

## The Kuro app

Recorded from the built app (`app/Sources/Kuro`), 2026-10-20.

- **Structure, "Watch it install":** two panes everywhere. Left, a 232pt rail on `#111113`: the
  wordmark (黒 Kuro), then the setup steps or the manager's sections. Right, the void (`#0A0A0B`):
  a 26pt semibold title, a lede in muted grey, the controls, and the live console of whatever ran.
- **Tokens (`Theme.swift`, from `sketchybar/colors.sh`):** text `#F5F5F7`, muted `#8E8E93`, faint
  `#48484A` (never for text that must be read), pill `#1C1C1E`, hairline white at 13%, console well
  `#070708`, one accent `#BF5AF2`, status green `#32D74B`, amber `#FF9F0A`, red `#FF453A`.
- **Controls:** the one forward action is a white capsule, the bar's active workspace chip
  (`ChipButtonStyle`); everything else is a pill with a hairline (`PillButtonStyle`). Switches tint
  in the accent. System fonts; SF Mono only in the console and the key editor, where it is code.
- **State:** a drawn ring (`StateMark`) that closes with a check when done, spins while working, and
  turns amber with a mark when it needs you. Colour is never the only signal.
- **Signature moment:** each step's ring closing as its command lands, the way the bar's battery
  ring fills; badge previews drawn live by the bar's own renderers, cycling through their states.
- **Motion:** spring 0.42/0.82 for step and section changes; reduced motion stops the preview
  cycling and the hero's settle.
- **Honesty:** permissions are inferred from what runs and say so; `--demo` carries a purple
  "Demo · nothing is installed or run" tag in the window.
