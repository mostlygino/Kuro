#!/bin/zsh

# Claude Code usage as a burst that goes out ray by ray.
#
# The number comes from the same endpoint Claude Code's own /usage command
# reads, api.anthropic.com/api/oauth/usage, authorised with the OAuth access
# token Claude Code keeps in the login keychain under "Claude Code-credentials".
# Nothing else on this machine knows the real limit: ccusage and friends can
# only add up tokens from the session logs and guess at a ceiling, and a battery
# drawn against a guessed ceiling is a decoration, not a gauge.
#
# The mark shows what is LEFT, not what is spent, so it goes dark as the session
# fills up. Two windows are published, a five-hour session and a rolling seven
# days, and the badge follows the session.
#
# It followed the worse of the two at first, on the reasoning that the weekly cap
# is what stops you on the day it binds. In use that was simply wrong: the week
# creeps up over days and sits at some middling number all week, so the badge
# spent its life reporting the week while the thing anyone glances at it for is
# the session in front of them. Three percent into a session and a ray already
# out is not a gauge, it is a puzzle.
#
# The badge is the session and only the session. The week took it over past 80%
# until 2026-10-02, as a backstop against a weekly wall behind a full-looking
# burst, and in practice that meant a fresh session (6% used) showing a nearly
# spent burst because the week stood at 80%: it read as a stale badge. The week
# stays in the card, one click away.
#
# The mark itself is a PNG drawn by assets/usagemark, not a font glyph. Read that
# file for why it is a burst rather than the battery it started as. One image per
# percent and colour, cached by filename and only rendered on a miss, so a steady
# tick costs one `--set` and nothing else.
#
# Colors are literal hex rather than the colors.sh exports, for the reason
# spelled out in tailscale.sh: a periodic plugin is spawned by the daemon and
# does not inherit the rc's shell environment.
#
# The token is read fresh on every tick and never written anywhere. Claude Code
# owns refreshing it; this script only ever reads. First run prompts for
# keychain access, because the credential's ACL lists Claude Code and not
# SketchyBar. Answer "Always Allow" once.
#
# A failed lookup leaves whatever is already on the bar rather than hiding the
# badge. It used to hide, and that was wrong twice over: a single missed poll
# made the badge vanish for the two minutes until the next one, and a badge that
# disappears reads as a bug rather than as a network hiccup. The number it keeps
# showing is at most one poll old, and the card behind it carries the reset times
# that say how much that matters.
#
# The badge is only ever hidden before it has drawn anything at all, which is the
# one case with nothing to keep. The mark has no honest way to say "unknown":
# drawing an unlit burst would read as "out of usage", the opposite of what a
# failed lookup means.
#
# A `--reload` builds every item from scratch, so "keep the last mark" has
# nothing to keep across one: the item comes back with no image. The last good
# reading is therefore written to `last` in the cache as plain text, restored
# before the network is touched at all, and re-rendered from scratch if its PNG
# is gone. That file is the one thing in the cache a rebuild does not delete,
# because a changed shape makes the old images wrong while the reading behind
# them is still the truth.
#
# A reading that cannot be refreshed turns the whole burst red, every ray lit.
# The badge is read to decide whether to keep working, and an hour-old number in
# the live colour is the one failure that actually costs something, because it
# looks exactly like a fresh one.
#
# All eight rays on purpose, rather than the last count in red. What has failed
# is the number itself, so drawing a level at all would be the lie; a full red
# asterisk says "no idea, and I cannot find out". It also cannot be confused with
# the other red on this badge, which is a single ray at under a tenth left: one
# ray red means nearly out, the whole mark red means nothing got through.
#
# Except once the session window it was measured in has expired, which is the
# normal state of every morning. A reading from last night is not unknown, it is
# void: the five-hour window rolled over while the machine slept and the session
# is empty by definition. So `last` carries the reset time it was taken against,
# and past that moment the badge draws full in the live colour rather than grey.
# Greying the one reading that is certainly right, on the morning it is most
# obviously right, made the badge look broken at its best moment.

zmodload zsh/datetime

ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
RENDERER="$ASSETS/usagemark"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/claude-usage"
# The two numbers behind the badge, written by every poll and read by every
# hover. Hover has to be instant, and the popup would otherwise sit empty for as
# long as a network round trip takes, so it never asks the endpoint itself.
DETAIL_FILE="$CACHE_DIR/detail"
LAST_FILE="$CACHE_DIR/last"
# Every failed poll, one line each: when, and why. Kept to the last 200 lines.
LOG_FILE="$CACHE_DIR/poll.log"
# When the token was last handed to Claude Code for a refresh, so a machine
# that stays logged out does not start Claude Code every five minutes.
REFRESH_STAMP="$CACHE_DIR/.refreshed"
REFRESH_EVERY=600

