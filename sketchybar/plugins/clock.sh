#!/bin/zsh

# The time on the bar, and the clock card: today, the week, the day of the year,
# the month drawn by assets/monthmark, and a row that opens the calendar.
#
# The week number and the date were on the bar beside the time until
# 2026-09-29. They are in the card now, which a right-click on the time opens.
#
# %V is the ISO 8601 week number, which is the one meant by "weeknummer" here.
# %U and %W are not interchangeable: both read 36 on the same day %V reads 37,
# because they count from a Sunday and from the first Monday of the year rather
# than by the ISO rule. A year has 52 ISO weeks or 53, and 28 December is always
# in the last one, so its %V is the count.
#
# One `date` call for everything, so no part of the card can come from one
# minute and another part from the next.

ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
RENDERER="$ASSETS/monthmark"
CACHE_DIR="$HOME/.cache/sketchybar/clock"

parts=("${(@f)$(/bin/date '+%-I:%M
%A
%-d %B
%V
%j
%Y
%F')}")
time=${parts[1]} weekday=${parts[2]} date=${parts[3]} week=${parts[4]#0}
day=${parts[5]} year=${parts[6]} today=${parts[7]}
weeks=$(/bin/date -j -f %F "$year-12-28" +%V)
days=$(( (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 366 : 365 ))

args=(--set clock label="$time"
      --set clock.today icon="$weekday" label="$date"
      --set clock.week icon="Week" label="$week of $weeks"
      --set clock.year icon="Day of the year" label="$(( 10#$day )) of $days"
      --set clock.calendar icon="Your calendar" label="Open")

# The month is drawn once a day, not every tick, to a file named for the day it
# shows: a stale one is simply not found, and SketchyBar, which keeps an image
# by its path, never shows yesterday's month under today's date.
MONTH="$CACHE_DIR/month-$today.png"
mkdir -p "$CACHE_DIR"
if [[ ! -x "$RENDERER" || "$ASSETS/monthmark.swift" -nt "$RENDERER" ]]; then
  /usr/bin/xcrun swiftc -O "$ASSETS/monthmark.swift" -o "$RENDERER" 2>/dev/null \
    || echo "clock.sh: cannot build monthmark, the card has no month" >&2
  rm -f "$MONTH"
fi
if [[ -x "$RENDERER" && ! -f "$MONTH" ]]; then
  "$RENDERER" --date "$today" --out "$MONTH"
  find "$CACHE_DIR" -name 'month-*.png' ! -name "${MONTH:t}" -delete
fi
[[ -f "$MONTH" ]] && args+=(--set clock.month background.image="$MONTH")

sketchybar "${args[@]}"
