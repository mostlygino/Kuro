#!/bin/zsh

# zsh starts `&!` jobs at nice 5 by default (BG_NICE). That throttled every
# watcher: slow hover cards, stuttering tweens, a laggy event tap.
unsetopt BG_NICE

# Builds and (re)starts the popup card watcher. Same reload trap as
# menubar_watch.sh and media_watch.sh: sketchybarrc re-runs this on every
# --reload, so the old instance has to go first.
#
# The seven cards it drives are named here rather than discovered. SketchyBar can
# list its items but not which of them own a popup, so the list has to be written
# down somewhere, and this is the only place that knows it. A click on a badge
# asks this watcher to open or close its card (plugins/card_click.sh), so the
# card flag has one owner and nothing fights over it.

ASSETS="$CONFIG_DIR/assets"
WATCHER="$ASSETS/hoverwatch"

if [[ ! -x "$WATCHER" || "$ASSETS/hoverwatch.swift" -nt "$WATCHER" ]]; then
  if ! /usr/bin/xcrun swiftc -O "$ASSETS/hoverwatch.swift" -o "$WATCHER" 2>/dev/null; then
    echo "hover_watch.sh: cannot build hoverwatch, cards will not open" >&2
    exit 1
  fi
fi

/usr/bin/pkill -KILL -x hoverwatch 2>/dev/null && sleep 0.2

"$WATCHER" orbstack caffeinate claude wifi tailscale vitals battery media_pill clock &!
