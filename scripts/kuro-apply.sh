#!/bin/zsh

# Builds ~/.aerospace.toml from Kuro's aerospace.toml and your own additions,
# checks it with AeroSpace, and reloads.
#
#   scripts/kuro-apply.sh            build, check, reload; errors on stdout
#   scripts/kuro-apply.sh --notify   the same, errors as a notification (⌥⌘C)
#   scripts/kuro-apply.sh --check    build and check only, then put back what was there
#
# Your additions live in ~/.config/kuro/aerospace.local.toml, out of the
# repository. TOML lets a table be written only once, so the file cannot simply
# be appended: plain `key = 'command'` lines before its first [table] go into
# the main mode, at the `# kuro:local-bindings` line, and its tables go at the
# end. The result is ~/.config/kuro/aerospace.toml, and ~/.aerospace.toml links
# to it. A result AeroSpace rejects is rolled back to the last good one.
#
# Window gaps are a special case of the same problem: [gaps] already lives in
# the repository's aerospace.toml, so it cannot be written a second time from
# the local file. Instead the Kuro app leaves the sizes it chose in
# ~/.config/kuro/gaps (outer=.. inner=..), and this shifts the repository's own
# [gaps] values by the difference from their defaults. The per-monitor top gap
# and its fixed bar/notch offset ride along with the outer value and are never
# rewritten by hand, so the one place that defines the gaps stays the base file.

set -u
REPO="${0:A:h:h}"
BASE="$REPO/aerospace.toml"
KURO="${XDG_CONFIG_HOME:-$HOME/.config}/kuro"
LOCAL="$KURO/aerospace.local.toml"
GAPS="$KURO/gaps"
OUT="$KURO/aerospace.toml"
LINK="$HOME/.aerospace.toml"
AEROSPACE=/opt/homebrew/bin/aerospace
MARKER='# kuro:local-bindings'
mode=apply
[[ "${1:-}" == --notify ]] && mode=notify
[[ "${1:-}" == --check ]] && mode=check

say() {
  if [[ "$mode" == notify ]]; then
    /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' -- "Kuro" "$1" >/dev/null 2>&1
  else
    print -r -- "kuro-apply: $1"
  fi
}

[[ -r "$BASE" ]] || { say "no aerospace.toml in $REPO"; exit 1; }
/usr/bin/grep -qxF "$MARKER" "$BASE" || { say "aerospace.toml has lost its '$MARKER' line"; exit 1; }
mkdir -p "$KURO"

# Adds a signed amount to every integer on one gap line, never below zero, so
# `outer.top = [{ monitor.'built-in' = 46 }, 84]` moves both of its numbers at
# once. Monitor names in [gaps] carry no digits ('built-in'), so only the gap
# sizes are touched.
adjust_gaps() { /usr/bin/perl -pe "s/(\\d+)/my \$n=\$1+($1); \$n<0?0:\$n/ge"; }

# How far the app moved the gaps from the base file's own defaults. An absent
# or malformed ~/.config/kuro/gaps leaves the base values exactly as they are.
gaps_outer="" gaps_inner=""
if [[ -r "$GAPS" ]]; then
  while IFS='=' read -r gk gv; do
    gv="${gv//[[:space:]]/}"
    case "$gk" in
      outer) [[ "$gv" == <-> ]] && gaps_outer="$gv" ;;
      inner) [[ "$gv" == <-> ]] && gaps_inner="$gv" ;;
    esac
  done < "$GAPS"
fi
base_outer=$(/usr/bin/grep -E '^[[:space:]]*outer\.left' "$BASE" | /usr/bin/grep -oE '[0-9]+' | head -1)
base_inner=$(/usr/bin/grep -E '^[[:space:]]*inner\.horizontal' "$BASE" | /usr/bin/grep -oE '[0-9]+' | head -1)
outer_delta=0 inner_delta=0
[[ -n "$gaps_outer" && -n "$base_outer" ]] && outer_delta=$(( gaps_outer - base_outer ))
[[ -n "$gaps_inner" && -n "$base_inner" ]] && inner_delta=$(( gaps_inner - base_inner ))

bindings=() tables=()
if [[ -r "$LOCAL" ]]; then
  in_tables=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == \[* ]] && in_tables=true
    if [[ "$in_tables" == true ]]; then tables+=("$line"); else bindings+=("$line"); fi
  done < "$LOCAL"
fi

new="$OUT.new.$$"
{
  in_gaps=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Inside [gaps], shift the outer and inner lines by the app's amounts.
    if [[ "$line" == "[gaps]" ]]; then
      in_gaps=true
    elif [[ "$line" == \[* ]]; then
      in_gaps=false
    fi
    if [[ "$in_gaps" == true ]]; then
      case "$line" in
        outer.*) (( outer_delta != 0 )) && line=$(print -r -- "$line" | adjust_gaps $outer_delta) ;;
        inner.*) (( inner_delta != 0 )) && line=$(print -r -- "$line" | adjust_gaps $inner_delta) ;;
      esac
    fi
    print -r -- "$line"
    if [[ "$line" == "$MARKER" && ${#bindings} -gt 0 ]]; then
      print -r -- "# --- From $LOCAL ---"
      print -rl -- "${bindings[@]}"
    fi
  done < "$BASE"
  if (( ${#tables} )); then
    print -r -- ""
    print -r -- "# --- From $LOCAL ---"
    print -rl -- "${tables[@]}"
  fi
} > "$new"

# The link moves to the generated file once; a ~/.aerospace.toml that is not a
# link to it (the repository's own file, as install.sh used to make) is kept aside.
if [[ ! -L "$LINK" || "$(readlink "$LINK")" != "$OUT" ]]; then
  [[ -e "$LINK" && ! -L "$LINK" ]] && mv "$LINK" "$LINK.backup-$(date +%Y%m%d-%H%M%S)"
  ln -sfn "$OUT" "$LINK"
fi

previous=""
[[ -e "$OUT" ]] && { previous="$OUT.previous"; cp -p "$OUT" "$previous"; }
mv "$new" "$OUT"

if ! pgrep -xq AeroSpace; then
  [[ "$mode" == check ]] && { [[ -n "$previous" ]] && mv "$previous" "$OUT"; }
  say "written; AeroSpace is not running, so it was not checked"
  exit 0
fi

report=$("$AEROSPACE" reload-config --no-gui --dry-run 2>&1)
if [[ $? -ne 0 ]]; then
  [[ -n "$previous" ]] && mv "$previous" "$OUT"
  say "not applied, AeroSpace says: ${report//$'\n'/ }"
  exit 1
fi
if [[ "$mode" == check ]]; then
  [[ -n "$previous" ]] && mv "$previous" "$OUT"
  say "fine"
  exit 0
fi
[[ -n "$previous" ]] && rm -f "$previous"
"$AEROSPACE" reload-config --no-gui >/dev/null 2>&1
[[ "$mode" == notify ]] || say "applied"
exit 0