# How long a reading stays believable. Twenty minutes is ten missed polls: long
# enough that a flaky minute never greys the badge, short enough that nobody
# plans a session around it.
STALE_AFTER=1200
# Duplicated from the python below, which cannot hand it back before it runs.
CLAUDE_COLOR=0xffd97757


# Hide only with nothing to fall back on, and report failure while doing it, so
# the retry loop in sketchybarrc can tell a bad first attempt from a good one.
#
# "Nothing to fall back on" means no reading has ever been taken: no `last`
# file. Whenever there is one, the restore step above has already put it on the
# bar, so there is always something honest to show.
#
# It used to ask the bar instead, with `--query`, whether an image was drawn.
# That query comes back empty now and then while the bar is busy, and an empty
# answer read as "nothing drawn": one failed poll landing on one failed query
# hid a badge that was showing a perfectly good reading, overnight, until the
# next poll that happened to succeed.
give_up() {
  local code=${1:-1}
  [[ -r "$LAST_FILE" ]] || sketchybar --set claude drawing=off
  exit "$code"
}

source "${0:A:h}/motion.sh"

# Self-building, the pattern every renderer here follows: the binary is not in the repo, and editing the
# geometry in usagemark.swift should take effect on the next tick without anyone
# remembering a compile step. Cached renders are stale the moment the source
# changes, so they go with it.
if [[ ! -x "$RENDERER" || "$ASSETS/usagemark.swift" -nt "$RENDERER" ]]; then
  if /usr/bin/xcrun swiftc -O "$ASSETS/usagemark.swift" -o "$RENDERER" 2>/dev/null; then
    rm -f "$CACHE_DIR"/mark-*.png
    motion_purge "$CACHE_DIR"
  else
    echo "claude_usage.sh: cannot build usagemark, leaving the mark as it is" >&2
    give_up
  fi
fi

# Silence by default, because a plugin's stderr goes nowhere useful and a failed
# poll is not news. `CLAUDE_USAGE_DEBUG=1` opens it back up, which is the only
# way to find out why a badge went missing.
error_sink=/dev/null
[[ -n "$CLAUDE_USAGE_DEBUG" ]] && error_sink=/dev/stderr

# Draw a reading. plugins/motion.sh caches the still and the move from
# the last reading by key, and only calls back here for what is missing.
# The key is "<percent>-<colour>", which is also how a transition learns what it
# is animating from.
# The key is "<percent>-<colour>", "error" when nothing has got through
# for long enough that the last reading cannot be trusted, or "blocked" when the
# weekly limit is spent.
render_mark() {
  local mode="$1" target="$3" from="$4" args
  case "$2" in
    error|blocked) args=(--$2) ;;
    *) args=(--percent "${2%%-*}" --color "${2#*-}") ;;
  esac
  case "$mode" in
    still) "$RENDERER" "${args[@]}" --out "$target" ;;
    transition)
      case "$from" in
        error|blocked) args+=(--from-$from) ;;
        *) args+=(--from-percent "${from%%-*}" --from-color "${from#*-}") ;;
      esac
      "$RENDERER" "${args[@]}" --transition "$target" ;;
  esac
}

show() {
  if [[ "$1" == blocked ]]; then
    motion_show claude blocked render_mark "$CACHE_DIR"
  else
    motion_show claude "$1-$2" render_mark "$CACHE_DIR"
  fi
}

# Put the last known reading up before anything else can fail. Three cases, in
# the order they are decided:
#
#   the session it was measured in has since reset  ->  full, live colour
#   it is older than STALE_AFTER                    ->  the error mark: nothing got through
#   otherwise                                       ->  exactly what it said
#
# This runs on every tick, not only after a reload: an endpoint that goes away
# for an hour would otherwise leave a stale number sitting there in the live
# colour, looking exactly like a fresh one.
if [[ -r "$LAST_FILE" ]]; then
  read -r last_percent last_color last_seen last_reset < "$LAST_FILE"
  if [[ -n "$last_percent" && -n "$last_color" ]]; then
    if [[ -n "$last_reset" ]] && (( EPOCHSECONDS >= last_reset )); then
      last_percent=100
      last_color="$CLAUDE_COLOR"
    elif (( EPOCHSECONDS - ${last_seen:-0} > STALE_AFTER )); then
      motion_show claude error render_mark "$CACHE_DIR"
      last_percent=""
    fi
    [[ -n "$last_percent" ]] && show "$last_percent" "$last_color"
  fi
fi

# When this last ran at all, as opposed to when it last succeeded. The two answer
# different questions and only one of them was recorded: "the number is six
# minutes old" could mean the timer is dead or it could mean six polls in a row
# were refused, and there was no way to tell them apart.
mkdir -p "$CACHE_DIR"
print -r -- "$EPOCHSECONDS" > "$CACHE_DIR/.tick"

