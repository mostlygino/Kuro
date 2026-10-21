#!/bin/zsh

# Fills a popup from a detail file. Shared by every item that has one, because
# the file format and the two traps below are worth writing down once.
#
#   popup_rows.sh <file>
#
# The file is one row per line, tab-separated: item name, icon text, label text,
# and optionally a label colour as 0xAARRGGBB. The producing plugin writes it on
# its own poll, so opening a popup never waits on whatever the value came from.
#
# The colour exists for one job: saying which row a badge is actually following
# when it follows the worst of several. Without it the Claude card showed 2% on
# one line and 17% on another with no way to tell which one the burst was drawn
# from, and the answer looked like a bug.
#
# One `sketchybar` call for the whole file rather than one per row. A popup is
# laid out from its members, so setting them one at a time lets a half-filled
# card reach the screen.
#
# A row that splits into neither three fields nor four is skipped rather than
# applied, and a missing or unreadable file leaves every row alone. Both cases
# mean the same thing, that the producer has not run yet or was interrupted
# mid-write, and in both the last good values are better than blanks.

file="$1"
[[ -n "$file" && -r "$file" ]] || exit 0

IFS=$'\n' rows=($(<"$file"))

args=()
for row in "${rows[@]}"; do
  # `p` on the split flag, or the separator is a literal backslash-t rather than
  # a tab, every line comes back as one field, and the popup silently blanks.
  fields=("${(@ps:\t:)row}")
  (( ${#fields} == 3 || ${#fields} == 4 )) || continue
  args+=(--set "${fields[1]}" icon="${fields[2]}" label="${fields[3]}")
  (( ${#fields} == 4 )) && args+=(label.color="${fields[4]}")
done

[[ ${#args} -gt 0 ]] && sketchybar "${args[@]}"
exit 0
