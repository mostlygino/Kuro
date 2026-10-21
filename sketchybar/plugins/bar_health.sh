#!/bin/zsh

# A small health check every 20 seconds, for the two ways the bar has been seen
# to go wrong after the screens change, so that neither can stay wrong for long:
#
# - A pill's background window stacked over the badges it holds, which dims
#   them as if greyed out (assets/zorder). Healed with a reload, at most once
#   every two minutes, so a check that keeps failing cannot reload the bar in a
#   loop.
# - Workspace chips still pinned to a screen that is gone, or a screen with no
#   chips at all, which leaves its workspace pill missing. Healed by asking
#   aerospace_sync for an ordinary pass, which reassigns them.
#
# display_settle.sh does the same after a display change; this catches the
# cases that slip past it (seen 2026-10-03: badges dimmed and the workspace pill
# gone after a day of screens coming and going).

zmodload zsh/datetime
ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
STAMP="$HOME/.cache/sketchybar/health-reload"

if [[ -x "$ASSETS/zorder" ]] && ! "$ASSETS/zorder"; then
  last=0
  [[ -r "$STAMP" ]] && last=$(<"$STAMP")
  if (( EPOCHSECONDS - last >= 120 )); then
    print -r -- "$EPOCHSECONDS" > "$STAMP"
    echo "bar_health.sh: a pill was stacked over its items, reloading the bar" >&2
    exec sketchybar --reload
  fi
fi

# Which screens exist, and which screens the drawn workspace chips are on.
/usr/bin/python3 - <<'PY' && exit 0
import json, subprocess, sys
def query(what):
    out = subprocess.run(["sketchybar", "--query", what], capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else None
displays = {d["arrangement-id"] for d in (query("displays") or [])}
if not displays:
    sys.exit(0)
covered = set()
for sid in [str(n) for n in range(1, 11)] + ["S"]:
    item = query(f"workspace.{sid}")
    if not item or item["geometry"]["drawing"] != "on":
        continue
    mask = item["geometry"]["associated_display_mask"]
    on = {d for d in range(1, 17) if mask & (1 << d)}
    if on - displays:
        sys.exit(1)           # pinned to a screen that is gone
    covered |= on
sys.exit(0 if displays <= covered else 1)   # every screen has a chip
PY
echo "bar_health.sh: workspace chips out of step with the screens, asking for a sync" >&2
sketchybar --trigger aerospace_workspace_change
