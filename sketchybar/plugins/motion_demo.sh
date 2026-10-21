#!/bin/zsh

# Plays one transition on each drawn badge, on demand:
#
#   plugins/motion_demo.sh
#
# Real changes are rare and usually small, a ray every half hour and a battery
# percent every few minutes, so this is the way to see the motion at all. The
# Claude burst comes back from its error mark, the battery has the cable plugged
# into it, the shield and the capsule come from their opposite states. Nothing is polled and
# no reading changes: each badge gets a throwaway state that points at its real
# still, and gets its real registry file back once the move has played.

MOTION_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/motion"
ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
DEMO_DIR=$(mktemp -d)
trap 'rm -rf "$DEMO_DIR"' EXIT

/usr/bin/pgrep -qx motionwatch || { print -u2 "motion_demo: motionwatch is not running"; exit 1; }

field() { sed -n "s/^$2=//p" "$MOTION_DIR/$1" 2>/dev/null }

play() {
  local item="$1" transition="$2" saved="$DEMO_DIR/$1.saved"
  cp "$MOTION_DIR/$item" "$saved"
  print -r -- "state=demo-$$
still=$(field "$item" still)
transition=$transition" > "$MOTION_DIR/.$item.demo"
  mv -f "$MOTION_DIR/.$item.demo" "$MOTION_DIR/$item"
}

# Claude: from the error mark back to the current reading.
if key=$(field claude state) && [[ -n "$key" && "$key" != error && "$key" != blocked ]]; then
  "$ASSETS/usagemark" --percent "${key%%-*}" --color "${key#*-}" \
    --from-error --transition "$DEMO_DIR/claude" \
    && play claude "$DEMO_DIR/claude"
fi

# Keep-awake capsule: from the opposite state, so it snaps shut or drains.
if key=$(field caffeinate state) && [[ -n "$key" ]]; then
  "$ASSETS/capsulemark" --state "$key" --from-state "$([[ "$key" == on ]] && print off || print on)" \
    --transition "$DEMO_DIR/caffeinate" && play caffeinate "$DEMO_DIR/caffeinate"
fi

# Vitals: the current reading, from an idle ghost.
if key=$(field vitals state) && [[ -n "$key" ]]; then
  parts=("${(@s:-:)key}")
  "$ASSETS/vitalsmark" --heat "$parts[1]" --tone "$parts[2]" \
    --from-heat 0 --from-tone calm \
    --transition "$DEMO_DIR/vitals" && play vitals "$DEMO_DIR/vitals"
fi

if key=$(field battery state) && [[ -n "$key" ]]; then
  parts=("${(@s:-:)key}")
  "$ASSETS/batterymark" --percent "$parts[1]" --color "$parts[2]" --charging \
    --from-percent "$parts[1]" --from-color "$parts[2]" --transition "$DEMO_DIR/battery" \
    && play battery "$DEMO_DIR/battery"
fi

# Shield: into its current state from connecting, so the tick draws itself in
# or the slash is struck.
if key=$(field tailscale state) && [[ -n "$key" ]]; then
  "$ASSETS/vpnmark" --state "$key" --from-state pending --transition "$DEMO_DIR/tailscale" \
    && play tailscale "$DEMO_DIR/tailscale"
fi

# Long enough for the animator to pick the states up and play one second of
# transition, then the real files go back. Their transition line is blanked on
# the way, or putting the real state back would replay the last real change.
sleep 2
for saved in "$DEMO_DIR"/*.saved(N); do
  item="${${saved:t}%.saved}"
  sed 's/^transition=.*/transition=/' "$saved" > "$MOTION_DIR/.$item.demo"
  mv -f "$MOTION_DIR/.$item.demo" "$MOTION_DIR/$item"
done
