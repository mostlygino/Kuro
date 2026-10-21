#!/bin/zsh

# zsh starts `&!` jobs at nice 5 by default (BG_NICE). That throttled every
# watcher: slow hover cards, stuttering tweens, a laggy event tap.
unsetopt BG_NICE

# Transport controls in the strip under the media pill: previous, play/pause,
# next, shuffle, repeat.
#
#   media_controls.sh refresh      re-read the two modes
#   media_controls.sh press <cmd>  a button's click_script: one media-control
#                                  command
#
# Everything goes through `media-control`, so the controls drive whatever holds
# the Now Playing session rather than one player specifically.
#
# Play/pause shows its state, and mediawatch keeps it right as the player
# changes. Shuffle and repeat show theirs only for Apple Music, the one player
# that answers for them over AppleScript; for anything else both stay grey and
# claim nothing, because a guess about a toggle is worse than no indication.
#
# The strip opens on hover, from hoverwatch, and the buttons act on click. The
# three transport buttons dip under the finger and the two modes crossfade to
# their new glyph, through motionwatch's tween client.

MEDIA_CONTROL=/opt/homebrew/bin/media-control

# Literal glyphs rather than $'\U...' escapes. zsh only decodes \U into a
# character the current locale can encode, and while the daemon inherits a LANG
# from its LaunchAgent, a reload typed into a shell without one does not.
#
# No play/pause pair here: mediawatch is the one writer of that glyph. Two
# writers reading the player at different moments could leave it wrong, and
# mediawatch, which remembers what it last drew, would then never correct it.
SHUFFLE_ON="󰒟"
SHUFFLE_OFF="󰒞"
REPEAT_ALL="󰑖"
REPEAT_ONE="󰑘"
REPEAT_OFF="󰑗"

# Lit is the answer "this is on"; muted covers both "off" and "nobody said".
MODE_ON_COLOR=0xfff5f5f7
MODE_OFF_COLOR=0xff8e8e93
BUTTON_COLOR=0xfff5f5f7
# A pressed button dips to this and comes back, which is the only press
# feedback a glyph can give: it has no scale that does not relayout the strip.
BUTTON_PRESSED_COLOR=0x59f5f5f7
MOTION="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets/motionwatch"

# A mode glyph changing state crossfades: out, swap, back in at its new colour.
# Without motionwatch the values land directly.
swap_glyph() {
  local item="$1" glyph="$2" color="$3"
  "$MOTION" tween \
      "$item" icon.color - "0x00${color#0x??}" 0 80 out \
      "$item" icon = "$glyph" 80 0 linear \
      "$item" icon.color "0x00${color#0x??}" "$color" 80 180 out 2>/dev/null \
    || sketchybar --set "$item" icon="$glyph" icon.color="$color"
}

# Shuffle as a glyph pair rather than by colour alone, and repeat as three
# glyphs, because repeat has three states and a colour cannot say which. The
# crossed-out arrows read as off at a glance even before the colour registers.
set_mode_glyphs() {
  local bundle modes shuffle repeat

  bundle=$("$MEDIA_CONTROL" get 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("bundleIdentifier") or "")
except Exception:
    print("")
' 2>/dev/null)

  # Only ask the app that is actually holding the session. `tell application` is
  # not a read-only verb: naming an app that is not running launches it, and a
  # bar icon has no business opening Music because a popup was hovered.
  if [[ "$bundle" != "com.apple.Music" ]]; then
    swap_glyph transport.shuffle "$SHUFFLE_ON" "$MODE_OFF_COLOR"
    swap_glyph transport.repeat "$REPEAT_ALL" "$MODE_OFF_COLOR"
    return
  fi

  modes=$(/usr/bin/osascript \
    -e 'tell application "Music"' \
    -e 'set s to shuffle enabled' \
    -e 'set r to song repeat' \
    -e 'return (s as text) & " " & (r as text)' \
    -e 'end tell' 2>/dev/null)
  [[ -n "$modes" ]] || return

  shuffle="${modes%% *}"
  repeat="${modes##* }"

  if [[ "$shuffle" == true ]]; then
    swap_glyph transport.shuffle "$SHUFFLE_ON" "$MODE_ON_COLOR"
  else
    swap_glyph transport.shuffle "$SHUFFLE_OFF" "$MODE_OFF_COLOR"
  fi

  case "$repeat" in
    one) swap_glyph transport.repeat "$REPEAT_ONE" "$MODE_ON_COLOR" ;;
    all) swap_glyph transport.repeat "$REPEAT_ALL" "$MODE_ON_COLOR" ;;
    *)   swap_glyph transport.repeat "$REPEAT_OFF" "$MODE_OFF_COLOR" ;;
  esac
}

if [[ "$1" == "press" ]]; then
  [[ -n "$2" ]] || exit 0

  # The three that move the music dip under the finger. Of those only
  # play/pause changes glyph, and mediawatch swaps it the moment the player
  # reports the new state, however it was toggled, so nothing here waits.
  case "$2" in
    previous-track|next-track|toggle-play-pause)
      "$MOTION" tween \
          "$NAME" icon.color = "$BUTTON_PRESSED_COLOR" 0 0 linear \
          "$NAME" icon.color "$BUTTON_PRESSED_COLOR" "$BUTTON_COLOR" 0 260 out 2>/dev/null &!
      ;;
  esac
  "$MEDIA_CONTROL" "$2" >/dev/null 2>&1
  # The command returns before the player has flipped, so asking immediately
  # reads the state just left. One beat, then re-read the modes.
  case "$2" in
    toggle-shuffle|toggle-repeat)
      sleep 0.35
      set_mode_glyphs
      ;;
  esac
  exit 0
fi

# Run when the strip opens (plugins/on_open_media_pill.sh) and on wake, so the
# two mode glyphs are right whether the player was touched here or in the app.
if [[ "$1" == "refresh" || "$SENDER" == media_change || "$SENDER" == system_woke ]]; then
  set_mode_glyphs
  exit 0
fi

exit 0
