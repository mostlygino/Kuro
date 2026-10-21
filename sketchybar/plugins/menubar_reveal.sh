#!/bin/zsh

# Called by assets/menubarwatch as `menubar_reveal.sh on <strip-height>` when the
# native menu bar reveals, and `off` when it hides again.
#
# Both pills sit exactly under the menu bar's own content, the left one beneath
# the Apple and app menus and the right one beneath the status icons, so both
# have to clear out. What is left behind is a frosted pane for the real menu bar
# to sit on, which is far more readable than menu text over bare wallpaper.
#
# The bar is normally a transparent container with the fill on the brackets, so
# there is nothing to frost until we temporarily give it back a body: full width,
# flush to the top, and exactly as tall as the menu bar strip on the screen the
# pointer is on. That last part is why the height is an argument rather than a
# constant. Guessing it is what made the old blur hang below the menu bar.
#
# `media` is the only item whose text lives in `icon`, so it needs an explicit
# toggle; everything else draws through `label` and is covered by the blanket
# selector. `media_wave` and `claude` are further explicit cases because they
# draw a background image instead of text, and an image is not a label: left to
# the blanket selector they are the one thing still floating over the revealed
# menu bar, on top of the real status icons. `claude` also has a popup, which has
# to be shut rather than hidden; a popup left open belongs to an item that is no
# longer on screen. `media_artist` is a label item; the clock's card is shut like the badges'.
#
# blur_radius is deliberately not touched here; sketchybarrc leaves it on
# permanently. Toggling it caused an intermittent white flash. The pane appears
# and disappears purely by giving the bar a fill and taking it away again.
#
# Nothing here has to care about the notch. The bar sits at the same y on every
# display; only the media items' `position` differs, and that is not touched by
# the reveal. An earlier revision rode `notch_offset` on the built-in, which
# this script did have to zero and restore, because that offset stacks on top of
# y_offset rather than replacing it.

source "$CONFIG_DIR/colors.sh"

STRIP_HEIGHT=${2:-38}

# Pills are hidden before the bar is resized, and shown again only after it has
# been put back, so a stretched full-width pill can never be on screen.
if [[ "$1" == "on" ]]; then
  sketchybar \
    --set '/.*/' label.drawing=off \
    --set media icon.drawing=off \
    --set media_disc background.drawing=off background.image.drawing=off \
    --set media_wave background.drawing=off background.image.drawing=off \
    --set claude background.drawing=off background.image.drawing=off popup.drawing=off \
    --set wifi background.drawing=off background.image.drawing=off popup.drawing=off \
    --set orbstack background.drawing=off background.image.drawing=off popup.drawing=off \
    --set tailscale background.drawing=off background.image.drawing=off popup.drawing=off \
    --set battery background.drawing=off background.image.drawing=off popup.drawing=off \
    --set vitals background.drawing=off background.image.drawing=off popup.drawing=off \
    --set caffeinate background.drawing=off background.image.drawing=off popup.drawing=off \
    --set clock popup.drawing=off \
    --set left_pill background.drawing=off \
    --set media_pill background.drawing=off popup.drawing=off \
    --set right_pill background.drawing=off \
    --set badge_pill background.drawing=off \
    --set '/workspace\..*/' background.drawing=off \
    --bar margin=0 y_offset=0 height="$STRIP_HEIGHT" color="$HOVER_BAR_COLOR"
else
  sketchybar \
    --bar margin=10 y_offset=6 height="$BAR_HEIGHT" color="$TRANSPARENT" \
    --set '/.*/' label.drawing=on \
    --set media icon.drawing=on \
    --set media_disc background.drawing=on background.image.drawing=on \
    --set media_wave background.drawing=on background.image.drawing=on \
    --set claude background.drawing=on background.image.drawing=on \
    --set wifi background.drawing=on background.image.drawing=on \
    --set orbstack background.drawing=on background.image.drawing=on \
    --set tailscale background.drawing=on background.image.drawing=on \
    --set battery background.drawing=on background.image.drawing=on \
    --set vitals background.drawing=on background.image.drawing=on \
    --set caffeinate background.drawing=on background.image.drawing=on \
    --set left_pill background.drawing=on \
    --set media_pill background.drawing=on \
    --set right_pill background.drawing=on \
    --set badge_pill background.drawing=on \
    --set '/workspace\..*/' background.drawing=on
fi
