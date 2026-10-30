#!/bin/zsh

# The one place the bar talks to AeroSpace: every workspace chip and every
# per-display app label, updated in a single pass.
#
# Each of those fourteen items used to run its own script and ask AeroSpace
# for itself, so one monitor change fired about twenty `aerospace` calls at
# once, all while macOS was still rearranging the displays. That is exactly
# the race behind AeroSpace's crash on monitor changes (issue #506 upstream):
# a command lands mid-reconfiguration and `Monitor.activeWorkspace` recurses
# until the stack runs out. With three screens it happened for real.
#
# So now: one script, subscribed once, asking once, one call after another.
# After a display change it first waits for the monitor set to settle, and
# overlapping triggers collapse into a single pass.

source "$CONFIG_DIR/colors.sh"

AEROSPACE=/opt/homebrew/bin/aerospace
LOCK="${TMPDIR:-/tmp}/sketchybar-aerospace-sync.lock"
# How long a display change is given to finish before AeroSpace is asked
# anything. macOS reports a new arrangement in several steps over about a
# second; asking between them is the dangerous part.
SETTLE=1.5

# Which workspaces were visible after the last pass, so a switch can tell the
# chip that is arriving from the one that is leaving.
VISIBLE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/aerospace-visible"
# Each display's last numbered workspace, `display sid` a line. Looking at an
# agent space hides that workspace, and an empty one hidden is gone: AeroSpace
# drops it, and with it the display's only chip. The bar keeps it drawn.
HOME_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/aerospace-home"
# Each display's last chip after the last pass, `display sid` a line, which the
# fast path reads to move the app over with the chip.
LAST_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/aerospace-last"

# The app label's gap on a display, glided there on the chip's own spring when
# it widens and eased back when it narrows. Prints tween arguments, or nothing
# when the label already has it. Asked of the bar rather than remembered, so a
# reload, which puts every padding back to its default, cannot leave a stale
# answer behind.
app_gap_tween() {
  local did=$1 gap=$2 now
  now=$(sketchybar --query "front_app.$did" 2>/dev/null | grep -m1 -o '"padding_left":[ ]*[0-9.-]*')
  [[ "${now##*[: ]}" == "$gap" ]] && return
  if [[ "$gap" == "$APP_GAP_AFTER_CHIP" ]]; then
    print -r -- "front_app.$did padding_left - $gap 0 420 spring"
  else
    print -r -- "front_app.$did padding_left - $gap 0 220 out"
  fi
}

# The fast path. A workspace switch arrives with the new workspace in it, so its
# chip starts growing now, before a single question to AeroSpace, instead of
# after the full pass below has asked its three. Only for a workspace that was
# not already visible: focus moving to another display's workspace moves no
# chip. The pass below then sees it as already arrived and only shrinks the
# chip that left.
if [[ "$SENDER" == aerospace_workspace_change && -n "$FOCUSED_WORKSPACE" ]]; then
  shown=" "
  [[ -r "$VISIBLE_FILE" ]] && shown=" $(<"$VISIBLE_FILE") "
  if [[ "$shown" != *" $FOCUSED_WORKSPACE "* ]]; then
    print -r -- "${${shown# }% } $FOCUSED_WORKSPACE" > "$VISIBLE_FILE"
    # The app beside the chips moves with the chip: over, if the chip landing
    # is its display's last, back, if the display's last is no longer it.
    gap_args=()
    if [[ -r "$LAST_FILE" ]]; then
      for line in "${(@f)$(<"$LAST_FILE")}"; do
        [[ "${line#* }" == "$FOCUSED_WORKSPACE" ]] && gap_args=(${=$(app_gap_tween "${line%% *}" "$APP_GAP_AFTER_CHIP")})
      done
    fi
    "$CONFIG_DIR/assets/motionwatch" tween \
      "workspace.$FOCUSED_WORKSPACE" label.color - "$ACTIVE_TEXT" 0 200 inout \
      "workspace.$FOCUSED_WORKSPACE" background.color - "$ACTIVE_FILL" 0 160 out \
      "workspace.$FOCUSED_WORKSPACE" background.height "$CHIP_FROM" "$CHIP_HEIGHT" 0 420 spring \
      "workspace.$FOCUSED_WORKSPACE" background.corner_radius $(( CHIP_FROM / 2.0 )) $(( CHIP_HEIGHT / 2.0 )) 0 420 spring \
      "${gap_args[@]}" \
      2>/dev/null &!
  fi
