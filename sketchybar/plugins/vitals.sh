#!/bin/zsh

# The vitals badge: how hard the Mac is working, as a pixel ghost after
# NeoHtop's (assets/vitalsmark) whose colour is a heat score of the processor and
# memory together, and a card with the numbers and a way into Vitals.
#
# The numbers are read here, not from Vitals. Vitals (com.forestudio.Vitals)
# offers its readings only as Shortcuts actions, which need a shortcut built by
# hand and take about a second a call inside the app; the same CPU and memory
# figures are one system call away (assets/vitalsinfo). Vitals is where the card
# and a right-click take you for everything else: temperatures, GPU, disks.
#
# The colour is one heat score for the whole machine: the worse of the processor
# and the memory, so 5% CPU with memory full is red. CPU counts as it is; memory
# counts from RAM_HEAT_FROM up, because a Mac sits at 60-80% used doing nothing
# and a scale from zero would never leave orange (60% is cool, 80% yellow, 90%
# orange, 95% and over red).
#
# Live, but not jittery. CPU is a running average over the last couple of polls,
# the score goes on the heat scale in CPU_STEP steps, and it only takes a new step
# once it is CPU_DEADBAND past the one it is on. Memory pressure only warms the
# colour: elevated is at least orange, critical is red.
#
# It was five CPU bands with a five-point dead band and memory counted only at
# elevated pressure until 2026-10-06, which kept it so calm it hardly moved.

zmodload zsh/datetime
PLUGINS="${0:A:h}"
ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
RENDERER="$ASSETS/vitalsmark"
PROBE="$ASSETS/vitalsinfo"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/vitals"
DETAIL_FILE="$CACHE_DIR/detail"
SAMPLE_FILE="$CACHE_DIR/sample"
LAST_FILE="$CACHE_DIR/last"

CPU_STEP=5
CPU_DEADBAND=3
RAM_HEAT_FROM=60
# How much each new poll moves the CPU average.
SMOOTHING=0.6

# `vitals.sh open`: the card's way into Vitals. Opening it while it runs brings
# up its Overview window; opening it cold only starts it, menu bar side, so it is
# asked a second time once it is up.
if [[ "$1" == open ]]; then
  running=$(/usr/bin/pgrep -x Vitals)
  /usr/bin/open -b com.forestudio.Vitals || exit 0
  [[ -n "$running" ]] || { sleep 1.5; /usr/bin/open -b com.forestudio.Vitals; }
  exit 0
fi

source "$PLUGINS/motion.sh"

