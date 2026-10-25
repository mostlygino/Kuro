#!/bin/zsh

# Reloads the bar when a pill's window is stacked over the badges it holds
# (assets/zorder), shared by display_settle.sh and bar_health.sh.
#
# Two guards, both from 2026-10-25, when the log showed the bar reloading again
# and again during a reinstall and a screen change:
# - The fault has to still be there a second later. Windows move while the bar
#   or the screens are settling, and a check taken mid-move said "wrong" for an
#   order that was right a moment after.
# - One reload every two minutes at most, for both callers together. A reload
#   runs display_settle again, so an order that a reload does not fix used to
#   reload the bar in a loop: every card shut, every item flickered.
#
# Usage: zorder_heal.sh <caller name, for the log>

zmodload zsh/datetime
ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
PROBE="$ASSETS/zorder"
STAMP="$HOME/.cache/sketchybar/zorder-reload"

if [[ ! -x "$PROBE" || "$ASSETS/zorder.swift" -nt "$PROBE" ]]; then
  /usr/bin/xcrun swiftc -O "$ASSETS/zorder.swift" -o "$PROBE" 2>/dev/null || exit 0
fi

"$PROBE" 2>/dev/null && exit 0
sleep 1
why=$("$PROBE" 2>&1) && exit 0

last=0
[[ -r "$STAMP" ]] && last=$(<"$STAMP")
(( EPOCHSECONDS - last >= 120 )) || exit 0
mkdir -p "${STAMP:h}"
print -r -- "$EPOCHSECONDS" > "$STAMP"
echo "$1: a pill was stacked over its items ($why), reloading the bar" >&2
sketchybar --reload
