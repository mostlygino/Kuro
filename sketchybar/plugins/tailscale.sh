#!/bin/zsh

# Polls `tailscale status --json` instead of `ifconfig utun*` because the utun
# index is not stable across reconnects and does not distinguish Tailscale
# from other VPN tunnels sharing the same interface family.
#
# BackendState is the field that matters: "Running" is connected, anything
# else (Stopped, NeedsLogin, NoState) is not, and a missing binary/daemon
# means offline too, not an error to surface.
#
# The shield's colours live in assets/vpnmark.swift with its shapes: green up,
# grey down, amber in between, the same values as colors.sh.

# The shield is drawn by assets/vpnmark, in four states: up (a green shield,
# the check drawing itself in), down (a grey outline, struck through), pending
# (amber with three dots, while `tailscale up` or `down` runs) and attention
# (amber with an exclamation mark, when the tailnet wants a login or an
# approval that only the app can give). See that file for the motion.
ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
RENDERER="$ASSETS/vpnmark"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/tailscale"

source "${0:A:h}/motion.sh"

# Self-building, like the other drawn badges. A shield that cannot be drawn
# leaves whatever is on the bar, and the card still updates below.
if [[ ! -x "$RENDERER" || "$ASSETS/vpnmark.swift" -nt "$RENDERER" ]]; then
  if /usr/bin/xcrun swiftc -O "$ASSETS/vpnmark.swift" -o "$RENDERER" 2>/dev/null; then
    motion_purge "$CACHE_DIR"
  else
    echo "tailscale.sh: cannot build vpnmark, leaving the shield as it is" >&2
  fi
fi

# The key is the state itself.
render_mark() {
  case "$1" in
    still) "$RENDERER" --state "$2" --out "$3" ;;
    transition) "$RENDERER" --state "$2" --from-state "$4" --transition "$3" ;;
  esac
}

# The four lines behind the shield, written by every poll and read by every
# hover. `tailscale status --json` is a local call and would be quick enough to
# run on entry, but the popup is laid out from its members, so filling it from
# the last poll is the difference between a card that opens finished and one
# that opens and then resizes.
DETAIL_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/tailscale/detail"
# The exit node the card's exit row would turn on, written by every poll: the
# one used last if it is still on offer, else Tailscale's own suggestion, else
# the first one online. "<address> <name>", or empty when there is none.
EXIT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/tailscale/exit"


# The CLI lives inside the app bundle on this Mac (App Store / standalone
# Tailscale.app); there is no /opt/homebrew/bin/tailscale. Keep the brew path
# as a fallback in case the CLI-only formula is installed later.
for bin in /Applications/Tailscale.app/Contents/MacOS/Tailscale /opt/homebrew/bin/tailscale; do
  [[ -x "$bin" ]] && TS_BIN="$bin" && break
done

# No Tailscale on this machine, no shield: a permanently grey badge for a VPN
# that is not installed is noise, not status.
if [[ -z "${TS_BIN:-}" ]]; then
  sketchybar --set tailscale drawing=off
  exit 0
fi

# `tailscale.sh toggle`, the card's bottom row: connect when the tunnel is down,
# disconnect when it is up, then poll straight away so the shield turns over
# and the card says what happened. `up` with no flags keeps the preferences the
# app already has. A tailnet that needs a login cannot be joined from here, so
# that case opens the app, which is where the login happens.
if [[ "$1" == toggle ]]; then
  backend=$("$TS_BIN" status --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("BackendState", ""))
except Exception:
    print("")
' 2>/dev/null)
  case "$backend" in
    Running)
      sketchybar --set tailscale.toggle label="Disconnecting…" label.color=0xffff9f0a
      motion_show tailscale pending render_mark "$CACHE_DIR"
      "$TS_BIN" down >/dev/null 2>&1 ;;
    NeedsLogin|NeedsMachineAuth)
      /usr/bin/open -a Tailscale ;;
    *)
      sketchybar --set tailscale.toggle label="Connecting…" label.color=0xffff9f0a
      motion_show tailscale pending render_mark "$CACHE_DIR"
      "$TS_BIN" up >/dev/null 2>&1 || /usr/bin/open -a Tailscale ;;
  esac
  exec "$0"
fi

