#!/bin/zsh

# OrbStack, as a badge that exists only while OrbStack is running.
#
#   orbstack.sh              poll: show or hide the badge, refresh the card
#   orbstack.sh click <n>    card row n clicked: the name opens its site, the
#                            state starts or stops it
#   orbstack.sh toggle <n>   start or stop what card row n stands for
#   orbstack.sh open         bring the OrbStack window up
#   orbstack.sh quit         stop OrbStack and quit the app
#
# The badge is an orb drawn by assets/orbmark, purple, and only there while a
# container or machine is running: with nothing running, or with the app gone,
# the badge is hidden and the pill closes up around the others.
#
# The card is what is running and a way to stop all of it: each running Linux
# machine and Compose project, and Quit all. Stopped ones are left off; until
# 2026-10-21 the card listed every machine and project OrbStack knew, seventeen
# rows of mostly "Stopped" to find the one that was up. Every row is a button:
# the state stops it (a machine through `orb`, a project through
# `docker compose -p <project>`, which finds its containers by label and needs
# no compose file), and the name opens its site when it has one. A row being
# stopped stays, saying Killing, until it has. Nothing running is one quiet row.
#
# Docker is only asked while `orb status` says the engine is running. Asking a
# stopped OrbStack for its containers starts it, which a poll must never do.

ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
RENDERER="$ASSETS/orbmark"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/orbstack"
DETAIL_FILE="$CACHE_DIR/detail"
ACTIONS_FILE="$CACHE_DIR/actions"
# Written by `quit`. While it is fresh the poll leaves `orb` and `docker` alone:
# OrbStack takes a moment to go, a poll landing in that moment still saw the app
# and asked `orb status`, and the CLI answered by launching OrbStack again.
QUITTING_FILE="$CACHE_DIR/.quitting"
QUIT_GRACE=15
ORB=/usr/local/bin/orb
DOCKER=/usr/local/bin/docker

# Literal hex, for the reason spelled out in tailscale.sh.
# systemPurple as macOS draws it in dark mode, for the orb and for the rows
# that are running, so the card and the badge agree.
BUSY_COLOR=0xffbf5af2
IDLE_COLOR=0xff8e8e93
# Booting and Killing, the two states in between, in the system amber.
MOVING_COLOR=0xffff9f0a
# A row mid-start or mid-stop, one file per machine or project, so the poll
# that lands while Docker is still working shows "Booting" rather than the
# "Stopped" Docker still reports. Anything older than this is a leftover from
# an action that died, and is ignored.
PENDING_DIR="$CACHE_DIR/pending"
PENDING_MAX_AGE=180
# Rows the rc creates for machines and projects. Anything beyond is left off
# the card rather than overflowing it.
MAX_ROWS=20

zmodload zsh/datetime
source "${0:A:h}/motion.sh"

render_mark() {
  local mode="$1" target="$3" color from_color
  color=$([[ "$2" == busy ]] && print -r -- "$BUSY_COLOR" || print -r -- "$IDLE_COLOR")
  case "$mode" in
    still) "$RENDERER" --color "$color" --out "$target" ;;
    transition)
      from_color=$([[ "$4" == busy ]] && print -r -- "$BUSY_COLOR" || print -r -- "$IDLE_COLOR")
      "$RENDERER" --color "$color" --from-color "$from_color" --transition "$target" ;;
  esac
}

hide_badge() {
  sketchybar --set orbstack drawing=off popup.drawing=off
}

# Immediate feedback on the row that was clicked, because a Compose stop can
# take several seconds and a card that does nothing for that long reads as a
# click that missed.
mark_row() {
  sketchybar --set "$1" label="$2" label.color="$MOVING_COLOR"
}

# Starts or stops one machine or project, with the row saying Booting or
# Killing for as long as that takes, and the card refreshed once it is done.
act() {
  local kind="$1" name="$2" verb="$3" row="$4" word pending
  word=$([[ "$verb" == start ]] && print Booting || print Killing)
  pending="$PENDING_DIR/$kind-$name"
  mkdir -p "$PENDING_DIR"
  print -r -- "$word" > "$pending"
  mark_row "$row" "$word"
  case "$kind" in
    machine) "$ORB" "$verb" "$name" >/dev/null 2>&1 ;;
    project) "$DOCKER" compose -p "$name" "$verb" >/dev/null 2>&1 ;;
  esac
  rm -f "$pending"
}

# The site behind a row, from the actions file. Empty when it has none, like a
# project that is only a database.
row_url() {
  local line=$(sed -n "$(( $1 + 1 ))p" "$ACTIONS_FILE" 2>/dev/null)
  local fields=("${(@ps:\t:)line}")
  print -r -- "${fields[4]}"
}

