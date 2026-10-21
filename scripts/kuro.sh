#!/bin/zsh

# Kuro on and off, as a whole or a part at a time. The Kuro app's switches run
# this, and so can you.
#
#   scripts/kuro.sh on  [all|bar|windows]
#   scripts/kuro.sh off [all|bar|windows]
#   scripts/kuro.sh status                      bar=on windows=on
#   scripts/kuro.sh menubar hide|show           the macOS menu bar only
#
# The bar is SketchyBar and its helpers. Off, the macOS menu bar comes back,
# because the strip at the top would otherwise be empty; on, it hides again.
# Windows is AeroSpace with JankyBorders' ring. Off, the windows stay where
# they are, untiled.
#
# Off stays off: SketchyBar leaves Homebrew's login items and AeroSpace's
# login agent is disabled, so a restart does not bring either back until
# they are switched on again.

set -u
REPO="${0:A:h:h}"
PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
AGENT_LABEL=sh.kuro.aerospace
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
DOMAIN="gui/$(id -u)"
HELPERS=(menubarwatch mediawatch topguard hoverwatch motionwatch)
# Where each window was when windows went off: AeroSpace starts with every
# window on one workspace, and this puts them back.
PLACES="${XDG_CACHE_HOME:-$HOME/.cache}/kuro/windows-off"

say() { print -r -- "==> $*"; }

menubar() {
  local hide=$1
  # System Events applies it at once; the preference alone waits for the next
  # login. macOS asks once whether whoever runs this may control System Events.
  if /usr/bin/osascript -e "tell application \"System Events\" to set autohide menu bar of dock preferences to $hide" >/dev/null 2>&1; then
    say "macOS menu bar: $([[ $hide == true ]] && print hidden || print shown)"
  else
    /usr/bin/defaults write NSGlobalDomain _HIHideMenuBar -bool "$hide"
    /usr/bin/killall SystemUIServer 2>/dev/null
    say "macOS menu bar: set to $([[ $hide == true ]] && print hide || print show) (System Events refused; may need a log out)"
  fi
}

bar_on() {
  menubar true
  brew services start sketchybar >/dev/null 2>&1 || brew services restart sketchybar >/dev/null 2>&1
  say "bar on"
}

bar_off() {
  brew services stop sketchybar >/dev/null 2>&1
  # Started by sketchybarrc and disowned, so stopping the service leaves them.
  for helper in "${HELPERS[@]}"; do /usr/bin/pkill -TERM -x "$helper" 2>/dev/null; done
  menubar false
  say "bar off"
}

windows_on() {
  /bin/launchctl enable "$DOMAIN/$AGENT_LABEL" 2>/dev/null
  if [[ -f "$AGENT_PLIST" ]] && ! /bin/launchctl print "$DOMAIN/$AGENT_LABEL" >/dev/null 2>&1; then
    /bin/launchctl bootstrap "$DOMAIN" "$AGENT_PLIST" 2>/dev/null
  fi
  if ! /usr/bin/pgrep -xq AeroSpace; then
    if [[ -f "$AGENT_PLIST" ]]; then /bin/launchctl kickstart "$DOMAIN/$AGENT_LABEL" 2>/dev/null
    else /usr/bin/open -a AeroSpace; fi
  fi
  for _ in {1..40}; do aerospace list-workspaces --focused >/dev/null 2>&1 && break; sleep 0.25; done
  restore_places
  /usr/bin/pgrep -xq borders || "$REPO/bordersrc" >/dev/null 2>&1 &!
  say "windows on"
}

# Window ids are the window server's and outlive AeroSpace, so a window that
# is still open goes back to the workspace it had; closed ones are skipped.
restore_places() {
  [[ -r "$PLACES" ]] || return 0
  local line id space moved=0
  local now=" ${(f)$(aerospace list-windows --all --format '%{window-id}' 2>/dev/null)} "
  now="${now//$'\n'/ }"
  for line in "${(@f)$(<"$PLACES")}"; do
    id="${line%%|*}" space="${line#*|}"
    [[ "$now" == *" $id "* ]] || continue
    aerospace move-node-to-workspace --window-id "$id" "$space" 2>/dev/null && (( moved++ ))
  done
  rm -f "$PLACES"
  # Then the workspaces onto their screens, the bar's way (plugins/aerospace_sync.sh).
  SENDER=forced CONFIG_DIR="$REPO/sketchybar" /bin/zsh "$REPO/sketchybar/plugins/aerospace_sync.sh" >/dev/null 2>&1
  say "windows back on their workspaces ($moved)"
}

windows_off() {
  if /usr/bin/pgrep -xq AeroSpace; then
    mkdir -p "${PLACES:h}"
    aerospace list-windows --all --format '%{window-id}|%{workspace}' > "$PLACES" 2>/dev/null
  fi
  # Disabled first, so launchd's KeepAlive does not start it straight back.
  /bin/launchctl disable "$DOMAIN/$AGENT_LABEL" 2>/dev/null
  /bin/launchctl bootout "$DOMAIN/$AGENT_LABEL" 2>/dev/null
  /usr/bin/pgrep -xq AeroSpace && /usr/bin/osascript -e 'tell application "AeroSpace" to quit' >/dev/null 2>&1
  for _ in {1..20}; do /usr/bin/pgrep -xq AeroSpace || break; sleep 0.25; done
  /usr/bin/pkill -TERM -x AeroSpace 2>/dev/null
  /usr/bin/pkill -TERM -x borders 2>/dev/null
  say "windows off"
}

status() {
  local bar=off windows=off
  /usr/bin/pgrep -xq sketchybar && bar=on
  /usr/bin/pgrep -xq AeroSpace && windows=on
  print -r -- "bar=$bar windows=$windows"
}

case "${1:-}" in
  on|off)
    part="${2:-all}"
    case "$part" in
      all) "windows_$1"; "bar_$1" ;;
      bar|windows) "${part}_$1" ;;
      *) print -u2 "kuro.sh: $part is not all, bar or windows"; exit 2 ;;
    esac ;;
  status) status ;;
  menubar)
    case "${2:-}" in
      hide) menubar true ;;
      show) menubar false ;;
      *) print -u2 "kuro.sh: menubar hide|show"; exit 2 ;;
    esac ;;
  *) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
