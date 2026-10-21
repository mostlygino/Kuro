#!/bin/zsh

# Gives a window an agent opened a hidden workspace of its own, F1 to F12.
#
# AeroSpace runs this from aerospace.toml's on-window-detected rules, after it
# has already put the window on F1, off screen, with the window's id in
# AEROSPACE_WINDOW_ID. A window joins the agent space its own process already
# has, so one browser's tabs and popups stay together; a new process takes the
# first agent space with nothing on it. With all twelve busy it stays on F1.
#
# `agent_space.sh claim` is the catch-all rule's, for every other new window:
# it moves the window only if an agent opened its app moments ago through
# plugins/agent_open.sh, which left a claim on it; anything else stays put.

AEROSPACE=/opt/homebrew/bin/aerospace

# `agent_space.sh next`, the agent chip's click: the next agent space with
# windows after the one in view, round to the first.
if [[ "$1" == next ]]; then
  busy=(${(f)"$("$AEROSPACE" list-workspaces --monitor all --empty no 2>/dev/null | grep -x 'F[0-9]*' | sort -V)"})
  (( ${#busy} )) || exit 0
  here=$("$AEROSPACE" list-workspaces --focused 2>/dev/null)
  next="${busy[1]}"
  for (( i = 1; i < ${#busy}; i++ )); do
    [[ "${busy[$i]}" == "$here" ]] && { next="${busy[$(( i + 1 ))]}"; break; }
  done
  exec "$AEROSPACE" workspace "$next"
fi

window="$AEROSPACE_WINDOW_ID"
[[ -n "$window" ]] || exit 0

# How long a claim holds: an app's first window can take a while to come up,
# a build launching cold in particular.
CLAIM_FOR=60
CLAIMS="${XDG_CACHE_HOME:-$HOME/.cache}/kuro/agent-claims"
if [[ "$1" == claim ]]; then
  # The common case, no agent opening anything: one directory read and out.
  claimed=("$CLAIMS"/*(N))
  (( ${#claimed} )) || exit 0
fi

listing=$("$AEROSPACE" list-windows --all --format '%{window-id}|%{app-pid}|%{workspace}|%{app-bundle-id}' 2>/dev/null)
[[ -n "$listing" ]] || exit 0

pid="" here="" bundle="" busy=" " target=""
for line in "${(@f)listing}"; do
  fields=("${(@s:|:)line}")
  [[ "${fields[1]}" == "$window" ]] && { pid="${fields[2]}" here="${fields[3]}" bundle="${fields[4]}"; break; }
done
[[ -n "$pid" ]] || exit 0

if [[ "$1" == claim ]]; then
  zmodload zsh/datetime
  claim="$CLAIMS/$bundle"
  [[ -n "$bundle" && -r "$claim" ]] || exit 0
  (( EPOCHSECONDS - $(<"$claim") <= CLAIM_FOR )) || { rm -f "$claim"; exit 0; }
fi

for line in "${(@f)listing}"; do
  fields=("${(@s:|:)line}")
  id="${fields[1]}" owner="${fields[2]}" space="${fields[3]}"
  [[ "$id" == "$window" || "$space" != F<1-12> ]] && continue
  [[ "$owner" == "$pid" ]] && target="$space"
  busy+="$space "
done

if [[ -z "$target" ]]; then
  for n in {1..12}; do
    [[ "$busy" == *" F$n "* ]] || { target="F$n"; break; }
  done
fi
[[ -n "$target" && "$target" != "$here" ]] || exit 0
"$AEROSPACE" move-node-to-workspace --window-id "$window" "$target" 2>/dev/null