fi

# One pass at a time. A second trigger while one runs marks the pass dirty, so
# the running one goes round once more instead of both talking to AeroSpace.
# The holder can let go between our mkdir and our touch; then the touch fails
# and this trigger runs the pass itself rather than being lost.
if ! mkdir "$LOCK" 2>/dev/null; then
  touch "$LOCK/again" 2>/dev/null && exit 0
  mkdir "$LOCK" 2>/dev/null || { touch "$LOCK/again" 2>/dev/null; exit 0; }
fi
trap 'rm -rf "$LOCK"' EXIT

[[ "$SENDER" == display_change || "$SENDER" == system_woke ]] && sleep "$SETTLE"

pgrep -xq AeroSpace || exit 0

# Which screen each of the ten workspaces lives on. One screen holds all ten;
# more share them out in order, the main screen first and the rest left to
# right, as evenly as ten will go: two screens 1-5 and 6-10, three 1-4, 5-7
# and 8-10, four 1-3, 4-6, 7-8 and 9-10. So a workspace number always means the
# same screen, and ⌘6 on a two-screen desk is the second screen.
#
# AeroSpace's own workspace-to-monitor-force-assignment cannot say this: its
# patterns are fixed, and "1-5 with two screens but 1-4 with three" is not a
# pattern. So the bar does it, here, where AeroSpace is already asked one thing
# at a time after the displays have settled.
#
# Everything is rebalanced when the set of screens changes (checked on a screen
# change, on wake and at start) and when kuro.sh asks for it (`forced`);
# otherwise only a workspace that has just been created is placed, so one you
# moved by hand with ⌘⇧⌥ + arrow stays where you put it until the next change.
KNOWN_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/aerospace-workspaces"
# The screens the last full rebalance was for. A wake or a bar reload with the
# same screens is not a screen change: until 2026-10-30 each one rebalanced
# anyway, switching what every screen showed and, through focus-monitor and
# on-focused-monitor-changed, throwing the pointer from screen to screen. With
# the bar reloading after every wake that was most of what "Kuro keeps
# crashing my displays" was.
SCREENS_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/aerospace-screens"

