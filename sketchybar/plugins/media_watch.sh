#!/bin/zsh

# zsh starts `&!` jobs at nice 5 by default (BG_NICE). That throttled every
# watcher: slow hover cards, stuttering tweens, a laggy event tap.
unsetopt BG_NICE

# Builds and (re)starts the Now Playing disc watcher. Same reload trap as
# menubar_watch.sh: sketchybarrc re-runs this on every --reload.
#
# The watcher ships as an .app bundle rather than a bare binary, and only for one
# reason: the waveform's Core Audio process tap needs a TCC identity to ask for
# System Audio Recording with. See mediawatch-Info.plist for the measurement.
# The executable is still called `mediawatch`, so `pkill -x mediawatch` is
# unchanged.

ASSETS="$CONFIG_DIR/assets"
APP="$ASSETS/mediawatch.app"
WATCHER="$APP/Contents/MacOS/mediawatch"
source "$CONFIG_DIR/colors.sh"

# A stable signing identity, because TCC keys the grant on it. Ad-hoc signing
# would give a fresh cdhash on every rebuild, so every source change would throw
# the permission away and ask again. Set MEDIAWATCH_SIGN_ID in local.sh to the
# name of a code-signing certificate in your login keychain (a self-signed one
# from Keychain Access is enough). Without one it signs ad-hoc: the pill still
# works, the live waveform just asks for permission again after each rebuild.
SIGN_ID="${MEDIAWATCH_SIGN_ID:-}"

needs_build() {
  [[ ! -x "$WATCHER" ]] && return 0
  for src in mediawatch.swift mediatap.swift mediafit.swift mediaservice.swift mediacall.swift main.swift \
             sketchybar_ipc.c sketchybar_ipc.h mediawatch-Info.plist; do
    [[ "$ASSETS/$src" -nt "$WATCHER" ]] && return 0
  done
  return 1
}

if needs_build; then
  mkdir -p "$APP/Contents/MacOS"
  cp "$ASSETS/mediawatch-Info.plist" "$APP/Contents/Info.plist"
  # main.swift is its own file because Swift allows top-level statements in
  # exactly one file per module and insists it be named that. mediatap.swift is
  # the audio tap. All three are one module, so all three are one compile.
  if ! /usr/bin/xcrun swiftc -O \
      -import-objc-header "$ASSETS/sketchybar_ipc.h" \
      "$ASSETS/mediawatch.swift" \
      "$ASSETS/mediatap.swift" \
      "$ASSETS/mediafit.swift" \
      "$ASSETS/mediaservice.swift" \
      "$ASSETS/mediacall.swift" \
      "$ASSETS/main.swift" \
      "$ASSETS/sketchybar_ipc.c" \
      -o "$WATCHER" 2>/dev/null; then
    echo "media_watch.sh: cannot build mediawatch, Now Playing stays hidden" >&2
    exit 1
  fi
  if [[ -n "$SIGN_ID" ]] && /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | grep -qF "$SIGN_ID"; then
    /usr/bin/codesign --force --options runtime --sign "$SIGN_ID" "$APP" \
      >/dev/null 2>&1 \
      || echo "media_watch.sh: signing failed, live waveform will fall back" >&2
  else
    /usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1
    [[ -n "$SIGN_ID" ]] && echo "media_watch.sh: no '$SIGN_ID' identity, signed ad-hoc." \
         "The audio tap will re-ask for permission after every rebuild." >&2
  fi
fi

# KILL, not TERM. The watcher's terminate handler runs on a dispatch queue, so a
# wedged queue used to mean TERM was never processed and the old process stayed
# alive holding the bar's items. That specific wedge is fixed, but a restart path
# that can hang is not worth keeping.
/usr/bin/pkill -KILL -x mediawatch 2>/dev/null && sleep 0.2

MEDIA_COLOR="$MEDIA_COLOR" \
MEDIA_PAUSED_COLOR="$MEDIA_PAUSED_COLOR" \
MEDIA_DISC_SCALE="$MEDIA_DISC_SCALE" \
MEDIA_DISC_PAUSED_SCALE="$MEDIA_DISC_PAUSED_SCALE" \
MEDIA_LABEL_MAX="$MEDIA_LABEL_MAX" \
MEDIA_PAUSE_HIDE_AFTER="$MEDIA_PAUSE_HIDE_AFTER" \
MEDIAWATCH_DEBUG="${MEDIAWATCH_DEBUG:-}" \
MEDIA_ARTIST_COLOR="$MEDIA_ARTIST_COLOR" \
MEDIA_ARTIST_PAUSED_COLOR="$MEDIA_ARTIST_PAUSED_COLOR" \
MEDIA_SEP_COLOR="$MEDIA_SEP_COLOR" \
MEDIA_SEP_PAUSED_COLOR="$MEDIA_SEP_PAUSED_COLOR" \
PILL_TEXT_PAD="$PILL_TEXT_PAD" \
BAR_FONT="$BAR_FONT" \
BAR_FONT_WEIGHT="$BAR_FONT_WEIGHT" \
BAR_FONT_SIZE="$BAR_FONT_SIZE" \
ITEM_GAP="$ITEM_GAP" \
PILL_COLOR="$PILL_COLOR" \
BORDER_COLOR="$BORDER_COLOR" \
SHADOW_COLOR="$SHADOW_COLOR" \
  "$WATCHER" &!
