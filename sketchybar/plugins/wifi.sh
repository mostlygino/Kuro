#!/bin/zsh

# Wi-Fi: four drawn dots lit as far as the signal reaches, and a card with
# everything about the link.
#
#   wifi.sh             poll: badge and card
#   wifi.sh toggle      the card's last row: Wi-Fi off or on
#   wifi.sh network     the card's first row: open Wi-Fi settings, or ask for
#                       the Location permission the network name needs
#
# The readings come from assets/wifiinfo.app, a CoreWLAN one-shot that lives
# in a signed bundle because the network name is location data on macOS 14 and
# later; see that file. Everything else is measured here: the address, the
# router and how long it takes to answer, and whether the internet answers too.
#
# Dots follow the received signal: -55 dBm or better lights all four, -65
# three, -75 two, -85 one, weaker still none. All lit dots share one colour,
# and the colour says the count: orange for one, pink for two, cyan for three,
# purple for four. A change of signal eases from one to the next round the
# colour wheel (assets/wifimark). Red when the internet is not answering,
# whatever the signal; a flatline when Wi-Fi is off.

ASSETS="${CONFIG_DIR:-$HOME/.config/sketchybar}/assets"
RENDERER="$ASSETS/wifimark"
APP="$ASSETS/wifiinfo.app"
INFO="$APP/Contents/MacOS/wifiinfo"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/wifi"
DETAIL_FILE="$CACHE_DIR/detail"
PENDING="$CACHE_DIR/.pending"

# One colour per dot count, one to four: orange, pink, cyan, purple. The pink
# is a true pink, 0xffff6ac1: Apple's systemPink, 0xffff375f, sits so close to
# the red that means no internet that two dots read as a warning.
DOT_COLORS="0xffff9f0a 0xffff6ac1 0xff64d2ff 0xffbf5af2"
POOR_COLOR=0xffff453a
# The card's internet row: a check when it answers, the cross is POOR_COLOR.
CHECK_COLOR=0xff32d74b
# The card's warnings: a router that does not answer, a toggle in progress.
WEAK_COLOR=0xffff9f0a
OFF_COLOR=0xff8e8e93
MUTED=0xff8e8e93

source "${0:A:h}/motion.sh"
[[ -r "${CONFIG_DIR:-$HOME/.config/sketchybar}/local.sh" ]] \
  && source "${CONFIG_DIR:-$HOME/.config/sketchybar}/local.sh"
mkdir -p "$CACHE_DIR"

# Built on first run and whenever the sources change, signed with the same
# identity as mediawatch when there is one, so the Location permission survives
# a rebuild. Ad-hoc otherwise: everything but the network name still works.
build() {
  if [[ ! -x "$INFO" || "$ASSETS/wifiinfo.swift" -nt "$INFO" || "$ASSETS/wifiinfo-Info.plist" -nt "$INFO" \
        || "$ASSETS/wifiinfo.entitlements" -nt "$INFO" ]]; then
    mkdir -p "$APP/Contents/MacOS"
    cp "$ASSETS/wifiinfo-Info.plist" "$APP/Contents/Info.plist"
    /usr/bin/xcrun swiftc -O "$ASSETS/wifiinfo.swift" -o "$INFO" 2>/dev/null || return 1
    if [[ -n "${MEDIAWATCH_SIGN_ID:-}" ]] \
        && /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -qF "$MEDIAWATCH_SIGN_ID"; then
      /usr/bin/codesign --force --options runtime --entitlements "$ASSETS/wifiinfo.entitlements" \
        --sign "$MEDIAWATCH_SIGN_ID" "$APP" >/dev/null 2>&1
    else
      /usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1
    fi
  fi
  if [[ ! -x "$RENDERER" || "$ASSETS/wifimark.swift" -nt "$RENDERER" ]]; then
    /usr/bin/xcrun swiftc -O "$ASSETS/wifimark.swift" -o "$RENDERER" 2>/dev/null || return 1
    motion_purge "$CACHE_DIR"
  fi
}
build || exit 0

# The key is "<dots>-<colour>-<on|off>", or "eth-<colour>-on" on a cable.
render_mark() {
  local mode="$1" target="$3"
  local -a k=("${(@s:-:)2}") f=("${(@s:-:)4}")
  local args
  if [[ "$k[1]" == eth ]]; then
    args=(--ethernet --color "$k[2]")
  else
    args=(--dots "$k[1]" --color "$k[2]")
    [[ "$k[3]" == off ]] && args+=(--off)
  fi
  case "$mode" in
    still) "$RENDERER" "${args[@]}" --out "$target" ;;
    transition)
      if [[ "$f[1]" == eth ]]; then
        args+=(--from-ethernet --from-color "$f[2]")
      else
        args+=(--from-dots "$f[1]" --from-color "$f[2]")
        [[ "$f[3]" == off ]] && args+=(--from-off)
      fi
      "$RENDERER" "${args[@]}" --transition "$target" ;;
  esac
}

