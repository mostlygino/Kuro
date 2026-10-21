#!/bin/zsh

# Keep this Mac awake: a capsule at the left end of the badge pill.
#
#   caffeinate.sh           poll: draw the capsule and fill its card
#   caffeinate.sh toggle    the capsule's right-click: on if off, off if on
#
# The card, on hover, says how long the Mac has been kept awake and since
# when, with a name for the session that grows with it, and a row to switch it.
#
# On means two things, because one of them alone was not a promise this could
# make. `caffeinate -d -i` holds assertions against display and idle sleep. The
# screen saver, though, runs off its own idle timer, and whether it defers to a
# display assertion is not something macOS documents. So while the capsule is on,
# the screen saver's idle time is also set to never, and the old value is put
# back when it goes off. The value is saved to disk first, so a restart, a
# killed caffeinate or a reload can never leave the screen saver disabled: the
# next poll notices caffeinate is gone and restores it.
#
# An empty grey capsule when off, an amber and white one when on, the pill
# Amphetamine made the keep-awake icon, drawn by assets/capsulemark: switching
# on snaps its halves together and fills them, switching off drains it.

ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
RENDERER="$ASSETS/capsulemark"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/caffeinate"
PID_FILE="$CACHE_DIR/pid"
# The last session: when it started and when it ended, for the card while off.
LAST_SESSION="$CACHE_DIR/last-session"
DETAIL_FILE="$CACHE_DIR/detail"
# The screen saver's idle time from before the capsule went on, or "unset" when
# there was none, so it can be put back exactly.
SAVED_IDLE="$CACHE_DIR/screensaver-idle"

ON_COLOR=0xffff9f0a
OFF_COLOR=0xff8e8e93

# Captured here: inside a function zsh's $0 is the function's name.
PLUGINS="${0:A:h}"
source "$PLUGINS/motion.sh"
mkdir -p "$CACHE_DIR"

# Our caffeinate, and only ours: the pid must still be a caffeinate process.
running() {
  local pid
  [[ -r "$PID_FILE" ]] || return 1
  pid=$(<"$PID_FILE")
  [[ "$pid" == <-> ]] && [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == *caffeinate ]]
}

screensaver_off() {
  if [[ ! -e "$SAVED_IDLE" ]]; then
    defaults -currentHost read com.apple.screensaver idleTime > "$SAVED_IDLE" 2>/dev/null \
      || print -r -- unset > "$SAVED_IDLE"
  fi
  defaults -currentHost write com.apple.screensaver idleTime -int 0
}

screensaver_restore() {
  [[ -e "$SAVED_IDLE" ]] || return 0
  local saved=$(<"$SAVED_IDLE")
  if [[ "$saved" == <-> ]]; then
    defaults -currentHost write com.apple.screensaver idleTime -int "$saved"
  else
    defaults -currentHost delete com.apple.screensaver idleTime 2>/dev/null
  fi
  rm -f "$SAVED_IDLE"
}

render_mark() {
  case "$1" in
    still) "$RENDERER" --state "$2" --out "$3" ;;
    transition) "$RENDERER" --state "$2" --from-state "$4" --transition "$3" ;;
  esac
}

if [[ "$1" == toggle ]]; then
  if running; then
    print -r -- "$(/usr/bin/stat -f %m "$PID_FILE") $(date +%s)" > "$LAST_SESSION"
    kill "$(<"$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
    screensaver_restore
  else
    screensaver_off
    /usr/bin/caffeinate -d -i >/dev/null 2>&1 &!
    print -r -- "$!" > "$PID_FILE"
  fi
fi

if [[ ! -x "$RENDERER" || "$ASSETS/capsulemark.swift" -nt "$RENDERER" ]]; then
  /usr/bin/xcrun swiftc -O "$ASSETS/capsulemark.swift" -o "$RENDERER" 2>/dev/null || exit 0
  motion_purge "$CACHE_DIR"
fi

# The pid file is written the moment caffeinate starts, so its age is how long
# the Mac has been kept awake.
session_name() {
  local minutes=$(( $1 / 60 ))
  if (( minutes < 15 )); then print -r -- "Just taken"
  elif (( minutes < 60 )); then print -r -- "Kicking in"
  elif (( minutes < 180 )); then print -r -- "Wide awake"
  elif (( minutes < 480 )); then print -r -- "Long haul"
  else print -r -- "All-nighter"; fi
}

duration() {
  /usr/bin/python3 "$PLUGINS/since.py" ago "$1"
}

# 08:12 today, Mon 08:12 on an earlier day, the same as since.py.
clock() {
  if [[ "$(date -r "$1" +%Y%m%d)" == "$(date +%Y%m%d)" ]]; then date -r "$1" +%H:%M
  else date -r "$1" '+%a %H:%M'; fi
}

card() {
  local tab=$'\t'
  if [[ "$1" == on ]]; then
    local started=$(/usr/bin/stat -f %m "$PID_FILE") elapsed
    elapsed=$(( $(date +%s) - started ))
    print -r -- "caffeinate.state${tab}$(session_name $elapsed)${tab}awake $(duration $elapsed)${tab}$ON_COLOR
caffeinate.since${tab}Since${tab}$(clock "$started")
caffeinate.screen${tab}Screen saver${tab}held off
caffeinate.toggle${tab}Awake${tab}Let it sleep${tab}0xffff453a" > "$DETAIL_FILE"
    sketchybar --set caffeinate.since drawing=on --set caffeinate.screen drawing=on
  else
    local began ended
    [[ -r "$LAST_SESSION" ]] && read -r began ended < "$LAST_SESSION"
    if [[ "$began" == <-> && "$ended" == <-> ]]; then
      # The last cup, so decaf still says something: how long it kept the
      # Mac up, and when it was put down.
      print -r -- "caffeinate.state${tab}Off${tab}sleeps as usual${tab}$OFF_COLOR
caffeinate.since${tab}Last session${tab}$(duration $(( ended - began ))), till $(clock "$ended")${tab}$OFF_COLOR
caffeinate.toggle${tab}Awake${tab}Keep awake${tab}$ON_COLOR" > "$DETAIL_FILE"
      sketchybar --set caffeinate.since drawing=on --set caffeinate.screen drawing=off
    else
      print -r -- "caffeinate.state${tab}Off${tab}sleeps as usual${tab}$OFF_COLOR
caffeinate.toggle${tab}Awake${tab}Keep awake${tab}$ON_COLOR" > "$DETAIL_FILE"
      sketchybar --set caffeinate.since drawing=off --set caffeinate.screen drawing=off
    fi
  fi
  "$PLUGINS/popup_rows.sh" "$DETAIL_FILE"
}

if running; then
  motion_show caffeinate on render_mark "$CACHE_DIR"
  card on
else
  # Gone without being switched off, a reboot or a kill: undo what on did.
  rm -f "$PID_FILE"
  screensaver_restore
  motion_show caffeinate off render_mark "$CACHE_DIR"
  card off
fi
