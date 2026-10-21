# Security

Kuro's helpers run as you with Accessibility, Input Monitoring and System Audio Recording permissions: they
read the pointer and keyboard (to guard the top edge), tap audio (for the Now Playing waveform), and run
shell scripts on bar events. Security reports are very welcome.

## Reporting

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/mostlygino/Kuro/security/advisories/new).
Don't open a public issue for a security problem.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get an answer as
soon as the maintainer can; this is a one-person project, so there is no fixed response time.

## Scope

In scope:

- The event taps and pointer handling (`topguard`, `menubarwatch`, `hoverwatch`).
- The Now Playing watcher (`mediawatch`) and its audio tap, and how it reads and caches artwork.
- Anything that builds a shell command or a SketchyBar message from outside data: track titles, window
  titles, network names, app names (`sketchybar_ipc.c`, the plugins).
- The Claude usage badge's use of the Claude Code credential in the keychain (`plugins/claude_usage.sh`).
- `install.sh` and the `open` shim for agents (`plugins/agent_open.sh`).

Out of scope: SketchyBar, AeroSpace, JankyBorders and media-control themselves; report those upstream.
