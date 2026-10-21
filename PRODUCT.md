# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (a native SwiftUI app for macOS 26; the bar itself is SketchyBar and AeroSpace configuration)

## Users

- **Someone who found Kuro on GitHub** and wants this desktop on their own Mac: they may have none of
  AeroSpace, SketchyBar, JankyBorders or Homebrew yet, and should not have to read shell scripts to get
  from nothing to a working bar.
- **The author**, every day: the same app is the control panel for a running setup, to switch badges, add
  a binding, see what is broken and fix it, and update.

## Product Purpose

Kuro is a minimal, void-like macOS desktop: AeroSpace for tiling, SketchyBar for the bar, JankyBorders for
the focus ring, with every badge state drawn by native helpers and motion throughout. The Kuro app is the
one place to install it, set it up, keep it healthy and keep it current. Success: a newcomer reaches a
working bar without a terminal, and the author never needs to edit a settings file by hand.

## Positioning

Other macOS "rice" setups ship as dotfiles and a README. Kuro ships its own installer and manager that
know the setup's real state: it reads what is installed and running, previews the badges with the same
renderers the bar uses, checks bindings with AeroSpace before applying them, and rolls back what fails.

## Operating Context

- macOS 26 on Apple silicon, one or more screens, often a MacBook with an external display.
- Homebrew installs the parts; the repository is a git clone the configs are linked from (`install.sh`).
- Settings live outside the repository: `~/.config/kuro/settings` (key=value, read by the bar),
  `~/.config/kuro/aerospace.local.toml` (own bindings, merged by `scripts/kuro-apply.sh`),
  `sketchybar/local.sh` (hand-written shell overrides).
- macOS privacy permissions are part of setup: Accessibility for SketchyBar (the top-edge guard and
  keystrokes), System Audio Recording for the Now Playing watcher, Location for the Wi-Fi name.

## Capabilities and Constraints

- **Onboarding:** requirements check, installing the parts, linking the configs, permissions, choosing
  badges, menu bar behaviour, first start.
- **Manager:** badges and settings with live previews; own keybindings, checked by AeroSpace's dry run
  before they apply; health and repair (what runs, permissions, reload, restart, checks); updates (pull
  from GitHub and rebuild, showing what changed).
- **Delivery:** built from the clone into `~/Applications` by a script, and a zipped unsigned build on
  GitHub Releases. No Developer ID, so a downloaded build meets Gatekeeper on first open.
- Another app's privacy grant cannot be read; permission state is inferred from what is running, and
  said plainly when it cannot be known.
- The app runs Kuro's own scripts and tools (`install.sh`, `scripts/*`, `brew`, `aerospace`,
  `sketchybar`, `git`) with argument lists, never shell strings built from input, and writes only
  validated settings values.
- Undecided: localisation beyond British English.

## Brand Commitments

- Name: Kuro, 黒. The obsidian tile with 黒 inlaid (`docs/brand/`) is the icon; name, icon and artwork
  are reserved (BRAND.md), the code is AGPL-3.0-or-later.
- The bar's world: near-black void, dark translucent pills with a hairline border, drawn marks in the
  system colours, one purple accent (`0xbf5af2`), quiet at rest, motion that explains a change.
- Copy: British English, short sentences, plain words; say what happens.

## Evidence on Hand

- Real bar screenshots and recordings in `docs/` (`bar-left.png`, `bar-right.png`, `card-*.png`,
  `anatomy.png`, `motion.gif`, `highlights.png`), the keyboard reference `docs/keys.png`.
- The badge renderers in `sketchybar/assets/*mark.swift` produce every state as PNG.
- No users, testimonials or download counts exist; none may be invented.

## Product Principles

1. **Show the real thing.** Previews come from the bar's own renderers, status from what is actually
   running.
2. **Nothing breaks silently.** Every change is checked before it applies and rolled back if rejected.
3. **Your settings stay yours.** Nothing personal goes into the repository; `git pull` never fights you.
4. **Quiet until it matters.** Like the bar: calm at rest, clear when something needs attention.

## Accessibility & Inclusion

Full keyboard navigation and VoiceOver labels on every control; status never by colour alone; text
contrast at least 4.5:1 in light and dark; reduced motion honoured.