# `tailscale.sh exit`, the card's exit node row: route through the exit node, or
# stop. Turning one on with the tunnel down connects it too, since an exit node
# on a stopped tunnel routes nothing. `set` only touches the one preference.
if [[ "$1" == exit ]]; then
  read -r active < <("$TS_BIN" status --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
    on = any(p.get("ExitNode") for p in (s.get("Peer") or {}).values())
    print(s.get("BackendState", ""), "on" if on else "off")
except Exception:
    print("", "off")
' 2>/dev/null)
  read -r backend exit_state <<< "$active"
  sketchybar --set tailscale.exit label="Switching…" label.color=0xffff9f0a
  if [[ "$exit_state" == on ]]; then
    "$TS_BIN" set --exit-node= >/dev/null 2>&1
  else
    read -r address name < "$EXIT_FILE" 2>/dev/null
    if [[ -z "$address" ]]; then
      /usr/bin/open -a Tailscale
    else
      "$TS_BIN" set --exit-node="$address" >/dev/null 2>&1 \
        && [[ "$backend" != Running ]] && "$TS_BIN" up >/dev/null 2>&1
    fi
  fi
  exec "$0"
fi

# An optional SSH tunnel row, for a LaunchAgent that holds a port forward open
# (set TUNNEL_AGENT, TUNNEL_NAME and TUNNEL_PORT in local.sh). The agent can be
# manual (no RunAtLoad, no KeepAlive) or always-on; the row works for both. On
# is enable + bootstrap + kickstart, since a manual agent only loads on
# bootstrap and only runs on kickstart. Off goes through launchd rather than a
# kill, because a KeepAlive agent would respawn a killed ssh, and `disable`
# keeps it from coming back at the next login. State is read from the port:
# ssh only binds the forward once it has logged in, so a listener means the
# tunnel is really up, and a running job without one is still connecting.
[[ -r "${CONFIG_DIR:-$HOME/.config/sketchybar}/local.sh" ]] \
  && source "${CONFIG_DIR:-$HOME/.config/sketchybar}/local.sh"
TUNNEL_JOB="gui/$(id -u)/${TUNNEL_AGENT:-}"

tunnel_state() {
  if /usr/sbin/lsof -nP -iTCP:"$TUNNEL_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then print -r -- up
  elif /bin/launchctl print "$TUNNEL_JOB" 2>/dev/null | grep -q 'state = running'; then print -r -- pending
  else print -r -- off; fi
}

if [[ "$1" == tunnel && -n "${TUNNEL_AGENT:-}" ]]; then
  if [[ "$(tunnel_state)" == off ]]; then
    sketchybar --set tailscale.tunnel label="Connecting…" label.color=0xffff9f0a
    /bin/launchctl enable "$TUNNEL_JOB"
    /bin/launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$TUNNEL_AGENT.plist" 2>/dev/null
    /bin/launchctl kickstart "$TUNNEL_JOB" 2>/dev/null
    # Give ssh a moment to log in and bind, so the row says Connected, not Connecting.
    for _ in {1..10}; do [[ "$(tunnel_state)" == up ]] && break; sleep 0.5; done
  else
    sketchybar --set tailscale.tunnel label="Disconnecting…" label.color=0xffff9f0a
    /bin/launchctl disable "$TUNNEL_JOB"
    /bin/launchctl bootout "$TUNNEL_JOB" 2>/dev/null
  fi
  exec "$0"
fi

# One pass over the JSON for both jobs: the shield's state and the popup's four
# rows. Parsing it twice, once here and once on hover, would let the badge and
# the card disagree about the same tailnet.
#
# Python runs the CLI itself rather than being handed its output on a pipe. With
# `python3 -` the program is already coming in on stdin, so piping the JSON in as
# well feeds it to the parser as source and it dies on the first `true`.
state=$(PYTHONPATH="${0:A:h}" /usr/bin/python3 - "$DETAIL_FILE" "${TS_BIN:-/usr/bin/false}" "$EXIT_FILE" <<'PY' 2>/dev/null
import json, pathlib, subprocess, sys
import since

try:
    result = subprocess.run(
        [sys.argv[2], "status", "--json"],
        capture_output=True, text=True, timeout=10,
    )
    status = json.loads(result.stdout)
except Exception:
    status = {}

backend = status.get("BackendState") or "NoState"

# The words people actually use for these, not the wire values. "NoState" in
# particular means the daemon has not answered, which reads as offline and not
# as a state worth naming on a bar.
STATES = {
    "Running": "Connected",
    "Stopped": "Stopped",
    "NeedsLogin": "Needs login",
    "NeedsMachineAuth": "Needs approval",
}

self_node = status.get("Self") or {}
peers = (status.get("Peer") or {}).values()

tailnet = (status.get("CurrentTailnet") or {}).get("Name") or "unknown"

# The v4 address is the one worth showing. Every node has both, and the v6 is
# three times as wide for the same information.
address = next(
    (ip for ip in (self_node.get("TailscaleIPs") or []) if ":" not in ip),
    "none",
)

# The peer carrying the ExitNode flag is the one being routed through, and its
# hostname is the useful answer. ExitNodeStatus is the fallback for the case
# where traffic is being routed but the peer list does not say through what,
# which is worth distinguishing from not using one at all.
peers = list(peers)
exit_node = next((p.get("HostName") for p in peers if p.get("ExitNode")), None)
if not exit_node and status.get("ExitNodeStatus"):
    exit_node = "in use"

# What the exit row would turn on: the last one used while it is still on offer,
# then Tailscale's suggestion, then the first offered node that is online.
def v4(peer):
    return next((ip for ip in (peer.get("TailscaleIPs") or []) if ":" not in ip), "")

offered = [p for p in peers if p.get("ExitNodeOption") and p.get("Online") and v4(p)]
exit_path = pathlib.Path(sys.argv[3])
try:
    last = exit_path.read_text().split()[1]
except Exception:
    last = ""
if exit_node and exit_node != "in use":
    last = exit_node
pick = next((p for p in offered if p.get("HostName") == last), None)
if pick is None and len(offered) > 1:
    try:
        said = subprocess.run([sys.argv[2], "exit-node", "suggest"],
                              capture_output=True, text=True, timeout=5).stdout
        pick = next((p for p in offered if (p.get("DNSName") or "\0") in said), None)
    except Exception:
        pass
pick = pick or (offered[0] if offered else None)
exit_path.parent.mkdir(parents=True, exist_ok=True)
exit_path.write_text(f"{v4(pick)} {pick.get('HostName')}\n" if pick else "\n", encoding="utf-8")

rows = [
    ("tailscale.state", f"Tailnet  ·  {tailnet}", STATES.get(backend, "Offline")),
    ("tailscale.address", "This device", address),
    # Its own action row: the node in the context, what a click does as the value.
    ("tailscale.exit", f"Exit node  ·  {exit_node}", "Turn off", "0xffff453a") if exit_node
    else ("tailscale.exit", f"Exit node  ·  {pick.get('HostName')}", "Turn on", "0xff32d74b") if pick
    else ("tailscale.exit", "Exit node", "none", "0xfff5f5f7"),
    ("tailscale.since",) + since.row("tailscale", "up" if backend == "Running" else "down",
                                     "Connected since" if backend == "Running" else "Off since"),
]

# The action row: what a click on it will do, in the colour of what it does.
if backend == "Running":
    action = ("tailscale.toggle", "Tunnel", "Disconnect", "0xffff453a")
elif backend in ("NeedsLogin", "NeedsMachineAuth"):
    action = ("tailscale.toggle", "Tunnel", "Log in", "0xfff5f5f7")
else:
    action = ("tailscale.toggle", "Tunnel", "Connect", "0xff32d74b")

detail = pathlib.Path(sys.argv[1])
detail.parent.mkdir(parents=True, exist_ok=True)
detail.write_text(
    "".join("\t".join(row) + "\n" for row in rows)
    + "\t".join(action) + "\n",
    encoding="utf-8",
)

print(backend)
PY
)

# Push the rows on every poll rather than when the card opens. The popup is laid
# out from its members, so filling it at open time makes it resize on screen;
# filling it here means the click only has to flip one flag.
if [[ -n "${TUNNEL_AGENT:-}" ]]; then
  case "$(tunnel_state)" in
    up)      tunnel_row="${TUNNEL_NAME:-Tunnel}  ·  connected"$'\t'"Disconnect"$'\t'"0xffff453a" ;;
    pending) tunnel_row="${TUNNEL_NAME:-Tunnel}  ·  connecting"$'\t'"Disconnect"$'\t'"0xffff453a" ;;
    *)       tunnel_row="${TUNNEL_NAME:-Tunnel}  ·  off"$'\t'"Connect"$'\t'"0xff32d74b" ;;
  esac
  print -r -- "tailscale.tunnel"$'\t'"$tunnel_row" >> "$DETAIL_FILE"
  sketchybar --set tailscale.tunnel drawing=on
else
  sketchybar --set tailscale.tunnel drawing=off
fi
"${0:A:h}/popup_rows.sh" "$DETAIL_FILE"

[[ -x "$RENDERER" ]] || exit 0
case "$state" in
  Running)                     motion_show tailscale up render_mark "$CACHE_DIR" ;;
  NeedsLogin|NeedsMachineAuth) motion_show tailscale attention render_mark "$CACHE_DIR" ;;
  *)                           motion_show tailscale down render_mark "$CACHE_DIR" ;;
esac
