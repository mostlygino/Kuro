#!/bin/zsh

# zsh starts `&!` jobs at nice 5 by default (BG_NICE). That throttled every
# watcher: slow hover cards, stuttering tweens, a laggy event tap.
unsetopt BG_NICE

# Builds and (re)starts the menu bar reveal watcher. Runs from sketchybarrc, so
# it has to be safe to call repeatedly: every `sketchybar --reload` re-executes
# the config and would otherwise stack a second watcher on top of the first.

ASSETS="$CONFIG_DIR/assets"
WATCHER="$ASSETS/menubarwatch"

# Settings read here (MENUBAR_REVEAL_WIDTH) come from local.sh. sketchybarrc has
# it loaded, but display_settle.sh restarts this from an event script, which has
# only SketchyBar's own environment, and the opening was lost on the first
# display change.
[[ -r "$CONFIG_DIR/local.sh" ]] && source "$CONFIG_DIR/local.sh"
REVEAL="$CONFIG_DIR/plugins/menubar_reveal.sh"
if [[ ! -x "$WATCHER" || "$ASSETS/menubarwatch.swift" -nt "$WATCHER" ]]; then
  if ! /usr/bin/xcrun swiftc -O "$ASSETS/menubarwatch.swift" -o "$WATCHER" 2>/dev/null; then
    echo "menubar_watch.sh: cannot build menubarwatch, bar will not yield to the menu bar" >&2
    exit 1
  fi
fi

# SIGTERM rather than SIGKILL: the watcher restores the bar on the way out, and
# killing it mid-reveal would strand the bar in its frosted, label-less state.
# BSD pkill wants the signal before the other flags; `-x -TERM` is rejected
# outright, which silently stacks a new watcher on every reload.
/usr/bin/pkill -TERM -x menubarwatch 2>/dev/null && sleep 0.3

# Normalises the bar in case a previous watcher was killed mid-reveal and never
# got to restore it.
"$REVEAL" off

CONFIG_DIR="$CONFIG_DIR" "$WATCHER" "$REVEAL" &!

# And the guard that keeps the menu bar from coming down at all: the pointer
# stops 6pt below a screen's top edge instead of summoning it (see
# assets/topguard.swift). The watcher above stays as the fallback for when the
# guard cannot run, and for a reveal from the keyboard.
GUARD="$ASSETS/topguard"
if [[ ! -x "$GUARD" || "$ASSETS/topguard.swift" -nt "$GUARD" ]]; then
  /usr/bin/xcrun swiftc -O "$ASSETS/topguard.swift" -o "$GUARD" 2>/dev/null \
    || echo "menubar_watch.sh: cannot build topguard, the menu bar can still come down" >&2
fi
/usr/bin/pkill -TERM -x topguard 2>/dev/null
# MENUBAR_REVEAL_WIDTH (local.sh) leaves an opening that wide at the top centre
# of each screen, where the menu bar still comes down; unset, there is none.
[[ -x "$GUARD" ]] && "$GUARD" --gap "${MENUBAR_REVEAL_WIDTH:-0}" &!