case "$1" in
  click)
    [[ "$2" == <-> ]] || exit 0
    # Which half of the row the pointer was on. hoverwatch writes the pointer
    # while a card is open; the name column ends CARD_CONTEXT_WIDTH plus its
    # padding in from the row's left edge. Anything uncertain toggles, which is
    # what the whole row did before it had two halves.
    source "${CONFIG_DIR:-$HOME/.config/sketchybar}/colors.sh"
    pointer_file="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/hover/pointer"
    read -r px py < "$pointer_file" 2>/dev/null
    row_x=$(sketchybar --query "orbstack.row.$2" 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    rects = json.load(sys.stdin)["bounding_rects"].values()
    print(min(r["origin"][0] for r in rects))
except Exception:
    pass
' 2>/dev/null)
    url=$(row_url "$2")
    if [[ -n "$px" && -n "$row_x" && -n "$url" ]] \
        && (( px < row_x + CARD_TEXT_PAD + CARD_CONTEXT_WIDTH )); then
      exec "$0" open-site "$2"
    fi
    exec "$0" toggle "$2"
    ;;
  open-site)
    [[ "$2" == <-> ]] || exit 0
    url=$(row_url "$2")
    [[ -n "$url" ]] || exit 0
    line=$(sed -n "$(( $2 + 1 ))p" "$ACTIONS_FILE" 2>/dev/null)
    fields=("${(@ps:\t:)line}")
    # A stopped site cannot load, so it is started first. `start` returns once
    # the containers are up, which is as close to "serving" as Docker can say.
    if [[ "${fields[3]}" != 1 ]]; then
      act "${fields[1]}" "${fields[2]}" start "orbstack.row.$2"
    fi
    /usr/bin/open "$url"
    exec "$0"
    ;;
  toggle)
    [[ "$2" == <-> ]] || exit 0
    line=$(sed -n "$(( $2 + 1 ))p" "$ACTIONS_FILE" 2>/dev/null)
    [[ -n "$line" ]] || exit 0
    fields=("${(@ps:\t:)line}")
    kind="${fields[1]}" name="${fields[2]}" running="${fields[3]}"
    row="orbstack.row.$2"
    act "$kind" "$name" $([[ "$running" == 1 ]] && print stop || print start) "$row"
    exec "$0"
    ;;
  open)
    /usr/bin/open -a OrbStack
    exit 0
    ;;
  quit)
    mark_row orbstack.quit "Killing"
    mkdir -p "$CACHE_DIR"
    print -r -- "$EPOCHSECONDS" > "$QUITTING_FILE"
    # Quitting the app is enough: it takes the engine, the machines and every
    # container down with it, measured with no OrbStack process left behind.
    # `orb stop` first was worse than redundant. The app went down with the
    # engine, and the `tell` that followed launched it straight back up, since
    # telling an app that is not running starts it. Hence the running check.
    /usr/bin/osascript \
      -e 'if application "OrbStack" is running then' \
      -e 'tell application "OrbStack" to quit' \
      -e 'end if' >/dev/null 2>&1
    hide_badge
    exit 0
    ;;
esac

# The app itself, not the engine: with the app gone there is nothing to manage
# and nothing to show. Nor while it is on its way out.
quitting_since=0
[[ -r "$QUITTING_FILE" ]] && quitting_since=$(<"$QUITTING_FILE")
if (( EPOCHSECONDS - quitting_since < QUIT_GRACE )) || ! /usr/bin/pgrep -qx OrbStack; then
  hide_badge
  exit 0
fi

if [[ ! -x "$RENDERER" || "$ASSETS/orbmark.swift" -nt "$RENDERER" ]]; then
  /usr/bin/xcrun swiftc -O "$ASSETS/orbmark.swift" -o "$RENDERER" 2>/dev/null \
    || { echo "orbstack.sh: cannot build orbmark" >&2; exit 0; }
  motion_purge "$CACHE_DIR"
fi
mkdir -p "$CACHE_DIR"

