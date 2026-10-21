#!/bin/zsh

# Golden-image check for the drawn marks.
#
#   render_test.sh           render every state and compare against the manifest
#   render_test.sh --bless   accept what it draws now as the new manifest
#
# Both renderers are pure: the same arguments give the same pixels, every time.
# That makes a hash of the output the cheapest possible test, and the states
# below are the ones whose drawing has actually been wrong at some point. A ray
# count that rounded the wrong way, a bolt that vanished under 60% charge, a
# `show` that called itself: all three would have failed here in under a second,
# and all three were instead found by looking at the bar.
#
# The shield is an SF Symbol, so its two hashes belong to the macOS release
# that drew them: after an OS update, look at the shield and re-bless if it is
# still right.
#
# No framework and no fixtures on purpose. The thing being tested is a pixel
# buffer; anything more than "draw it and hash it" would be testing the harness.

ASSETS="${0:A:h}"
MANIFEST="$ASSETS/render_test.sha256"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# name : renderer : arguments. The boundaries matter more than the middles: 88
# and 87 sit either side of the first ray going out, 12 and 11 either side of the
# battery's red, and 0 and 100 are the two ends nobody draws by hand.
cases=(
  "mark-full:usagemark:--percent 100 --color 0xffd97757"
  "mark-boundary-8:usagemark:--percent 88 --color 0xffd97757"
  "mark-boundary-7:usagemark:--percent 87 --color 0xffd97757"
  "mark-half:usagemark:--percent 50 --color 0xffd97757"
  "mark-last-ray:usagemark:--percent 5 --color 0xffff453a"
  "mark-empty:usagemark:--percent 0 --color 0xffff453a"
  "mark-error:usagemark:--percent 100 --color 0xffff453a"
  "battery-full:batterymark:--percent 100 --color 0xff32d74b"
  "battery-warn:batterymark:--percent 34 --color 0xffff9f0a"
  "battery-low:batterymark:--percent 11 --color 0xffff453a"
  "battery-empty:batterymark:--percent 0 --color 0xffff453a"
  "battery-charging-high:batterymark:--percent 78 --color 0xff32d74b --charging"
  "battery-charging-low:batterymark:--percent 6 --color 0xffff453a --charging"
  "vpn-up:vpnmark:--state up"
  "vpn-down:vpnmark:--state down"
  "vpn-pending:vpnmark:--state pending"
  "vpn-attention:vpnmark:--state attention"
  "capsule-on:capsulemark:--state on"
  "capsule-off:capsulemark:--state off"
  "mark-unreachable:usagemark:--error"
  "mark-blocked:usagemark:--blocked"
  "void:voidmark:"
  "orb-busy:orbmark:--color 0xffbf5af2"
  "orb-idle:orbmark:--color 0xff8e8e93"
  "vitals-idle:vitalsmark:--heat 0"
  "vitals-light:vitalsmark:--heat 15"
  "vitals-working:vitalsmark:--heat 40"
  "vitals-between:vitalsmark:--heat 55"
  "vitals-heavy:vitalsmark:--heat 70"
  "vitals-maxed:vitalsmark:--heat 100"
  "vitals-pressure:vitalsmark:--heat 15 --tone busy"
  "vitals-critical:vitalsmark:--heat 15 --tone critical"
  "vitals-dead:vitalsmark:--heat 0 --tone dead"
  "wifi-full:wifimark:--dots 4 --color 0xffbf5af2"
  "wifi-fair:wifimark:--dots 2 --color 0xffff6ac1"
  "wifi-offline:wifimark:--dots 3 --color 0xffff453a"
  "wifi-searching:wifimark:--dots 0 --color 0xff8e8e93"
  "wifi-off:wifimark:--dots 0 --color 0xff8e8e93 --off"
  "wifi-ethernet:wifimark:--ethernet --color 0xffbf5af2"
  "wifi-ethernet-offline:wifimark:--ethernet --color 0xffff453a"
)

# Built from source if the source is newer, so the test can never pass against a
# binary that predates the change being tested.
for renderer in usagemark batterymark vpnmark capsulemark orbmark wifimark voidmark vitalsmark; do
  if [[ ! -x "$ASSETS/$renderer" || "$ASSETS/$renderer.swift" -nt "$ASSETS/$renderer" ]]; then
    /usr/bin/xcrun swiftc -O "$ASSETS/$renderer.swift" -o "$ASSETS/$renderer" 2>/dev/null || {
      print -u2 "render_test: cannot build $renderer"
      exit 2
    }
  fi
done

typeset -a results
for entry in "${cases[@]}"; do
  name="${entry%%:*}"
  rest="${entry#*:}"
  renderer="${rest%%:*}"
  args=("${(z)rest#*:}")
  "$ASSETS/$renderer" "${args[@]}" --out "$WORK/$name.png" || {
    print -u2 "render_test: $name failed to render"
    exit 2
  }
  results+=("$(/usr/bin/shasum -a 256 "$WORK/$name.png" | cut -d' ' -f1)  $name")
done

if [[ "$1" == "--bless" ]]; then
  print -l -- "${results[@]}" > "$MANIFEST"
  print "render_test: blessed ${#results} states"
  exit 0
fi

if [[ ! -r "$MANIFEST" ]]; then
  print -u2 "render_test: no manifest, run with --bless once the drawing is right"
  exit 2
fi

# Compared line by line rather than by hashing the whole manifest, so a failure
# names the state that changed instead of saying only that something did.
failed=0
expected=("${(@f)$(<"$MANIFEST")}")
for line in "${results[@]}"; do
  name="${line##*  }"
  want=""
  for candidate in "${expected[@]}"; do
    [[ "${candidate##*  }" == "$name" ]] && want="${candidate%%  *}"
  done
  got="${line%%  *}"
  if [[ -z "$want" ]]; then
    print "NEW   $name"
    failed=1
  elif [[ "$want" != "$got" ]]; then
    print "CHANGED $name"
    failed=1
  fi
done

(( failed )) && { print -u2 "render_test: run with --bless if the change was intended"; exit 1 }
print "render_test: ${#results} states unchanged"
