#!/bin/zsh

# Installs this setup on a Mac: AeroSpace, SketchyBar and JankyBorders, wired
# together from this repository.
#
#   ./install.sh                  link the configs and start everything
#   ./install.sh --deps           install the Homebrew packages first
#   ./install.sh --hide-menubar   also set the macOS menu bar to auto-hide
#   ./install.sh --no-start       link only, start nothing
#   ./install.sh --agent-open     also put the agents' `open` in ~/.local/bin
#   ./install.sh --no-app         skip building the Kuro app into ~/Applications
#
# The configs are symlinked, not copied, so `git pull` updates the running bar.
# Anything already at a target path is moved aside to `<path>.backup-<time>`
# first; nothing is deleted. Running it again is safe: links that already point
# here are left alone.

set -euo pipefail

REPO="${0:A:h}"
STAMP=$(date +%Y%m%d-%H%M%S)
WANT_DEPS=0 HIDE_MENUBAR=0 START=1 AGENT_OPEN=0 APP=1

for arg in "$@"; do
  case "$arg" in
    --deps) WANT_DEPS=1 ;;
    --hide-menubar) HIDE_MENUBAR=1 ;;
    --no-start) START=0 ;;
    --agent-open) AGENT_OPEN=1 ;;
    --no-app) APP=0 ;;
    -h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "install.sh: unknown option $arg (try --help)"; exit 2 ;;
  esac
done

say() { print -P "%F{blue}==>%f $*"; }
warn() { print -P "%F{yellow}warning:%f $*" >&2; }
die() { print -P "%F{red}error:%f $*" >&2; exit 1; }

[[ "$(uname)" == Darwin ]] || die "this is a macOS setup"

# The bar's watchers and drawn badges are Swift, compiled on first run by the
# plugins that use them, so the command line tools are a hard requirement.
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  die "swiftc not found. Install the Xcode command line tools: xcode-select --install"
fi

command -v brew >/dev/null 2>&1 || die "Homebrew not found: https://brew.sh"

if (( WANT_DEPS )); then
  say "Installing Homebrew packages"
  brew install felixkratz/formulae/sketchybar felixkratz/formulae/borders media-control
  brew install --cask nikitabobko/tap/aerospace font-hack-nerd-font
fi

