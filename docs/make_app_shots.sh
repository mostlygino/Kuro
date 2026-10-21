#!/bin/zsh

# Screenshots of the Kuro app for the README, from its --demo mode, so they
# show a made-up Mac and nothing of yours. Each window is captured by its id,
# so it works while the app sits on an agent space off screen.
#
#   docs/make_app_shots.sh     after scripts/build-app.sh

set -eu
REPO="${0:A:h:h}"
APP="$REPO/build/Kuro.app"
OUT="${KURO_SHOTS_OUT:-$REPO/docs}"
[[ -d "$APP" ]] || { print -u2 "make_app_shots.sh: build the app first (scripts/build-app.sh)"; exit 1; }

shot() {
  local name="$1"; shift
  local before after id
  before=$(/opt/homebrew/bin/aerospace list-windows --monitor all --app-bundle-id dev.mostlygino.kuro --format '%{window-id}' 2>/dev/null | sort)
  /usr/bin/open -n "$APP" --args "$@" --quit-after 14
  for _ in {1..40}; do
    sleep 0.25
    after=$(/opt/homebrew/bin/aerospace list-windows --monitor all --app-bundle-id dev.mostlygino.kuro --format '%{window-id}' 2>/dev/null | sort)
    id=$(comm -13 <(print -r -- "$before") <(print -r -- "$after") | head -1)
    [[ -n "$id" ]] && break
  done
  [[ -n "$id" ]] || { print -u2 "make_app_shots.sh: no window for $name"; return 1; }
  sleep "${SETTLE:-4}"
  /usr/sbin/screencapture -x -o -l "$id" "$OUT/app-$name.png"
  print -r -- "wrote ${OUT#$REPO/}/app-$name.png"
  while /usr/bin/pgrep -f "Kuro.app/Contents/MacOS/Kuro --demo" >/dev/null; do sleep 0.5; done
}

shot welcome      --demo fresh --step welcome
shot requirements --demo fresh --step requirements
shot badges       --demo fresh --step badges
shot health       --demo ready --section health
shot keys         --demo ready --section keys
shot updates      --demo ready --section updates
