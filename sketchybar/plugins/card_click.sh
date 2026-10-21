#!/bin/zsh

# What a click on a badge does, in one place.
#
#   card_click.sh <item>
#
# A left click opens that badge's card, or closes it when it is already open.
# A right click, or alt-click, flips the thing the badge is about: keep-awake,
# the VPN, Wi-Fi, or play/pause. Vitals has nothing to flip, so its right
# click opens the Vitals app, the one badge that is a window onto an app.
# Badges with nothing to flip (Claude, battery, OrbStack) just open their card
# on a right click too. It opened apps and
# settings pages until 2026-09-29; those are one click further, in the card.

# Cards opened on hover until 2026-09-29. Hovering near the top of the screen
# also brings the real macOS menu bar down over the bar, which greyed the badges
# out under it and shut whichever card was open; a click is unambiguous.
#
# SketchyBar passes the button to a click script as $BUTTON and the held
# modifier as $MODIFIER.

PLUGINS="${0:A:h}"
item="$1"

toggle_card() {
  exec "${CONFIG_DIR:-$HOME/.config/sketchybar}/assets/hoverwatch" toggle "$item"
}

# The clock is the one the other way round, because a left click on a Mac's clock
# has always been Notification Center: its card, the date and the month, is the
# right-click.
if [[ "$item" == clock ]]; then
  [[ "$BUTTON" != right && "$MODIFIER" != alt ]] && exec "$PLUGINS/notification_center.sh"
  toggle_card
fi

[[ "$BUTTON" != right && "$MODIFIER" != alt ]] && toggle_card

case "$item" in
  caffeinate) exec "$PLUGINS/caffeinate.sh" toggle ;;
  tailscale)  exec "$PLUGINS/tailscale.sh" toggle ;;
  wifi)       exec "$PLUGINS/wifi.sh" toggle ;;
  media_pill) exec /opt/homebrew/bin/media-control toggle-play-pause ;;
  vitals)     exec "$PLUGINS/vitals.sh" open ;;
  *)          toggle_card ;;
esac
