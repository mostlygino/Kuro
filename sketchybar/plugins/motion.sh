#!/bin/zsh

# Shared by the three drawn badges: put a state on the bar, and when it is a
# change, let motionwatch animate the way there. Sourced, not run.
#
#   motion_show <item> <key> <render-function> <cache-dir>
#
# The key names a state, and it has to be enough to draw that state again: it
# is how the next change knows what it is changing *from*. The render function
# is called as
#
#   <fn> still      <key> <file>
#   <fn> transition <key> <dir> <from-key>
#
# and every result is cached by key, so a steady tick renders nothing.
#
# Between changes the badge is its still and nothing moves. The badges used to
# breathe all the time as well; that was taken out, and only the transitions
# stayed.

MOTION_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/motion"

# The state currently registered for an item, which is what a change is from.
motion_state() {
  local line
  [[ -r "$MOTION_DIR/$1" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == state=* ]] && print -r -- "${line#state=}"
  done < "$MOTION_DIR/$1"
}

motion_show() {
  local item="$1" key="$2" render="$3" cache="$4"
  local still="$cache/still-$key.png" transition="" previous
  mkdir -p "$cache" "$MOTION_DIR"

  [[ -f "$still" ]] || "$render" still "$key" "$still" || return 1

  previous=$(motion_state "$item")
  if [[ -n "$previous" && "$previous" != "$key" ]] && /usr/bin/pgrep -qx motionwatch; then
    transition="$cache/trans-$previous-$key"
    [[ -d "$transition" ]] || "$render" transition "$key" "$transition" "$previous" \
      || transition=""
  fi

  # Registered only when the state changed. Rewriting an unchanged one blanks
  # the transition line, and a second run landing inside the animator's fifth
  # of a second between reads would swallow the change it was about to play.
  # Written beside and renamed, because motionwatch reads it on a timer and a
  # half-written file is a wrong state.
  if [[ "$previous" != "$key" ]]; then
    print -r -- "state=$key
still=$still
transition=$transition" > "$MOTION_DIR/.$item.$$"
    mv -f "$MOTION_DIR/.$item.$$" "$MOTION_DIR/$item"
  fi

  # With a transition to play, motionwatch owns the image until it lands on the
  # still; setting the still here first would jump to the end and then replay
  # the way there. Otherwise the still goes up directly, which also covers a
  # reload, where the item comes back with no image at all.
  if [[ -n "$transition" ]]; then
    sketchybar --set "$item" drawing=on
  else
    sketchybar --set "$item" drawing=on background.image="$still"
  fi

  # A transition plays once and is done in under a second.
  /usr/bin/find "$cache" -maxdepth 1 -name 'trans-*' -mmin +10 -exec rm -rf {} + 2>/dev/null
  return 0
}

# Everything a rebuilt renderer makes stale. `last` and `detail` stay: they are
# readings, not drawings. `loop-*` is from when the badges breathed.
motion_purge() {
  rm -rf "$1"/still-*.png(N) "$1"/loop-*(N) "$1"/trans-*(N)
}