missing=()
for bin in sketchybar borders aerospace media-control; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
(( ${#missing} == 0 )) || die "missing: ${missing[*]}. Run ./install.sh --deps"

# Moves whatever is in the way aside, then links. A link that already points
# at this repository is the finished state and is left as it is.
link() {
  local source="$1" target="$2"
  if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
    say "already linked: $target"
    return
  fi
  mkdir -p "${target:h}"
  if [[ -e "$target" || -L "$target" ]]; then
    mv "$target" "$target.backup-$STAMP"
    say "moved the old $target to $target.backup-$STAMP"
  fi
  ln -s "$source" "$target"
  say "linked $target"
}

link "$REPO/sketchybar" "$HOME/.config/sketchybar"
# ~/.aerospace.toml is built from aerospace.toml plus your own additions in
# ~/.config/kuro/aerospace.local.toml (scripts/kuro-apply.sh), so the repository
# carries nobody's personal bindings and `git pull` keeps working: ⌥⌘C rebuilds.
"$REPO/scripts/kuro-apply.sh" || warn "AeroSpace did not accept the config; see above"
link "$REPO/bordersrc" "$HOME/.config/borders/bordersrc"
# `open` for agents: the system's open for you, and for a shell under Zeron or
# Claude Code it opens in the background and sends the app's window to an
# agent space (sketchybar/plugins/agent_open.sh). ~/.local/bin comes ahead of
# /usr/bin on PATH. Opt in only: it stands in front of the system's open.
if (( AGENT_OPEN )); then
  link "$REPO/sketchybar/plugins/agent_open.sh" "$HOME/.local/bin/open"
else
  say "skipped the agents' open (--agent-open adds it; see Workspaces in the README)"
fi
chmod +x "$REPO/bordersrc" "$REPO"/sketchybar/sketchybarrc "$REPO"/sketchybar/plugins/*.sh

if [[ ! -e "$REPO/sketchybar/local.sh" ]]; then
  cp "$REPO/sketchybar/local.sh.example" "$REPO/sketchybar/local.sh"
  say "created sketchybar/local.sh for your own settings"
fi

# Clicking the time opens Notification Center by pressing the system's own
# "Show Notification Center" shortcut, which ships unbound. Bind it to F19,
# unless it already has a key.
if ! defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys 2>/dev/null \
    | grep -A2 '^ *163 = ' | grep -q 'enabled = 1'; then
  defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 163 \
    '<dict><key>enabled</key><true/><key>value</key><dict><key>type</key><string>standard</string><key>parameters</key><array><integer>65535</integer><integer>80</integer><integer>8388608</integer></array></dict></dict>'
  /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u >/dev/null 2>&1 || true
  say "bound Show Notification Center to F19 (the clock presses it)"
fi

# cmd-shift-3 to 6 move a window to a workspace in aerospace.toml, and macOS
# takes those four first for its screenshots and the Touch Bar shot. Switched
# off here; ctrl-cmd-shift-3 and 4 still take a screenshot to the clipboard.
# Each is "<hotkey id>:<character code>:<key code>", the parameters macOS keeps.
for entry in 28:51:20 30:52:21 184:53:23 181:54:22; do
  parts=("${(@s/:/)entry}")
  defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "${parts[1]}" \
    "<dict><key>enabled</key><false/><key>value</key><dict><key>type</key><string>standard</string><key>parameters</key><array><integer>${parts[2]}</integer><integer>${parts[3]}</integer><integer>1179648</integer></array></dict></dict>"
done
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u >/dev/null 2>&1 || true
say "switched off the macOS screenshot keys on cmd-shift-3 to 6 (AeroSpace uses them)"

if (( HIDE_MENUBAR )); then
  # The bar sits where the menu bar would be and gets out of its way when the
  # pointer reveals it, so the menu bar has to be set to hide.
  say "Setting the menu bar to hide automatically"
  defaults write NSGlobalDomain _HIHideMenuBar -bool true
  killall SystemUIServer 2>/dev/null || true
fi

# AeroSpace runs under launchd, which restarts it if it crashes (see the plist).
# Copied rather than linked: launchd reads agents at load time and does not
# want them to be symlinks into a repository that might move.
AGENT="$HOME/Library/LaunchAgents/sh.kuro.aerospace.plist"
mkdir -p "${AGENT:h}"
if ! cmp -s "$REPO/launchd/sh.kuro.aerospace.plist" "$AGENT" 2>/dev/null; then
  cp "$REPO/launchd/sh.kuro.aerospace.plist" "$AGENT"
  say "installed $AGENT"
fi

if (( START )); then
  say "Starting SketchyBar"
  brew services restart sketchybar >/dev/null
  if ! launchctl print "gui/$UID/sh.kuro.aerospace" >/dev/null 2>&1; then
    # Hand AeroSpace over to launchd: quit the copy that started itself, then
    # let the agent start the one that gets restarted.
    osascript -e 'if application "AeroSpace" is running then tell application "AeroSpace" to quit' \
      >/dev/null 2>&1 || true
    sleep 1
    launchctl bootstrap "gui/$UID" "$AGENT"
  else
    aerospace reload-config >/dev/null 2>&1 || true
  fi
  pgrep -xq borders || "$REPO/bordersrc" >/dev/null 2>&1 &!
fi

# The Kuro app: settings, repair and updates, from now on. The app itself
# runs this script, so it skips building itself while it is the one asking.
if (( APP )) && [[ -z "${KURO_APP_RUNNING:-}" ]]; then
  say "Building the Kuro app"
  "$REPO/scripts/build-app.sh" --install | grep '==>' || warn "the Kuro app did not build; the desktop works without it"
fi

cat <<'EOF'

Done. A few things macOS asks for once:

  - AeroSpace: Accessibility, when it first starts.
  - SketchyBar: Accessibility, only if you click the app name (it sends a key).
  - mediawatch: System Audio Recording, for the live waveform on podcasts.
    Set MEDIAWATCH_SIGN_ID in sketchybar/local.sh so it only asks once.
  - Claude usage badge: keychain access to "Claude Code-credentials" the first
    time. It needs Claude Code logged in; without it the badge stays hidden.

The bar takes about 20 seconds on first start while it compiles its Swift
helpers. If the menu bar still covers it, run ./install.sh --hide-menubar.
EOF
