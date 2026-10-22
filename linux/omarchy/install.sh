#!/bin/bash

# Kuro on Omarchy (4.5 or later): Kuro's bar as an Omarchy shell bar plugin,
# and Kuro's look in Hyprland.
#
#   linux/omarchy/install.sh          install and switch to Kuro
#   linux/omarchy/install.sh --off    back to Omarchy's own bar and look
#   linux/omarchy/install.sh --status which bar is in use
#
# The plugin is linked, not copied, so `git pull` updates the running bar
# (the shell reloads it on a rescan, which this does). Nothing is deleted:
# shell.json and hyprland.lua are backed up before they are changed, and
# --off only undoes what this added.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
PLUGIN_ID=kuro.bar
PLUGIN_DIR="$CONFIG/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$CONFIG/omarchy/shell.json"
HYPR_MAIN="$CONFIG/hypr/hyprland.lua"
HYPR_KURO="$CONFIG/hypr/kuro.lua"
REQUIRE='require("hypr.kuro")'
STAMP=$(date +%Y%m%d-%H%M%S)

say() { printf '\033[34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is needed (sudo pacman -S jq)"
command -v omarchy-shell >/dev/null || die "this is for Omarchy 4.5 or later, whose desktop runs in omarchy-shell"

# The bar the shell uses, in shell.json. A user file is canonical once it
# exists (no merge with the defaults), so start from the defaults if there is
# none, and change only bar.id.
set_bar() {
  local id=$1
  mkdir -p "${SHELL_JSON%/*}"
  if [[ ! -f $SHELL_JSON ]]; then
    cp "${OMARCHY_PATH:-/usr/share/omarchy}/config/omarchy/shell.json" "$SHELL_JSON"
  fi
  cp "$SHELL_JSON" "$SHELL_JSON.backup-$STAMP"
  local next
  next=$(jq --arg id "$id" '.bar.id = $id' "$SHELL_JSON")
  printf '%s\n' "$next" > "$SHELL_JSON"
}

reload_shell() {
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
}

case "${1:-}" in
  --status)
    id=$(jq -r '.bar.id // "omarchy.bar"' "$SHELL_JSON" 2>/dev/null || echo omarchy.bar)
    printf 'bar=%s look=%s\n' "$id" "$(grep -qxF "$REQUIRE" "$HYPR_MAIN" 2>/dev/null && echo kuro || echo omarchy)"
    exit 0 ;;
  --off)
    set_bar omarchy.bar
    if grep -qxF "$REQUIRE" "$HYPR_MAIN" 2>/dev/null; then
      cp "$HYPR_MAIN" "$HYPR_MAIN.backup-$STAMP"
      grep -vxF "$REQUIRE" "$HYPR_MAIN.backup-$STAMP" > "$HYPR_MAIN"
    fi
    reload_shell
    hyprctl reload >/dev/null 2>&1 || true
    say "back to Omarchy's bar and look (Kuro's plugin stays installed; run install.sh to switch back)"
    exit 0 ;;
  "") ;;
  *) die "unknown option $1 (try --off or --status)" ;;
esac

# The plugin, linked into the shell's plugin folder.
mkdir -p "${PLUGIN_DIR%/*}"
if [[ -L $PLUGIN_DIR && "$(readlink "$PLUGIN_DIR")" == "$HERE/kuro-bar" ]]; then
  say "plugin already linked"
else
  [[ -e $PLUGIN_DIR || -L $PLUGIN_DIR ]] && mv "$PLUGIN_DIR" "$PLUGIN_DIR.backup-$STAMP"
  ln -s "$HERE/kuro-bar" "$PLUGIN_DIR"
  say "linked $PLUGIN_DIR"
fi

# Kuro's look in Hyprland, loaded after looknfeel.lua so it wins.
ln -sf "$HERE/hypr/kuro.lua" "$HYPR_KURO"
if ! grep -qxF "$REQUIRE" "$HYPR_MAIN"; then
  cp "$HYPR_MAIN" "$HYPR_MAIN.backup-$STAMP"
  awk -v line="$REQUIRE" '{ print } /^require\("hypr\.looknfeel"\)$/ { print line; added = 1 } END { if (!added) print line }' \
    "$HYPR_MAIN.backup-$STAMP" > "$HYPR_MAIN"
  say "added Kuro's look to $HYPR_MAIN"
fi

reload_shell
set_bar "$PLUGIN_ID"
reload_shell
hyprctl reload >/dev/null 2>&1 || true
say "Kuro's bar is on. Back to Omarchy's: $0 --off"
