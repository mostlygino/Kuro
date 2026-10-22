#!/bin/zsh

# What CI runs, and what to run before a pull request: every script parses,
# every Swift helper compiles, and the self-tests pass. The golden images
# (sketchybar/assets/render_test.sh) are separate, because CoreGraphics
# antialiasing differs between macOS releases and a runner's would not match.

set -e
cd "${0:A:h}/.."
ASSETS=sketchybar/assets
MEDIA=(mediawatch mediatap mediafit mediaservice mediacall main)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
step() { print -r -- "· $1"; }
fail() { print -r -- "  FAIL $1"; (( failures++ )) || true; }

step "shell scripts parse"
for f in sketchybar/sketchybarrc sketchybar/colors.sh sketchybar/plugins/*.sh $ASSETS/*.sh install.sh scripts/*.sh bordersrc; do
  zsh -n "$f" 2>/dev/null || fail "$f"
done

step "the Omarchy port: its installer parses, its manifest is JSON"
bash -n linux/omarchy/install.sh 2>/dev/null || fail "linux/omarchy/install.sh"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" linux/omarchy/kuro-bar/manifest.json 2>/dev/null || fail "manifest.json"

step "Python compiles, and since.py's self-test"
for f in docs/*.py docs/brand/*.py sketchybar/plugins/*.py; do
  python3 -m py_compile "$f" 2>/dev/null || fail "$f"
done
python3 sketchybar/plugins/since.py --self-test >/dev/null || fail "since.py --self-test"

step "Swift helpers compile"
for f in $ASSETS/*.swift; do
  (( ${MEDIA[(Ie)${f:t:r}]} )) && continue
  # Helpers that talk to SketchyBar over its mach port carry the C shim.
  ipc=()
  grep -q sketchybar_send_args "$f" && ipc=(-import-objc-header $ASSETS/sketchybar_ipc.h $ASSETS/sketchybar_ipc.c)
  xcrun swiftc -O "$f" $ipc -o "$tmp/${f:t:r}" 2>"$tmp/err" || { fail "$f"; sed 's/^/    /' "$tmp/err" | head -20; }
done
xcrun swiftc -O -import-objc-header $ASSETS/sketchybar_ipc.h \
  $ASSETS/${^MEDIA}.swift $ASSETS/sketchybar_ipc.c -o "$tmp/mediawatch" 2>"$tmp/err" \
  || { fail "mediawatch"; sed 's/^/    /' "$tmp/err" | head -20; }

step "the Kuro app builds"
scripts/build-app.sh >"$tmp/app.log" 2>&1 || { fail "scripts/build-app.sh"; grep -E "error:" "$tmp/app.log" | head -20 | sed 's/^/    /'; }

step "self-tests"
[[ -x "$tmp/topguard" ]] && { "$tmp/topguard" --self-test >/dev/null || fail "topguard --self-test"; }

(( failures == 0 )) && print -r -- "check: all passed" || { print -r -- "check: $failures failed"; exit 1; }
