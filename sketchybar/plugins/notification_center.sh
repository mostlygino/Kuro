#!/bin/zsh

# Opens macOS Notification Center: the clock's click.
#
# macOS has no command for it, and on macOS 26 the menu bar clock that opens it
# is not reachable through System Events either: ControlCenter reports no menu
# bar at all. What does work is the system's own "Show Notification Center"
# shortcut, which is off by default. install.sh binds it to F19, a key no
# keyboard has in the way and no app claims, and this presses it.
#
# Only when the panel is not already there. Clicking the time while it is open
# is itself a click outside the panel, which closes it; pressing the shortcut
# as well reopened it straight away, so closing it from the clock flashed shut
# and open again. assets/ncstate says whether the panel, or its closing
# animation, is on screen.

ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
PROBE="$ASSETS/ncstate"

if [[ ! -x "$PROBE" || "$ASSETS/ncstate.swift" -nt "$PROBE" ]]; then
  /usr/bin/xcrun swiftc -O "$ASSETS/ncstate.swift" -o "$PROBE" 2>/dev/null
fi

[[ -x "$PROBE" ]] && "$PROBE" && exit 0

if ! /usr/bin/osascript -e 'tell application "System Events" to key code 80' 2>/dev/null; then
  echo "notification_center.sh: keystroke refused, check Accessibility permission for sketchybar" >&2
  exit 1
fi
