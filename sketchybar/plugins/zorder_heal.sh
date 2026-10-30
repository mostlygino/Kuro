#!/bin/zsh

# Says so in the log when a pill's window is stacked over the badges it holds
# (assets/zorder), shared by display_settle.sh and bar_health.sh.
#
# It reloaded the bar until 2026-10-30, see below. Two guards from 2026-10-25,
# when the log showed the bar reloading again and again:
# - The fault has to still be there a second later. Windows move while the bar
#   or the screens are settling, and a check taken mid-move said "wrong" for an
#   order that was right a moment after.
# - One report every ten minutes at most, for both callers together.
#
# Usage: zorder_heal.sh <caller name, for the log>

zmodload zsh/datetime
ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
PROBE="$ASSETS/zorder"
STAMP="$HOME/.cache/sketchybar/zorder-report"

if [[ ! -x "$PROBE" || "$ASSETS/zorder.swift" -nt "$PROBE" ]]; then
  /usr/bin/xcrun swiftc -O "$ASSETS/zorder.swift" -o "$PROBE" 2>/dev/null || exit 0
fi

"$PROBE" 2>/dev/null && exit 0
sleep 1
why=$("$PROBE" 2>&1) && exit 0

# Logged, once in ten minutes, and no longer healed with a reload (2026-10-30).
# On three screens the check fired after nearly every wake, mostly a one-chip
# workspace pill on a second screen 1pt around its chip, now and then the badge
# pill, and the reload cost far more than the dimming: every helper restarted,
# every item flashed on every screen and AeroSpace was rebalanced.
# `sketchybar --reload` is still the fix when a pill really does look grey.
last=0
[[ -r "$STAMP" ]] && last=$(<"$STAMP")
(( EPOCHSECONDS - last >= 600 )) || exit 0
mkdir -p "${STAMP:h}"
print -r -- "$EPOCHSECONDS" > "$STAMP"
echo "$1: a pill is stacked over its items ($why); reload the bar if it looks grey" >&2
