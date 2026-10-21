#!/bin/zsh

# Run by hoverwatch the moment the transport strip opens.
#
# The strip's play/pause glyph cannot be kept fresh by an event: SketchyBar's
# `media_change` never fires on macOS 26, verified with a probe item across a
# play and a pause, because MediaRemote is locked down. Polling it on a timer
# would mean asking the player every few seconds for a button nobody is looking
# at. Reading it once, as the card appears, is the whole of what is needed.

exec "${0:A:h}/media_controls.sh" refresh