case "$1" in
  toggle)
    power=$(/usr/sbin/networksetup -getairportpower en0 2>/dev/null)
    if [[ "$power" == *": On" ]]; then
      print -r -- "Turning off…" > "$PENDING"
      sketchybar --set wifi.toggle label="Turning off…" label.color="$WEAK_COLOR"
      /usr/sbin/networksetup -setairportpower en0 off
    else
      print -r -- "Turning on…" > "$PENDING"
      sketchybar --set wifi.toggle label="Turning on…" label.color="$WEAK_COLOR"
      /usr/sbin/networksetup -setairportpower en0 on
      sleep 3
    fi
    rm -f "$PENDING"
    exec "$0"
    ;;
  network)
    auth=$("$INFO" 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("authorization",""))' 2>/dev/null)
    if [[ "$auth" == undetermined ]]; then
      /usr/bin/open "$APP" --args --authorize
    elif [[ "$auth" == denied ]]; then
      /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
    else
      /usr/bin/open "x-apple.systempreferences:com.apple.wifi-settings-extension"
    fi
    exit 0
    ;;
esac

state=$(PYTHONPATH="${0:A:h}" /usr/bin/python3 - "$INFO" "$DETAIL_FILE" "$DOT_COLORS" "$POOR_COLOR" "$WEAK_COLOR" "$OFF_COLOR" "$MUTED" "$CHECK_COLOR" <<'PY' 2>/dev/null
import json, pathlib, re, subprocess, sys, time
import since

info, detail, dot_colours, poor, weak, off_colour, muted, check = sys.argv[1:9]
tiers = dot_colours.split()

def run(*args, timeout=3):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""

# Launched through LaunchServices rather than run directly: macOS checks the
# Location permission against the responsible process, which for a child of
# this script is SketchyBar, not the signed bundle that holds the permission.
# Run directly the name comes back nil; opened, the bundle answers for itself.
# `-g` keeps it in the background, and it costs about 0.1 s.
app = str(pathlib.Path(info).parents[2])
out = pathlib.Path(detail).with_name(".probe")
try:
    out.unlink(missing_ok=True)
    run("/usr/bin/open", "-g", "-W", "--stdout", str(out), app)
    w = json.loads(out.read_text())
except (OSError, ValueError):
    w = {}
if not w:
    try:
        w = json.loads(run(info))
    except ValueError:
        w = {}

def ping(host):
    """Round trip in ms, or None. One packet, one second."""
    out = run("/sbin/ping", "-c", "1", "-t", "1", "-q", host, timeout=2)
    m = re.search(r"= [\d.]+/([\d.]+)/", out)
    return round(float(m.group(1))) if m else None

def internet_check():
    """(row value, colour) and whether the internet answers. A ping answers the
    common case; when it does not, the page macOS itself uses to detect captive
    portals tells "blocked ping" from "sign-in page" from "nothing at all"."""
    internet_ms = ping("1.1.1.1")
    portal = "" if internet_ms is not None else run(
        "/usr/bin/curl", "-s", "-m", "2", "http://captive.apple.com/hotspot-detect.html", timeout=3)
    online = internet_ms is not None or "Success" in portal
    if internet_ms is not None:
        return (f"✓  {internet_ms} ms", check), True
    if online:
        return ("✓  Connected", check), True
    if portal:
        return ("✕  Sign-in needed", poor), False
    return ("✕  No internet", poor), False

def wired():
    """The first Ethernet or LAN port with a live link and an address: its
    hardware name, device and negotiated speed. Thunderbolt Bridge is a
    Mac-to-Mac link, not a cable to a network, and is left out. Asked of the
    ports themselves, not of the default route, which a VPN takes over."""
    for block in run("/usr/sbin/networksetup", "-listallhardwareports").split("\n\n"):
        m = re.search(r"Hardware Port: (.+)\nDevice: (\S+)", block)
        if not m:
            continue
        name, dev = m.groups()
        if not re.search(r"Ethernet|LAN", name) or "Bridge" in name:
            continue
        cfg = run("/sbin/ifconfig", dev)
        if "status: active" not in cfg or "\tinet " not in cfg:
            continue
        media = re.search(r"media: .*?\((\d+)[bB]ase", cfg)
        return name, dev, int(media.group(1)) if media else 0
    return None

rows = []
cable = wired()
if cable:
    # A cable in: the badge shows the port, and the card is about the cable.
    # Wi-Fi keeps its switch at the bottom.
    name, dev, speed = cable
    internet, online = internet_check()
    colour = tiers[3] if online else poor
    kind = "USB adapter" if "USB" in name else "Thunderbolt" if "Thunderbolt" in name else "Adapter"
    if speed >= 1000:
        rate = f"{speed / 1000:g} Gbit/s"
    elif speed:
        rate = f"{speed} Mbit/s"
    else:
        rate = "unknown"
    address = run("/usr/sbin/ipconfig", "getifaddr", dev).strip() or "none"
    router = run("/usr/sbin/ipconfig", "getoption", dev, "router").strip()
    router_ms = ping(router) if router else None
    powered = bool(w.get("power"))
    rows = [
        ("wifi.network", "Ethernet", kind, None),
        ("wifi.since",) + since.row("wifi", f"eth:{dev}", "Connected since") + (None,),
        ("wifi.internet", "Internet", *internet),
        ("wifi.rate", "Link speed", rate, None),
        ("wifi.address", "This Mac", address, None),
        ("wifi.router", f"Router  ·  {router or 'none'}", f"{router_ms} ms" if router_ms is not None else "no answer", None if router_ms is not None else weak),
        ("wifi.toggle", "Wi-Fi", "Turn off" if powered else "Turn on", "0xffff453a" if powered else "0xff32d74b"),
    ]
    pathlib.Path(detail).write_text(
        "".join("\t".join([item, ctx, val] + ([col] if col else ["0xfff5f5f7"])) + "\n"
                for item, ctx, val, col in rows), encoding="utf-8")
    print(f"eth-{colour}-on", " ".join(r[0] for r in rows))
    raise SystemExit(0)

if not w.get("present"):
    print("NONE")
    raise SystemExit(0)

iface = w.get("interface") or "en0"

# Since when, in every state: off, searching, or on this network. Joining a
# different network starts the clock again; see since.py.
if not w.get("power"):
    key = f"0-{off_colour}-off"
    rows = [("wifi.network", "Wi-Fi", "Off", muted),
            ("wifi.since",) + since.row("wifi", "off", "Off since") + (muted,),
            ("wifi.toggle", "Wi-Fi", "Turn on", "0xff32d74b")]
elif not w.get("associated"):
    key = f"0-{off_colour}-on"
    rows = [("wifi.network", "Wi-Fi", "Not connected", muted),
            ("wifi.since",) + since.row("wifi", "searching", "Searching since") + (muted,),
            ("wifi.toggle", "Wi-Fi", "Turn off", "0xffff453a")]
else:
    rssi, noise = int(w.get("rssi", -100)), int(w.get("noise", -100))
    dots = 4 if rssi >= -55 else 3 if rssi >= -65 else 2 if rssi >= -75 else 1 if rssi >= -85 else 0
    quality = ["Weak", "Weak", "Fair", "Good", "Excellent"][dots]
    address = run("/usr/sbin/ipconfig", "getifaddr", iface).strip() or "none"
    router = run("/usr/sbin/ipconfig", "getoption", iface, "router").strip()
    router_ms = ping(router) if router else None
    # Strong Wi-Fi is not the internet.
    internet, online = internet_check()
    colour = poor if not online else tiers[max(1, dots) - 1]

    name = w.get("ssid")
    if name:
        network = (name, None)
    elif w.get("authorization") in ("undetermined", "denied"):
        # Clicking the row asks for it; see `wifi.sh network`.
        network = ("Allow Location", muted)
    else:
        network = ("Hidden", muted)

    rows = [
        ("wifi.network", "Network", network[0], network[1]),
        ("wifi.since",) + since.row("wifi", f"on:{w.get('ssid') or 'network'}", "Connected since") + (None,),
        ("wifi.internet", "Internet", *internet),
        ("wifi.signal", f"Signal  ·  {rssi} dBm", f"{quality}  ·  SNR {rssi - noise} dB", None),
        ("wifi.radio", f"{w.get('band')}  ·  channel {w.get('channel')}", f"{w.get('phy', '')}  ·  {w.get('width')} MHz", None),
        ("wifi.rate", "Link rate", f"{round(float(w.get('rate', 0)))} Mbps", None),
        ("wifi.security", "Security", w.get("security", ""), None),
        ("wifi.address", "This Mac", address, None),
        ("wifi.router", f"Router  ·  {router or 'none'}", f"{router_ms} ms" if router_ms is not None else "no answer", None if router_ms is not None else weak),
        ("wifi.toggle", "Wi-Fi", "Turn off", "0xffff453a"),
    ]
    key = f"{dots}-{colour}-on"

pathlib.Path(detail).write_text(
    "".join("\t".join([item, ctx, val] + ([col] if col else ["0xfff5f5f7"])) + "\n"
            for item, ctx, val, col in rows), encoding="utf-8")
print(key, " ".join(r[0] for r in rows))
PY
)

[[ -n "$state" ]] || exit 0
if [[ "$state" == NONE ]]; then
  sketchybar --set wifi drawing=off
  exit 0
fi

read -r key shown <<< "$state"
motion_show wifi "$key" render_mark "$CACHE_DIR"

# Rows that apply are filled; the rest leave the card, so an off radio is a
# two-row card rather than seven blanks.
"${0:A:h}/popup_rows.sh" "$DETAIL_FILE"
args=()
for row in network since internet signal radio rate security address router toggle; do
  if [[ " $shown " == *" wifi.$row "* ]]; then
    args+=(--set "wifi.$row" drawing=on)
  else
    args+=(--set "wifi.$row" drawing=off)
  fi
done
sketchybar "${args[@]}"