# One pass for the badge's state, the card's rows and the action behind each.
# Python runs the CLIs itself; see tailscale.sh for why nothing is piped in.
state=$(/usr/bin/python3 - "$DETAIL_FILE" "$ACTIONS_FILE" "$ORB" "$DOCKER" "$MAX_ROWS" \
    "$BUSY_COLOR" "$IDLE_COLOR" "$MOVING_COLOR" "$PENDING_DIR" "$PENDING_MAX_AGE" <<'PY' 2>/dev/null
import json, pathlib, subprocess, sys, time

detail, actions, orb, docker, max_rows, busy, idle, moving, pending_dir, max_age = sys.argv[1:11]
max_rows, max_age = int(max_rows), int(max_age)

# Four words for a row, and nothing else: no counts, no fractions. Docker and
# OrbStack's own in-between states map onto the two middle ones; an action this
# card started overrides whatever they say until it has finished.
WORDS = {"running": "Running", "restarting": "Booting", "starting": "Booting",
         "removing": "Killing", "stopping": "Killing"}

def word(kind, name, native):
    marker = pathlib.Path(pending_dir) / f"{kind}-{name}"
    try:
        if time.time() - marker.stat().st_mtime < max_age:
            return marker.read_text(encoding="utf-8").strip()
    except OSError:
        pass
    return WORDS.get(native, "Stopped")

COLOURS = {"Running": busy, "Stopped": idle, "Booting": moving, "Killing": moving}

def run(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=8).stdout
    except Exception:
        return ""

engine = run(orb, "status").strip() or "Unknown"
entries = []  # (kind, name, running, url, context, value)

if engine == "Running":
    try:
        machines = json.loads(run(orb, "list", "--format", "json") or "[]")
    except ValueError:
        machines = []
    for m in machines:
        name = m.get("name", "?")
        on = m.get("state") == "running"
        entries.append(("machine", name, on, f"http://{name}.orb.local",
                        f"{name}  ·  VM", word("machine", name, m.get("state", ""))))

    # Every container Docker knows, on every poll, so a project created or
    # pulled since the last one simply appears. A project's native state is the
    # most alive of its containers: any running means Running, any in between
    # means that, otherwise Stopped.
    projects = {}
    rank = {"running": 3, "restarting": 2, "removing": 2}
    fmt = '{{.Label "com.docker.compose.project"}}\t{{.Names}}\t{{.State}}'
    for line in run(docker, "ps", "-a", "--format", fmt).splitlines():
        parts = line.split("\t")
        if len(parts) != 3 or not parts[0]:
            continue
        best = projects.get(parts[0], "exited")
        if rank.get(parts[2], 0) > rank.get(best, 0):
            best = parts[2]
        projects[parts[0]] = best

    # One site per project. The container named after the project wins, then a
    # service that sounds like a front end, then anything with a port. Its
    # published host port if it has one, else, on the host network, the port
    # it exposes. Databases and media ports are not sites.
    not_sites = {5432, 3306, 6379, 27017, 554, 8554, 8322, 9997, 1935}
    front = ("web", "app", "server", "dashboard", "frontend", "ui")
    urls = {}
    ids = run(docker, "ps", "-aq").split()
    try:
        inspected = json.loads(run(docker, "inspect", *ids) or "[]") if ids else []
    except ValueError:
        inspected = []
    for c in inspected:
        labels = (c.get("Config") or {}).get("Labels") or {}
        project = labels.get("com.docker.compose.project")
        if not project:
            continue
        name = (c.get("Name") or "").lstrip("/")
        service = labels.get("com.docker.compose.service", "")
        host = (c.get("HostConfig") or {})
        port = None
        for bindings in (host.get("PortBindings") or {}).values():
            for b in bindings or []:
                if (b.get("HostPort") or "").isdigit() and int(b["HostPort"]) not in not_sites:
                    port = port or int(b["HostPort"])
        if port is None and host.get("NetworkMode") == "host":
            for exposed in ((c.get("Config") or {}).get("ExposedPorts") or {}):
                number = int(exposed.split("/")[0])
                if number not in not_sites:
                    port = port or number
        if port is None:
            continue
        rank = 0 if name == project else (1 if service in front else 2)
        if project not in urls or rank < urls[project][0]:
            urls[project] = (rank, f"http://localhost:{port}" if port != 80 else "http://localhost")
    for name in sorted(projects, key=str.lower):
        native = projects[name]
        # Bare names: the longest project here is 26 characters, which only
        # fits the card's context column without a suffix.
        entries.append(("project", name, native == "running", urls.get(name, (0, ""))[1],
                        name, word("project", name, native)))

active = sum(1 for e in entries if e[2])
# Only what is running, or on its way up or down because this card said so.
entries = [e for e in entries if e[2] or e[5] in ("Booting", "Killing")][:max_rows]

rows = []
for i, (kind, name, on, url, context, value) in enumerate(entries):
    rows.append((f"orbstack.row.{i}", context, value, COLOURS.get(value, idle)))
if not entries:
    rows.append(("orbstack.empty", "Nothing running", "", idle))
rows.append(("orbstack.quit", "Every machine and container", "Quit all", "0xffff453a"))

pathlib.Path(detail).write_text(
    "".join("\t".join(r) + "\n" for r in rows), encoding="utf-8")
pathlib.Path(actions).write_text(
    "".join(f"{k}\t{n}\t{int(on)}\t{u}\n" for k, n, on, u, _, _ in entries), encoding="utf-8")

print("busy" if active else "idle", len(entries))
PY
)

[[ -n "$state" ]] || exit 0
read -r mood count <<< "$state"

# Only while something runs. OrbStack up with every machine and container
# stopped drew a grey orb until 2026-10-25, a badge for nothing.
if [[ "$mood" != busy ]]; then
  hide_badge
  exit 0
fi

motion_show orbstack "$mood" render_mark "$CACHE_DIR"

# Rows in use are filled from the detail file; the rest are taken off the card.
"${0:A:h}/popup_rows.sh" "$DETAIL_FILE"
args=(--set orbstack.empty drawing=$( (( count == 0 )) && print on || print off))
for (( i = 0; i < MAX_ROWS; i++ )); do
  args+=(--set "orbstack.row.$i" drawing=$( (( i < count )) && print on || print off))
done
sketchybar "${args[@]}"
