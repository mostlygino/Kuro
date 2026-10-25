#!/bin/zsh

# `kbdlight.sh up|down|off|max`: the MacBook keyboard's backlight, a step at a
# time or all the way (assets/kbdlight). For a binding of your own in
# ~/.config/kuro/aerospace.local.toml, for example:
#
#   cmd-rightSquareBracket = 'exec-and-forget ~/.config/sketchybar/plugins/kbdlight.sh up'
#
# Builds the helper on first use, like the bar's other helpers.

ASSETS="${0:A:h:h}/assets"
BIN="$ASSETS/kbdlight"
if [[ ! -x "$BIN" || "$ASSETS/kbdlight.swift" -nt "$BIN" ]]; then
  /usr/bin/xcrun swiftc -O "$ASSETS/kbdlight.swift" -o "$BIN" 2>/dev/null \
    || { echo "kbdlight.sh: cannot build kbdlight" >&2; exit 1; }
fi
exec "$BIN" "$@"
