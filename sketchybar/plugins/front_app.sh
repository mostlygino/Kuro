#!/bin/zsh

source "$CONFIG_DIR/colors.sh"

AEROSPACE=/opt/homebrew/bin/aerospace

# $1 is a SketchyBar display id. AeroSpace monitor ids are a different
# namespace, so resolve one to the other through the AppKit NSScreen id.
display_id="$1"
monitor_id=$(
  "$AEROSPACE" list-monitors --format '%{monitor-id}|%{monitor-appkit-nsscreen-screens-id}' 2>/dev/null |
    /usr/bin/awk -F'|' -v display="$display_id" '$2 == display { print $1; exit }'
)

if [[ -z "$monitor_id" ]]; then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

focused=$("$AEROSPACE" list-windows --focused --format '%{monitor-id}|%{app-name}|%{app-bundle-id}' 2>/dev/null)

if [[ "${focused%%|*}" == "$monitor_id" ]]; then
  window="${focused#*|}"
  label_color="$TEXT_COLOR"
else
  window=$(
    "$AEROSPACE" list-windows --monitor "$monitor_id" --workspace visible --format '%{app-name}|%{app-bundle-id}' 2>/dev/null |
      /usr/bin/head -1
  )
  label_color="$MUTED_COLOR"
fi
app_name="${window%%|*}"
bundle_id="${window#*|}"
[[ "$bundle_id" == "$window" ]] && bundle_id=""

# A display with nothing on it says so, rather than leaving the pill with a
# chip and an odd empty tail. Quieter than an app name, so it never reads as
# one.
if [[ -z "$app_name" ]]; then
  app_name="$EMPTY_LABEL"
  label_color="$EMPTY_COLOR"
  bundle_id=""
fi

# The app's own icon in front of its name, as macOS draws it in the Dock. The
# empty display gets the void's own mark instead, a small black hole drawn by
# assets/voidmark: its still, and the frames of its horizon opening, rendered
# once into the cache and rebuilt only when the source changes.
ASSETS="$CONFIG_DIR/assets"
VOID_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/void"
if [[ -z "$bundle_id" ]]; then
  if [[ ! -x "$ASSETS/voidmark" || "$ASSETS/voidmark.swift" -nt "$ASSETS/voidmark" ]]; then
    /usr/bin/xcrun swiftc -O "$ASSETS/voidmark.swift" -o "$ASSETS/voidmark" 2>/dev/null && rm -rf "$VOID_DIR"
  fi
  if [[ ! -r "$VOID_DIR/still.png" && -x "$ASSETS/voidmark" ]]; then
    mkdir -p "$VOID_DIR"
    "$ASSETS/voidmark" --out "$VOID_DIR/still.png" && "$ASSETS/voidmark" --transition "$VOID_DIR/open"
  fi
fi
# The password and Touch ID prompts (com.apple.SecurityAgent,
# com.apple.LocalAuthentication.UIAgent) take focus but have no app bundle, so
# `app.<id>` is an invalid image: the icon is left off rather than asked for.
if [[ "$bundle_id" == com.apple.*Agent ]]; then
  icon_args=(icon.drawing=off)
elif [[ -n "$bundle_id" ]]; then
  icon_args=(icon.drawing=on icon.background.image="app.$bundle_id")
elif [[ -r "$VOID_DIR/still.png" ]]; then
  icon_args=(icon.drawing=on icon.background.image="$VOID_DIR/still.png")
else
  icon_args=(icon.drawing=off)
fi

# A new app name crossfades in: the old one fades out for 90ms, the label
# swaps while it is invisible, and the new one fades up while rising 3pt into
# place. The same app with only its brightness changing, focus moving between
# displays, just fades the colour. The last name shown is kept per item in the
# cache, because asking the bar for it would cost a query on every focus event.
STATE="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/front_app/$NAME"
mkdir -p "${STATE:h}"
previous=""
[[ -r "$STATE" ]] && previous=$(<"$STATE")
print -r -- "$app_name" > "$STATE"
# A void arriving starts on its first frame, not on the still it opens into.
if [[ "$app_name" == "$EMPTY_LABEL" && "$previous" != "$app_name" && -r "$VOID_DIR/open/frame-00.png" ]]; then
  icon_args=(icon.drawing=on icon.background.image="$VOID_DIR/open/frame-00.png")
fi

sketchybar --set "$NAME" drawing=on display="$display_id" "${icon_args[@]}"
MOTION="$CONFIG_DIR/assets/motionwatch"
clear_color="0x00${label_color#0x??}"
if [[ "$previous" != "$app_name" ]]; then
  # The icon pops in, a little small and springing to size as the name rises.
  # The void instead opens: its frames, one every 16ms, in the icon's slot,
  # landing on the still.
  icon_motion=("$NAME" icon.background.image.scale $(( APP_ICON_SCALE * 0.6 )) "$APP_ICON_SCALE" 60 420 spring)
  # The icon itself goes through motionwatch as well, not only the --set above.
  # A void opening is 37 image frames queued over 0.6s; back on a busy space
  # inside that window, the --set put the app's icon up and the void's queued
  # frames went on landing after it, so the void stuck. A new tween for the same
  # property replaces what was still queued for it, so this cancels them.
  [[ -n "$bundle_id" && "$bundle_id" != com.apple.*Agent ]] \
    && icon_motion+=("$NAME" icon.background.image = "app.$bundle_id" 0 0 linear)
  if [[ "$app_name" == "$EMPTY_LABEL" && -d "$VOID_DIR/open" ]]; then
    icon_motion=("$NAME" icon.background.image.scale = "$APP_ICON_SCALE" 0 0 linear)
    frame_at=0
    for frame in "$VOID_DIR"/open/frame-*.png(N); do
      icon_motion+=("$NAME" icon.background.image = "$frame" "$frame_at" 0 linear)
      (( frame_at += 16 ))
    done
    icon_motion+=("$NAME" icon.background.image = "$VOID_DIR/still.png" "$frame_at" 0 linear)
  fi
  "$MOTION" tween \
      "${icon_motion[@]}" \
      "$NAME" label.color - "$clear_color" 0 90 out \
      "$NAME" label = "$app_name" 90 0 linear \
      "$NAME" label.y_offset = -3 90 0 linear \
      "$NAME" label.y_offset -3 0 90 240 out \
      "$NAME" label.color "$clear_color" "$label_color" 90 220 out 2>/dev/null \
    || sketchybar --set "$NAME" label="$app_name" label.color="$label_color"
else
  # The name is set every time even when it has not changed, without any
  # animation. The cache outlives the bar: after a reload the items come back
  # empty while the cache still says "same app", and without this set the
  # label stayed blank on every display until focus moved to another app.
  sketchybar --set "$NAME" label="$app_name"
  "$MOTION" tween "$NAME" label.color - "$label_color" 0 200 inout 2>/dev/null \
    || sketchybar --set "$NAME" label.color="$label_color"
fi
