#!/bin/zsh

# Kuro's window layouts (assets/tiler): Columns, Rows and Side, a screen at a
# time, on top of AeroSpace.
#
#   tiler.sh                 builds it if needed and (re)starts the daemon
#   tiler.sh set <layout>    the focused screen's layout: off, columns, rows, side
#
# Started by aerospace.toml's after-startup-command, so it lives and goes with
# AeroSpace: `kuro.sh off windows` stops AeroSpace and the daemon leaves once
# AeroSpace has been gone a minute. The ⌥⌘ 1, 2, 3 and 0 keys run `set`.

unsetopt BG_NICE

ASSETS="${0:A:h:h}/assets"
TILER="$ASSETS/tiler"
if [[ ! -x "$TILER" || "$ASSETS/tiler.swift" -nt "$TILER" ]]; then
  /usr/bin/xcrun swiftc -O "$ASSETS/tiler.swift" -o "$TILER" 2>/dev/null \
    || { echo "tiler.sh: cannot build tiler, layouts stay off" >&2; exit 1; }
fi

if [[ $# -gt 0 ]]; then
  exec "$TILER" "$@"
fi

/usr/bin/pkill -TERM -x tiler 2>/dev/null && sleep 0.2
"$TILER" &!
