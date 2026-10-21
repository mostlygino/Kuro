#!/bin/zsh

# Run by hoverwatch the moment the battery card opens. The badge polls once a
# minute, so the draw and the time left could be most of a minute old by the
# time the card was read; this reads them as it appears.

NAME=battery exec "${0:A:h}/battery.sh"
