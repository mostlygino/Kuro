#!/bin/zsh

# A workspace chip's click. A workspace that exists is switched to. One that
# does not, the home chip the bar keeps while a display shows an agent space,
# is made on that chip's own display: `workspace N` alone would make it on the
# main one whichever display was clicked.

AEROSPACE=/opt/homebrew/bin/aerospace
ws="$1"
"$AEROSPACE" list-workspaces --all 2>/dev/null | grep -qx -- "$ws" && exec "$AEROSPACE" workspace "$ws"

# The chip's display is a bit in its display mask: 2 is display 1, 4 is 2.
mask=$(sketchybar --query "workspace.$ws" 2>/dev/null | grep -m1 -o '"associated_display_mask":[ ]*[0-9]*' | grep -o '[0-9]*$')
display=0
while (( ${mask:-0} > 1 )); do (( mask >>= 1, display++ )); done
monitor=""
for line in "${(@f)$("$AEROSPACE" list-monitors --format '%{monitor-id}|%{monitor-appkit-nsscreen-screens-id}' 2>/dev/null)}"; do
  [[ "${line##*|}" == "$display" ]] && monitor="${line%%|*}"
done
[[ -n "$monitor" ]] && "$AEROSPACE" focus-monitor "$monitor" 2>/dev/null
exec "$AEROSPACE" summon-workspace "$ws"