# Fill the card from whatever is on disk, before the poll and regardless of
# whether it succeeds. The rows used to be pushed only after a good reading, so a
# reload followed by a failing poll left the popup opening completely empty: the
# detail file was right there on disk and nothing had put it on screen. A stale
# row is honest here, because every row carries the window it belongs to and when
# that window resets.
"${0:A:h}/popup_rows.sh" "$DETAIL_FILE"

log_line() {
  mkdir -p "$CACHE_DIR"
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
  local lines=("${(@f)$(tail -n 200 "$LOG_FILE")}")
  print -rl -- "${lines[@]}" > "$LOG_FILE"
}

token_expiry() {
  /usr/bin/security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | /usr/bin/python3 -c '
import json, sys
try:
    print(int(json.load(sys.stdin)["claudeAiOauth"]["expiresAt"]) // 1000)
except Exception:
    print(0)
' 2>/dev/null
}

result=$(/usr/bin/python3 - "$DETAIL_FILE" "$LOG_FILE" <<'PY' 2>"$error_sink"
import datetime, json, os, pathlib, subprocess, sys, urllib.error, urllib.request

# Claude's own clay orange, which is the point: on a bar whose whole palette is
# neutral grey, the one hue on the right-hand side is what marks this as the
# Claude badge rather than one more grey glyph. Apple's system orange was tried
# and reads as a warning at any level, which is wrong for a full session.
CLAUDE = "0xffd97757"
# Nearly out. No amber tier in between: amber next to clay is two shades of the
# same warning, and the ray count already says how close the edge is, so the
# colour only has to change once and change unmistakably.
LOW    = "0xffff453a"


def fail(reason, code="HIDE"):
    """Give the shell the word to stand down, and write down why.

    The reason goes to poll.log every time: a badge that went red overnight with
    no trace of why was exactly the thing that could not be diagnosed.
    `CLAUDE_USAGE_DEBUG=1` also prints it.
    """
    if os.environ.get("CLAUDE_USAGE_DEBUG"):
        sys.stderr.write(f"claude_usage: {reason}\n")
    try:
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(sys.argv[2], "a", encoding="utf-8") as log:
            log.write(f"{stamp} {code} {reason}\n")
    except Exception:
        pass
    print(code)
    raise SystemExit(0)

try:
    raw = subprocess.run(
        ["/usr/bin/security", "find-generic-password",
         "-s", "Claude Code-credentials", "-w"],
        capture_output=True, text=True, timeout=10,
    )
    oauth = json.loads(raw.stdout)["claudeAiOauth"]
    token = oauth["accessToken"]
except Exception as error:
    fail(f"keychain: {error}")

# The access token lives about eight hours and this script only ever reads it:
# Claude Code refreshes it, and only while Claude Code is running. Overnight it
# simply runs out, so an expired token is its own answer rather than a 401.
import time
if int(oauth.get("expiresAt") or 0) // 1000 <= time.time():
    fail("token expired", code="EXPIRED")

try:
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={"Authorization": "Bearer " + token,
                 "anthropic-beta": "oauth-2025-04-20"},
    )
    with urllib.request.urlopen(req, timeout=8) as resp:
        usage = json.load(resp)
except urllib.error.HTTPError as error:
    # Rate limited. Worth telling apart from any other failure, because the one
    # thing that must not happen next is another request: the retry loop in
    # sketchybarrc reads this and stops rather than digging in deeper.
    code = {429: "RATELIMIT", 401: "EXPIRED"}.get(error.code, "HIDE")
    fail(f"endpoint: {error}", code=code)
except Exception as error:
    fail(f"endpoint: {error}")

def used_in(window):
    value = (usage.get(window) or {}).get("utilization")
    return float(value) if isinstance(value, (int, float)) else 0.0


session_used = used_in("five_hour")

# The session alone; the week is in the card.
spent = session_used
left = round(max(0.0, min(100.0, 100.0 - spent)))


def reset_epoch(window):
    try:
        return int(datetime.datetime.fromisoformat((usage.get(window) or {}).get("resets_at")).timestamp())
    except Exception:
        return 0


def when(value):
    """Reset time in local terms. The date is only worth the space it takes when
    it is not today, which for the five-hour window is almost never and for the
    weekly one is almost always."""
    if not value:
        return "unknown"
    try:
        moment = datetime.datetime.fromisoformat(value).astimezone()
    except ValueError:
        return "unknown"
    # Rounded to the nearest minute rather than truncated. The endpoint answers
    # with sub-second precision and the boundary sits on :59.7 as often as not,
    # so truncating showed 14:09 for a window that everything else calls 14:10.
    moment += datetime.timedelta(seconds=30)
    today = datetime.datetime.now().astimezone().date()
    return moment.strftime("%H:%M" if moment.date() == today else "%a %H:%M")


def row(item, name, window):
    """One popup row as item, icon, label, and a colour for the label.

    The split across the two slots is the hierarchy: the number is the answer
    and goes right, the window it belongs to and when it comes back are context
    and go left in grey. Both rows right-align, so the percentages line up under
    each other and can be compared without reading the words.

    The session, which the badge is drawn from, wears the badge's own orange,
    so the card says which of its two numbers the burst is.
    """
    block = usage.get(window) or {}
    value = block.get("utilization")
    used = round(float(value)) if isinstance(value, (int, float)) else 0
    context = f"{name}  \u00b7  resets {when(block.get('resets_at'))}"
    color = CLAUDE if window == "five_hour" else "0xfff5f5f7"
    # The popup says used, the badge says left. Both are the same number from
    # different ends, and a percentage on its own is ambiguous about which it
    # means, so the word travels with it.
    return f"{item}\t{context}\t{used}% used\t{color}"


detail = pathlib.Path(sys.argv[1])
detail.parent.mkdir(parents=True, exist_ok=True)
detail.write_text(
    row("claude.session", "Session", "five_hour") + "\n"
    + row("claude.week", "Week", "seven_day") + "\n",
    encoding="utf-8",
)

# The session's own reset time travels with the reading, so a later run can tell
# "this is old" from "this is void because the window has turned over".
#
# The one exception to "the badge is the session": a spent week. Then no session
# can be used at all, however full it looks, so the badge becomes the red cross
# and carries the week's reset instead, past which it comes back full.
if used_in("seven_day") >= 100:
    print("blocked", LOW, reset_epoch("seven_day"))
else:
    print(left, LOW if left <= 10 else CLAUDE, reset_epoch("five_hour"))
PY
)

