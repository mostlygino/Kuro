#!/bin/zsh

# zsh starts `&!` jobs at nice 5 by default (BG_NICE). That throttled every
# watcher: slow hover cards, stuttering tweens, a laggy event tap.
unsetopt BG_NICE

# Builds and (re)starts the badge animator. Same reload trap as the other
# watchers: sketchybarrc re-runs this on every --reload, so the old instance has
# to go first.
#
# It needs no list of items. The badges register themselves through
# plugins/motion.sh, and a badge that never does simply stays a still.

ASSETS="$CONFIG_DIR/assets"
WATCHER="$ASSETS/motionwatch"

needs_build() {
  [[ ! -x "$WATCHER" ]] && return 0
  for src in motionwatch.swift sketchybar_ipc.c sketchybar_ipc.h; do
    [[ "$ASSETS/$src" -nt "$WATCHER" ]] && return 0
  done
  return 1
}

if needs_build; then
  if ! /usr/bin/xcrun swiftc -O \
      -import-objc-header "$ASSETS/sketchybar_ipc.h" \
      "$ASSETS/motionwatch.swift" \
      "$ASSETS/sketchybar_ipc.c" \
      -o "$WATCHER" 2>/dev/null; then
    echo "motion_watch.sh: cannot build motionwatch, badges stay still" >&2
    exit 1
  fi
fi

/usr/bin/pkill -KILL -x motionwatch 2>/dev/null && sleep 0.2

"$WATCHER" &!
