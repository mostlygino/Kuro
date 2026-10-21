#!/bin/zsh

# The battery, drawn rather than written. No percentage on the bar: a level and a
# colour answer "do I need a cable" without asking anyone to read a number. The
# figures behind it live in the card that opens on hover, written here on every
# poll so the card opens finished rather than laying itself out after the fact.
#
# `pmset -g batt` rather than IOKit: it is the same source the system uses, it
# needs no entitlement, and it reports charge and charging state in one line.
#
# A failed read leaves the last mark up rather than hiding the badge, and that
# reading is kept in `last` so it survives a reload, which rebuilds every item
# with no image. The badge only disappears when the machine says it has no
# battery at all, which is the one case with nothing to draw. Hiding on any
# failure was the first shape of this and it is the wrong one: a badge that
# vanishes reads as a bug, which the Claude badge had already taught.
#
# Colors are literal hex rather than the colors.sh exports, for the reason
# spelled out in tailscale.sh: a periodic plugin is spawned by the daemon and
# does not inherit the rc's shell environment. The green is the same one the
# Tailscale shield wears when the VPN is up, so the two badges agree on what
# "fine" looks like.
GOOD_COLOR=0xff32d74b
WARN_COLOR=0xffff9f0a
LOW_COLOR=0xffff453a

# Apple turns its own battery yellow at 20%. This goes amber a little earlier and
# keeps red for the part where the machine is genuinely about to stop.
WARN_BELOW=35
LOW_BELOW=12

ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
RENDERER="$ASSETS/batterymark"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/battery"
DETAIL_FILE="$CACHE_DIR/detail"
LAST_FILE="$CACHE_DIR/last"

# Leave whatever is on the bar alone. Every failure but "no battery in this
# machine" ends here, that one being the only one where hiding is honest.
keep_last() {
  exit 0
}

# Draw a reading. The colour rules live here so the restore path and the poll
# cannot disagree about them. plugins/motion.sh caches the still and the move
# from the last reading under the key "<percent>-<colour>-<charging>",
# and only calls back into render_mark for what is missing.
render_mark() {
  local mode="$1" target="$3" from="$4" args
  local -a key=("${(@s:-:)2}") old=("${(@s:-:)4}")
  args=(--percent "$key[1]" --color "$key[2]")
  [[ "$key[3]" == yes ]] && args+=(--charging)
  case "$mode" in
    still) args+=(--out "$target") ;;
    transition)
      args+=(--from-percent "$old[1]" --from-color "$old[2]" --transition "$target")
      [[ "$old[3]" == yes ]] && args+=(--from-charging) ;;
  esac
  "$RENDERER" "${args[@]}"
}

show() {
  local percent="$1" charging="$2" color
  if (( percent < LOW_BELOW )); then
    color="$LOW_COLOR"
  elif (( percent < WARN_BELOW )); then
    color="$WARN_COLOR"
  else
    color="$GOOD_COLOR"
  fi
  motion_show battery "$percent-$color-$charging" render_mark "$CACHE_DIR"
}

source "${0:A:h}/motion.sh"

# Self-building, the pattern every renderer here follows: the binary is not in the repo, and editing the
# geometry in batterymark.swift should take effect on the next tick without
# anyone remembering a compile step. Cached renders are stale the moment the
# source changes, so they go with it.
if [[ ! -x "$RENDERER" || "$ASSETS/batterymark.swift" -nt "$RENDERER" ]]; then
  if /usr/bin/xcrun swiftc -O "$ASSETS/batterymark.swift" -o "$RENDERER" 2>/dev/null; then
    rm -f "$CACHE_DIR"/bat-*.png
    motion_purge "$CACHE_DIR"
  else
    echo "battery.sh: cannot build batterymark, leaving the mark as it is" >&2
    keep_last
  fi
fi

mkdir -p "$CACHE_DIR"

# Put the last reading back before anything can fail. A reload rebuilds the item
# with no image, so without this a reload plus one bad read leaves a hole.
if [[ -r "$LAST_FILE" ]]; then
  read -r last_percent last_charging < "$LAST_FILE"
  [[ -n "$last_percent" ]] && show "$last_percent" "${last_charging:-no}"
fi

