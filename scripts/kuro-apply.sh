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

set -u
REPO="${0:A:h:h}"
BASE="$REPO/aerospace.toml"
KURO="${XDG_CONFIG_HOME:-$HOME/.config}/kuro"
LOCAL="$KURO/aerospace.local.toml"
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
  while IFS= read -r line || [[ -n "$line" ]]; do
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