place_workspaces() {
  local monitors main others=() order=() line id is_main n base extra ws=1 i k size
  monitors=$("$AEROSPACE" list-monitors --format '%{monitor-id}|%{monitor-is-main}|%{monitor-name}' 2>/dev/null)
  [[ -n "$monitors" ]] || return
  for line in "${(@f)monitors}"; do
    id="${line%%|*}" is_main="${${line#*|}%%|*}"
    if [[ "$is_main" == true ]]; then main="$id"; else others+=("$id"); fi
  done
  [[ -n "$main" ]] || return
  order=("$main" "${(@on)others}")
  n=${#order}
  (( n > 1 )) || return
  local -A target
  base=$(( 10 / n )) extra=$(( 10 % n ))
  for (( i = 1; i <= n; i++ )); do
    size=$(( base + (i <= extra ? 1 : 0) ))
    for (( k = 0; k < size; k++ )); do target[$ws]="${order[$i]}"; (( ws++ )); done
  done

  local listing known=" " current=" " name monitor rest visible
  listing=$("$AEROSPACE" list-workspaces --all --format '%{workspace}|%{monitor-id}|%{workspace-is-visible}' 2>/dev/null)
  [[ -r "$KNOWN_FILE" ]] && known=" $(<"$KNOWN_FILE") "
  local everything=false screens
  screens="${(j: :)${(@o)${(f)monitors}}}"
  if [[ "$SENDER" == forced ]]; then
    everything=true
  elif [[ "$SENDER" == display_change || "$SENDER" == system_woke || -z "$SENDER" ]]; then
    [[ -r "$SCREENS_FILE" && "$(<"$SCREENS_FILE")" == "$screens" ]] || everything=true
  fi
  [[ "$everything" == true ]] && print -r -- "$screens" > "$SCREENS_FILE"
  for line in "${(@f)listing}"; do
    name="${line%%|*}" rest="${line#*|}"
    monitor="${rest%%|*}" visible="${rest##*|}"
    if [[ -n "${target[$name]:-}" && "$monitor" != "${target[$name]}" ]] \
        && [[ "$everything" == true || "$known" != *" $name "* ]]; then
      # Never a workspace a screen is showing. Moving one makes AeroSpace find
      # the screen another workspace in the same breath, and that is the path
      # that crashes it (upstream #506): on 2026-09-30, with three screens, it
      # went down thirteen times in a row, each restart handing out 1, 2 and 3
      # one per screen and this pass moving the visible ones straight back
      # into the crash. A visible one is left where it is and not counted as
      # known, so it is placed the first time it is hidden.
      if [[ "$visible" == true ]]; then
        continue
      fi
      "$AEROSPACE" move-workspace-to-monitor --workspace "$name" "${target[$name]}" 2>/dev/null
      # One move at a time, with room for AeroSpace to settle between them.
      sleep 0.15
    fi
    current+="$name "
  done
  print -r -- "${${current# }% }" > "$KNOWN_FILE"

  # A full rebalance also puts each screen on a workspace of its own, one screen
  # at a time, main first. A screen showing someone else's is switched to one of
  # its own, which hides the stranger, and the stranger goes straight home while
  # hidden. Switching is an ordinary workspace change, the thing AeroSpace does
  # all day; it is only moving a visible workspace that brings it down.
  #
  # The own workspace switched to must already be on that screen, or not exist
  # yet. One that is there is switched to; one that does not exist is summoned,
  # because `workspace N` makes a new workspace on the main screen whichever
  # screen has focus (seen on 2026-10-01: from the MSI it put 6 on the
  # ultrawide), and `summon-workspace N` makes it on the focused one. Never one
  # that lives on another screen: switching to that shows it over there. Going a screen at a time is
  # what makes that rule enough: main first parks its stranger, say 6, on the
  # second screen, so by the time the second screen is looked at, 6 is its own.
  #
  # Focus goes back to the screen it was on, not to the workspace: that
  # workspace may just have moved to another screen.
  #
  # Once per run of this script, never again in its loop: the switches below
  # are workspace changes, each one triggers this script, and those triggers
  # land as another round of the loop. On 2026-09-30 a screen that had just
  # gone away kept its old id for a moment, the switch to it went nowhere, and
  # every round tried again, switching focus back and forth for as long as it
  # ran.
  [[ "$everything" == true && -z "$REBALANCED" ]] || return
  REBALANCED=1
  local focused_monitor shown pick where acted=false
  local -A lives
  focused_monitor=$("$AEROSPACE" list-monitors --focused --format '%{monitor-id}' 2>/dev/null)
  for (( i = 1; i <= n; i++ )); do
    id="${order[$i]}"
    shown=$("$AEROSPACE" list-workspaces --monitor "$id" --visible 2>/dev/null)
    [[ -n "$shown" && -n "${target[$shown]:-}" && "${target[$shown]}" != "$id" ]] || continue
    # Asked again for every screen: the move for the last one changed it.
    lives=()
    for line in "${(@f)$("$AEROSPACE" list-workspaces --all --format '%{workspace}|%{monitor-id}' 2>/dev/null)}"; do
      lives[${line%%|*}]=${line##*|}
    done
    pick=""
    for (( ws = 1; ws <= 10; ws++ )); do
      [[ "${target[$ws]}" == "$id" ]] || continue
      where="${lives[$ws]:-}"
      if [[ -z "$where" || "$where" == "$id" ]]; then pick=$ws; break; fi
    done
    [[ -n "$pick" ]] || continue
    "$AEROSPACE" focus-monitor "$id" 2>/dev/null || continue
    if [[ -n "${lives[$pick]:-}" ]]; then
      "$AEROSPACE" workspace "$pick" 2>/dev/null || continue
    else
      "$AEROSPACE" summon-workspace "$pick" 2>/dev/null || continue
    fi
    acted=true
    sleep 0.15
    # Sent home only once it is truly hidden, asked rather than assumed: the
    # switch above going somewhere else is exactly how a visible workspace got
    # moved on 2026-10-01. An empty one AeroSpace has already dropped needs no
    # move at all.
    [[ "$("$AEROSPACE" list-workspaces --monitor "$id" --visible 2>/dev/null)" != "$shown" ]] || continue
    "$AEROSPACE" list-workspaces --all 2>/dev/null | grep -qx -- "$shown" || continue
    "$AEROSPACE" move-workspace-to-monitor --workspace "$shown" "${target[$shown]}" 2>/dev/null
    sleep 0.15
  done
  [[ "$acted" == true && -n "$focused_monitor" ]] && "$AEROSPACE" focus-monitor "$focused_monitor" 2>/dev/null
}

update_workspaces() {
  local listing occupied sid display visible label_color fill_color gap args=()
  listing=$("$AEROSPACE" list-workspaces --all \
    --format '%{workspace}|%{monitor-appkit-nsscreen-screens-id}|%{workspace-is-visible}' 2>/dev/null)
  [[ -n "$listing" ]] || return
  # One more question, still one at a time: which workspaces have windows.
  occupied=" ${(f)$("$AEROSPACE" list-workspaces --monitor all --empty no 2>/dev/null)} "
  occupied="${occupied//$'\n'/ }"

  local -A known
  for line in "${(@f)listing}"; do
    sid="${line%%|*}"
    known[$sid]="${line#*|}"
  done

  local was=" " now=" "
  [[ -r "$VISIBLE_FILE" ]] && was=" $(<"$VISIBLE_FILE") "
  # Per display, in chip order: the last chip drawn, and the one that is focused.
  local -A last focused

  # The agent spaces in view, by display, and how many hold windows at all.
  local -A agent home
  local busy=0
  for sid in F{1..12}; do
    [[ "$occupied" == *" $sid "* ]] && (( busy++ ))
    [[ "${known[$sid]:-}" == *"|true" ]] && agent[${known[$sid]%%|*}]=$sid
  done
  if [[ -r "$HOME_FILE" ]]; then
    for line in "${(@f)$(<"$HOME_FILE")}"; do home[${line%% *}]=${line#* }; done
  fi
  for sid in {1..10} S; do
    [[ "${known[$sid]:-}" == *"|true" ]] && home[${known[$sid]%%|*}]=$sid
  done
  # Never seen a number yet, as after a restart straight onto an agent space:
  # the main display's home is 1.
  [[ -n "${agent[1]:-}" && -z "${home[1]:-}" ]] && home[1]=1

  for sid in {1..10} S; do
    if [[ -z "${known[$sid]:-}" ]]; then
      # A display on an agent space keeps the chip it came from, empty, so
      # its numbers never all go and one click takes it home.
      for display in ${(k)agent}; do
        [[ "${home[$display]:-}" == "$sid" ]] && known[$sid]="$display|false"
      done
    fi
    if [[ -z "${known[$sid]:-}" ]]; then
      args+=(--set "workspace.$sid" drawing=off)
      continue
    fi
    display="${known[$sid]%%|*}"
    visible="${known[$sid]##*|}"
    last[$display]=$sid
    [[ "$visible" == true ]] && focused[$display]=$sid
    # Visible workspace inverts: solid light chip, dark digit. Everything else
    # is a bare digit, muted with windows on it and darker without, its chip
    # the fill colour at zero alpha so the fade dims the white away instead of
    # passing it through grey.
    if [[ "$visible" == true ]]; then
      label_color="$ACTIVE_TEXT" fill_color="$ACTIVE_FILL"
      now+="$sid "
    elif [[ "$occupied" == *" $sid "* ]]; then
      label_color="$MUTED_COLOR" fill_color="0x00${ACTIVE_FILL#0x??}"
    else
      label_color="$WORKSPACE_EMPTY_COLOR" fill_color="0x00${ACTIVE_FILL#0x??}"
    fi
    args+=(--set "workspace.$sid" drawing=on display="$display")
    fallback+=(--set "workspace.$sid" label.color="$label_color" background.color="$fill_color")
    if [[ "$visible" == true && "$was" != *" $sid "* ]]; then
      # Arriving: the chip grows out of the digit on a spring while it fades
      # up, so the switch reads as the selection landing here.
      tweens+=("workspace.$sid" label.color - "$label_color" 0 200 inout
               "workspace.$sid" background.color - "$fill_color" 0 160 out
               "workspace.$sid" background.height "$CHIP_FROM" "$CHIP_HEIGHT" 0 420 spring
               "workspace.$sid" background.corner_radius $(( CHIP_FROM / 2.0 )) $(( CHIP_HEIGHT / 2.0 )) 0 420 spring)
    elif [[ "$visible" != true && "$was" == *" $sid "* ]]; then
      # Leaving: it shrinks as it fades, and is put back to full size once
      # it is invisible, ready for the next time.
      tweens+=("workspace.$sid" label.color - "$label_color" 0 200 inout
               "workspace.$sid" background.color - "$fill_color" 0 200 out
               "workspace.$sid" background.height "$CHIP_HEIGHT" "$CHIP_FROM" 0 200 out
               "workspace.$sid" background.corner_radius $(( CHIP_HEIGHT / 2.0 )) $(( CHIP_FROM / 2.0 )) 0 200 out
               "workspace.$sid" background.height = "$CHIP_HEIGHT" 210 0 linear
               "workspace.$sid" background.corner_radius = $(( CHIP_HEIGHT / 2.0 )) 210 0 linear)
    else
      tweens+=("workspace.$sid" label.color - "$label_color" 0 180 inout
               "workspace.$sid" background.color - "$fill_color" 0 180 inout)
    fi
  done
  # The agent chip: solid TestFlight blue with the space's name where one is in
  # view, a quiet propeller and a count on the main display while agents have
  # windows out of sight, nothing otherwise.
  local main_display=1
  for display in 1 2 3; do
    if [[ -n "${agent[$display]:-}" ]]; then
      args+=(--set "workspace.agent.$display" drawing=on label="${agent[$display]}" label.drawing=on
             icon.color=0xffffffff label.color=0xffffffff background.color="$AGENT_BLUE")
      last[$display]=agent focused[$display]=agent
    elif (( display == main_display && busy > 0 )); then
      args+=(--set "workspace.agent.$display" drawing=on label="$busy" label.drawing=on
             icon.color="$AGENT_BLUE" label.color="$AGENT_BLUE" background.color="$AGENT_TINT")
      last[$display]=agent
    else
      args+=(--set "workspace.agent.$display" drawing=off)
    fi
  done
  sketchybar "${args[@]}"
  print -r -- "${now# }" > "$VISIBLE_FILE"
  : > "$HOME_FILE.tmp"
  for display in ${(k)home}; do print -r -- "$display ${home[$display]}" >> "$HOME_FILE.tmp"; done
  mv "$HOME_FILE.tmp" "$HOME_FILE"
  # Each app label's gap, from whether its display's last chip is the focused one.
  : > "$LAST_FILE.tmp"
  for display in ${(k)last}; do
    print -r -- "$display ${last[$display]}" >> "$LAST_FILE.tmp"
    gap=$APP_GAP
    [[ "${last[$display]}" == "${focused[$display]:-}" ]] && gap=$APP_GAP_AFTER_CHIP
    tweens+=(${=$(app_gap_tween "$display" "$gap")})
    fallback+=(--set "front_app.$display" padding_left="$gap")
  done
  mv "$LAST_FILE.tmp" "$LAST_FILE"
}

while true; do
  rm -f "$LOCK/again"
  tweens=() fallback=()
  place_workspaces
  update_workspaces
  if (( ${#tweens} )); then
    "$CONFIG_DIR/assets/motionwatch" tween "${tweens[@]}" 2>/dev/null \
      || sketchybar "${fallback[@]}"
  fi
  # The app labels, one display after another rather than three at once.
  for did in 1 2 3; do
    NAME="front_app.$did" "${0:A:h}/front_app.sh" "$did"
  done
  # The workspace pill may have changed width, and the Now Playing title is
  # fitted to the room after it: tell the player to re-fit, once the label
  # swap has landed (it swaps 90ms into its crossfade).
  ( sleep 0.15; "$CONFIG_DIR/assets/mediawatch.app/Contents/MacOS/mediawatch" --refit ) >/dev/null 2>&1 &!
  [[ -e "$LOCK/again" ]] || break
  # A round caused by triggers during this one is an ordinary pass, not another
  # rebalance.
  SENDER=aerospace_sync_again
done