# `pmset` for the level, the source and the human-readable estimate, which it
# already formats better than anything reconstructed from ioreg would.
# `system_profiler` for cycles and condition: it takes about a third of a second,
# which is nothing on a 60s poll and buys the two numbers that say whether the
# battery itself is still healthy rather than merely full.
# Python runs pmset itself rather than being handed its output on a pipe. With
# `python3 -` the program is already arriving on stdin, so piping the report in
# as well feeds it to the parser as source and it dies on the first word.
state=$(PYTHONPATH="${0:A:h}" /usr/bin/python3 - "$DETAIL_FILE" <<'INNER' 2>/dev/null
import pathlib, plistlib, re, subprocess, sys
import since

try:
    text = subprocess.run(
        ["/usr/bin/pmset", "-g", "batt"],
        capture_output=True, text=True, timeout=5,
    ).stdout
except Exception:
    text = ""

# A machine with no battery says so in as many words, and there is nothing
# honest to draw for it.
match = re.search(r"(\d+)%; *([^;]+);", text)
if not match:
    print("NONE")
    raise SystemExit(0)

percent = int(match.group(1))
status = match.group(2).strip()

# The bolt means "on power", not "electrons currently moving". A laptop that has
# been plugged in all morning reports "charged" and takes no current, and hiding
# the bolt for that case answers the wrong question: what anyone wants from a
# glance is whether the cable is in.
charging = "AC Power" in text or status in ("charging", "finishing charge")
on_power = "AC Power" in text


def estimate():
    """What pmset says is left, in its own words where it has any.

    The clock reads 0:00 both while the estimate is still being worked out and
    when the machine is sitting full on the mains, so the status is what tells
    those two apart rather than the number.
    """
    if status == "charged" or (on_power and percent >= 100):
        return "Fully charged"
    match = re.search(r"(\d+:\d{2}) remaining", text)
    if not match:
        return "Calculating"
    clock = match.group(1)
    if clock == "0:00":
        return "Calculating"
    return f"{clock} to full" if charging else f"{clock} remaining"


def draw():
    """What the machine is pulling right now, in watts.

    `SystemPowerIn` is the system's own load and it is reported on mains and on
    battery alike, which is why it is preferred over the battery's discharge
    figure: the answer to "what is this costing me" should not change its
    meaning when the cable comes out. `BatteryPower` is the fallback for the
    moments telemetry reports nothing, and it is negative while discharging.

    Milliwatts in, so a tenth of a watt is the finest this can honestly claim.
    """
    try:
        report = subprocess.run(
            ["/usr/sbin/ioreg", "-rn", "AppleSmartBattery", "-a"],
            capture_output=True, timeout=5,
        ).stdout
        entry = plistlib.loads(report)[0]
    except Exception:
        return None

    telemetry = entry.get("PowerTelemetryData") or {}
    milliwatts = telemetry.get("SystemPowerIn") or 0
    if not milliwatts:
        milliwatts = abs((entry.get("BatteryData") or {}).get("BatteryPower") or 0)
    if not milliwatts:
        return None

    watts = milliwatts / 1000
    return f"{watts:.1f} W" if watts < 10 else f"{watts:.0f} W"


def health():
    """Cycles and condition, or nothing at all.

    system_profiler is the only source for these two that does not need root.
    If it is slow or absent the row is dropped rather than filled with a guess:
    a battery card is read to decide whether to trust the battery.
    """
    try:
        report = subprocess.run(
            ["/usr/sbin/system_profiler", "SPPowerDataType"],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return None
    cycles = re.search(r"Cycle Count: (\d+)", report)
    condition = re.search(r"Condition: (.+)", report)
    capacity = re.search(r"Maximum Capacity: (\d+%)", report)
    if not (cycles and condition):
        return None
    left = f"Condition  \u00b7  {cycles.group(1)} cycles"
    right = condition.group(1).strip()
    if capacity:
        right = f"{right}  \u00b7  {capacity.group(1)}"
    return left, right


rows = [
    ("battery.charge", "Charge", f"{percent}%"),
    # Where the power comes from, and since when: "On battery since 09:40 · 25
    # min" answers the question the old "Power: Battery" row only half did.
    ("battery.power",) + since.row("battery", "power" if on_power else "battery",
                                   "On power since" if on_power else "On battery since"),
]

# Dropped rather than zeroed when telemetry says nothing, the same rule the
# condition row follows: a card read to decide whether to unplug should not
# carry a number nobody stands behind.
watts = draw()
if watts:
    rows.append(("battery.draw", "Drawing", watts))

rows.append(("battery.remaining", "Remaining", estimate()))

condition_row = health()
if condition_row:
    rows.append(("battery.health",) + condition_row)

detail = pathlib.Path(sys.argv[1])
detail.write_text(
    "".join(f"{item}\t{left}\t{right}\n" for item, left, right in rows),
    encoding="utf-8",
)

print(percent, "yes" if charging else "no")
INNER
)

# The one case worth hiding for: no battery in this machine, so there is nothing
# to draw and never will be.
if [[ "$state" == "NONE" ]]; then
  sketchybar --set battery drawing=off
  exit 0
fi

[[ -z "$state" || ! -x "$RENDERER" ]] && keep_last

read -r percent charging <<< "$state"
show "$percent" "$charging" || keep_last
print -r -- "$percent $charging" > "$LAST_FILE"

# Push the card's rows on every poll rather than when it opens. A popup is laid
# out from its members, so filling it at open time makes it resize on screen.
"${0:A:h}/popup_rows.sh" "$DETAIL_FILE"
