#!/bin/zsh

# `open`, for agents. Installed as ~/.local/bin/open, ahead of /usr/bin on PATH.
#
# Run by you, it is the system's open and nothing else. Run by an agent (a
# shell under Zeron or Claude Code), it opens in the background, so the app
# does not come forward over your work, and it leaves a claim on the app it
# opens: aerospace.toml's catch-all window rule hands the window that app then
# shows to plugins/agent_space.sh, which puts it on an agent space, F1 to F12.
#
# Apps launched through LaunchServices are children of launchd, not of the
# agent, so nothing at window time can tell an agent's Kagami from yours; the
# claim, made here where the agent is still in the picture, is what can.
#
# URLs and documents open in whatever handles them, often an app of yours
# that is already open (a link becomes a tab in Dia); those are opened in the
# background but not claimed. KURO_AGENT_OPEN=off turns all of it off.

zmodload zsh/datetime
real=/usr/bin/open
agent=false
[[ -n "${CLAUDECODE:-}" ]] && agent=true
(( ${#${(M)${(k)parameters}:#ZERON_*}} )) && agent=true
[[ "$agent" == true && "${KURO_AGENT_OPEN:-}" != off ]] || exec "$real" "$@"

claims="${XDG_CACHE_HOME:-$HOME/.cache}/kuro/agent-claims"
mkdir -p "$claims"

bundle="" args=("$@")
for (( i = 1; i <= ${#args}; i++ )); do
  case "${args[$i]}" in
    -b) bundle="${args[$(( i + 1 ))]:-}" ;;
    -a)
      name="${args[$(( i + 1 ))]:-}"
      app=""
      if [[ "$name" == /* || "$name" == *.app ]]; then app="$name"
      else
        for dir in /Applications /System/Applications /System/Applications/Utilities "$HOME/Applications"; do
          [[ -d "$dir/$name.app" ]] && { app="$dir/$name.app"; break; }
        done
      fi
      [[ -n "$app" ]] && bundle=$(/usr/bin/defaults read "${app:A}/Contents/Info" CFBundleIdentifier 2>/dev/null) ;;
    *.app|*.app/)
      [[ -d "${args[$i]}" ]] && bundle=$(/usr/bin/defaults read "${args[$i]:A}/Contents/Info" CFBundleIdentifier 2>/dev/null) ;;
  esac
done
[[ -n "$bundle" ]] && print -r -- "$EPOCHSECONDS" > "$claims/$bundle"

exec "$real" -g "$@"
