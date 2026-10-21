#!/bin/zsh

# Clicking the app name presses hyper + M for whatever is listening for it
# (Raycast, say). Not wired to anything by default: point FRONT_APP_CLICK at it
# in local.sh to use it. Hyper here is the usual all-four stack:
# control + option + command + shift. Key code 46 is M on any layout, because
# key codes are physical positions rather than characters.
#
# This *synthesises a keystroke*, which is the fragile way to do it. It needs
# Accessibility permission for the process that runs it, which is sketchybar,
# not this script and not Terminal:
#
#   System Settings > Privacy & Security > Accessibility > SketchyBar
#
# Without that the keystroke is silently dropped, with no error anywhere, which
# is why the failure is logged here rather than swallowed. If hyper + M turns
# out to map to a command that can be invoked directly, call that instead and
# delete this: a direct call needs no permission and cannot land in the wrong
# window if focus moves between the click and the keystroke.
if ! /usr/bin/osascript -e 'tell application "System Events" to key code 46 using {control down, option down, command down, shift down}' 2>/dev/null; then
  echo "hyper_m.sh: keystroke refused, check Accessibility permission for sketchybar" >&2
  exit 1
fi