# The key is "<heat step>-<tone>".
render_mark() {
  local mode="$1" target="$3" from="$4"
  local -a key=("${(@s:-:)2}") old=("${(@s:-:)4}")
  (( ${#key} == 2 )) || return 1
  case "$mode" in
    still) "$RENDERER" --heat "$key[1]" --tone "$key[2]" --out "$target" ;;
    transition)
      (( ${#old} == 2 )) || return 1
      "$RENDERER" --heat "$key[1]" --tone "$key[2]" \
        --from-heat "$old[1]" --from-tone "$old[2]" --transition "$target" ;;
  esac
}

for tool in vitalsmark vitalsinfo; do
  if [[ ! -x "$ASSETS/$tool" || "$ASSETS/$tool.swift" -nt "$ASSETS/$tool" ]]; then
    /usr/bin/xcrun swiftc -O "$ASSETS/$tool.swift" -o "$ASSETS/$tool" 2>/dev/null || {
      echo "vitals.sh: cannot build $tool, leaving the badge as it is" >&2
      exit 0
    }
    [[ "$tool" == vitalsmark ]] && motion_purge "$CACHE_DIR"
  fi
done
mkdir -p "$CACHE_DIR"

# After a reload, the last state goes straight back up, before any reading.
if [[ -r "$LAST_FILE" ]]; then
  read -r last_key < "$LAST_FILE"
  [[ -n "$last_key" ]] && motion_show vitals "$last_key" render_mark "$CACHE_DIR"
fi

read -r busy total used memtotal <<< "$("$PROBE" 2>/dev/null)"
[[ -n "$total" ]] || exit 0
pressure=$(/usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
# Whether the Vitals app itself is running. Not, and the ghost is dead.
running=no
/usr/bin/pgrep -xq Vitals && running=yes
# The busiest process with its full path, so a helper can be named after the
# app it belongs to: "Microsoft Teams ModuleHost" lives inside Microsoft
# Teams.app, and the card says Microsoft Teams.
read -r top_cpu top_path <<< "$(/bin/ps -Aeo pcpu=,comm= -r 2>/dev/null | head -1)"

prev_busy="" prev_total="" average="" step=""
[[ -r "$SAMPLE_FILE" ]] && read -r prev_busy prev_total average step _ < "$SAMPLE_FILE"

result=$(/usr/bin/python3 - "$busy" "$total" "${prev_busy:-}" "${prev_total:-}" "${average:-}" "${step:-}" \
  "$used" "$memtotal" "${pressure:-1}" "${top_cpu:-0}" "${top_path:-}" \
  "$DETAIL_FILE" "$CPU_STEP" "$CPU_DEADBAND" "$SMOOTHING" "$running" "$RAM_HEAT_FROM" <<'PY'
import pathlib, sys
(busy, total, prev_busy, prev_total, average, step, used, memtotal, pressure,
 top_cpu, top_path, detail, cpu_step, cpu_deadband, smoothing, running, ram_heat_from) = sys.argv[1:]
busy, total, used, memtotal = int(busy), int(total), int(used), int(memtotal)
pressure = int(pressure or 1)
cpu_step, cpu_deadband, smoothing = float(cpu_step), float(cpu_deadband), float(smoothing)

# This poll's CPU, from the ticks since the last one. The first poll after a
# reload has nothing to difference against and starts the average from scratch.
if prev_total and int(total) > int(prev_total):
    now = 100.0 * (busy - int(prev_busy)) / (total - int(prev_total))
else:
    now = None
if now is None:
    avg = float(average) if average else 0.0
else:
    avg = now if not average else float(average) + smoothing * (now - float(average))

def settle(value, previous, deadband):
    """The nearest step, unless the one it is on is still within the dead band."""
    try:
        if abs(value - float(previous)) < deadband:
            return int(float(previous))
    except ValueError:
        pass
    return int(round(value))

# The worse of the two, on the heat scale in steps of CPU_STEP.
ram = 100.0 * used / memtotal
cool = float(ram_heat_from)
score = max(avg, max(0.0, (ram - cool) / (100 - cool) * 100))
heat = min(100, settle(score / cpu_step, float(step) / cpu_step if step else "", cpu_deadband / cpu_step) * int(cpu_step))

# The Vitals app not running is the ghost's death, whatever the readings: the
# badge stands for Vitals, and a live ghost would say it is there.
if running != "yes":
    tone = "dead"
elif pressure >= 4:
    tone = "critical"
# Memory pressure only ever warms the ghost; the processor's own heat is the
# level, with its dead band. A threshold of its own here flipped the colour every
# poll while the average sat on it.
elif pressure >= 2:
    tone = "busy"
else:
    tone = "calm"

gb = 1024 ** 3
words = {1: "Normal", 2: "Elevated", 4: "Critical"}
pressure_colour = {2: "0xffff9f0a", 4: "0xffff453a"}.get(pressure, "0xfff5f5f7")
# The outermost app bundle in the path names it; a bare process keeps its own
# name. Kept to what fits the card's value column.
parts = top_path.strip().split("/")
apps = [part[:-4] for part in parts if part.endswith(".app")]
name = apps[0] if apps else (parts[-1] if parts and parts[-1] else "nothing")
if len(name) > 16:
    name = name[:15].rstrip() + "\u2026"
rows = [
    ("vitals.cpu", "Processor", f"{round(now if now is not None else avg)}% busy", "0xfff5f5f7"),
    ("vitals.memory", "Memory", f"{used / gb:.1f} of {memtotal / gb:.0f} GB · {ram:.0f}%", "0xfff5f5f7"),
    ("vitals.pressure", "Memory pressure", words.get(pressure, "Normal"), pressure_colour),
    ("vitals.busiest", "Busiest", f"{name} · {float(top_cpu):.0f}%", "0xfff5f5f7"),
    ("vitals.open", "Temperatures, GPU, disks", "Open Vitals", "0xff64d2ff") if running == "yes"
    else ("vitals.open", "Vitals is not running", "Start", "0xff32d74b"),
]
pathlib.Path(detail).write_text("".join(f"{i}\t{a}\t{b}\t{c}\n" for i, a, b, c in rows), encoding="utf-8")
# A dead ghost is one key whatever the load, so the load moving while Vitals
# is down redraws nothing.
print(f"{avg:.2f} {heat} {tone}")
PY
)
[[ -n "$result" ]] || exit 0
read -r average step tone <<< "$result"
print -r -- "$busy $total $average $step" > "$SAMPLE_FILE"

key="$step-$tone"
[[ "$tone" == dead ]] && key="0-dead"
motion_show vitals "$key" render_mark "$CACHE_DIR" || exit 0
print -r -- "$key" > "$LAST_FILE"
"$PLUGINS/popup_rows.sh" "$DETAIL_FILE"
