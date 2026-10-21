#!/bin/zsh

# Run by hoverwatch the moment the Claude card opens: a fresh reading, so the
# card does not show numbers up to five minutes old. The badge polls every 300s,
# which is right for a badge nobody is looking at and wrong for a card someone
# has just asked for.
#
# Not more often than every 30 seconds, whatever the clicking: the usage
# endpoint rate-limits hard (HTTP 429), and opening and closing the card a few
# times must not be what trips it. The card fills in place, row by row, without
# resizing: its rows are fixed width (see sketchybarrc).

zmodload zsh/datetime
LAST="$HOME/.cache/sketchybar/claude-usage/last"
[[ -f "$LAST" ]] && (( EPOCHSECONDS - $(stat -f %m "$LAST") < 30 )) && exit 0
NAME=claude exec "${0:A:h}/claude_usage.sh"