# 2 rather than 1 for a rate limit, so the load-time retry loop can tell "try
# again shortly" from "stop asking".
[[ "$result" == "RATELIMIT" ]] && give_up 2

# An expired token is not ours to refresh: the credential belongs to Claude
# Code, and a refresh rotates the refresh token, so writing it back wrong would
# log you out. So Claude Code does it, the only way it will: by making a real
# request. `claude auth status` was tried first and never refreshes anything
# (the log showed the expiry unchanged every time, and the badge went red after
# eight idle hours). One word to Haiku in safe mode, so no CLAUDE.md, hooks,
# plugins or MCP servers load: about three seconds and the smallest request
# there is, at most once per REFRESH_EVERY, and only when the token has run out.
# Then one more try. Every attempt is logged with whether the token moved.
if [[ "$result" == "EXPIRED" && -z "${CLAUDE_USAGE_RETRIED:-}" ]]; then
  last_refresh=0
  [[ -r "$REFRESH_STAMP" ]] && last_refresh=$(<"$REFRESH_STAMP")
  claude_bin=""
  for candidate in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [[ -x "$candidate" ]] && claude_bin="$candidate" && break
  done
  if [[ -n "$claude_bin" ]] && (( EPOCHSECONDS - last_refresh >= REFRESH_EVERY )); then
    print -r -- "$EPOCHSECONDS" > "$REFRESH_STAMP"
    before=$(token_expiry)
    ( cd /tmp && "$claude_bin" -p --safe-mode --model haiku --no-session-persistence \
        "Reply with the single word ok." >/dev/null 2>&1 ) & refresher=$!
    # Bounded: a login prompt or a hang must not hold the bar's script.
    for (( waited = 0; waited < 60; waited++ )); do
      kill -0 "$refresher" 2>/dev/null || break
      sleep 1
    done
    kill "$refresher" 2>/dev/null
    after=$(token_expiry)
    if (( after > EPOCHSECONDS )); then
      log_line "REFRESHED token now valid until $(date -r "$after" '+%H:%M')"
      CLAUDE_USAGE_RETRIED=1 exec "$0"
    fi
    log_line "REFRESH-FAILED token still expired after a Claude Code request (expiry $before -> $after)"
  fi
fi

if [[ -z "$result" || "$result" == "HIDE" || "$result" == "EXPIRED" || ! -x "$RENDERER" ]]; then
  give_up
fi

read -r percent color reset <<< "$result"
show "$percent" "$color" || give_up
print -r -- "$percent $color $EPOCHSECONDS ${reset:-0}" > "$LAST_FILE"

# And again with the numbers this poll just wrote. The popup is laid out from its
# members, so filling it here rather than when the card opens is what stops it
# resizing on screen in front of you.
"${0:A:h}/popup_rows.sh" "$DETAIL_FILE"
