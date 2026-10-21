#!/bin/zsh

# After the displays change or the Mac wakes, wait until things have stopped
# moving, then give the two pointer watchers a clean start.
#
# Opening or closing the lid is not one event: macOS reports the new
# arrangement in several steps over about a second, and waking brings its own
# round. The watchers used to be restarted on the first `display_change`, in
# the middle of that, so menubarwatch could come up measuring a layout that was
# gone a moment later. It reads the displays live now, but this still matters
# for hoverwatch, which holds a card's rectangles while it is open, and as a
# plain reset after a lid change: both restart from rest, no card open, bar in
# its normal place.
#
# Overlapping triggers collapse: a change that lands while one is settling
# restarts the wait instead of starting a second pass.

LOCK="${TMPDIR:-/tmp}/sketchybar-display-settle.lock"
SETTLE=2

# The holder can let go between our mkdir and our touch; then the touch fails
# and this trigger runs the pass itself rather than being lost.
if ! mkdir "$LOCK" 2>/dev/null; then
  touch "$LOCK/again" 2>/dev/null && exit 0
  mkdir "$LOCK" 2>/dev/null || { touch "$LOCK/again" 2>/dev/null; exit 0; }
fi
trap 'rm -rf "$LOCK"' EXIT

while true; do
  rm -f "$LOCK/again"
  sleep "$SETTLE"
  [[ -e "$LOCK/again" ]] || break
done

"${0:A:h}/menubar_watch.sh"
"${0:A:h}/hover_watch.sh"

# Then check the windows are still stacked the right way round. A screen change
# can leave a pill's background window in front of the badges it holds, which
# dims them as if greyed out (found 2026-09-29, the badge pill over all five
# badges); a reload is what puts the order back. assets/zorder says which it is.
# After the watchers, so no card is open while it looks.
ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
PROBE="$ASSETS/zorder"
if [[ ! -x "$PROBE" || "$ASSETS/zorder.swift" -nt "$PROBE" ]]; then
  /usr/bin/xcrun swiftc -O "$ASSETS/zorder.swift" -o "$PROBE" 2>/dev/null
fi
sleep 0.5
if [[ -x "$PROBE" ]] && ! "$PROBE"; then
  echo "display_settle.sh: a pill was stacked over its items, reloading the bar" >&2
  sketchybar --reload
fi
