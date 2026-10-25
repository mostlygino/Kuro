#!/usr/bin/env python3
"""Builds the keybinding reference from aerospace.toml, so it can never drift.

    python3 docs/make_keys.py

Writes two views of the same bindings:

  docs/KEYS.md     the page GitHub renders: the layers at a glance, then
                   every binding in four sections, as keycaps
  docs/keys.html   the interactive reference: a Mac keyboard that lights the
                   keys bound under the modifiers you pick, a search box, and
                   every binding by group. cmd-shift-/ opens it (aerospace.toml).
  docs/keys.png    that page's keyboard, rendered by WebKit (docs/snapshot.swift)
                   for the README
and keeps the README's "All N bindings" count in step.

The bindings are read straight out of [mode.main.binding]: each `# --- Group ---`
comment starts a group, each `key = 'command'` (or a list of commands) is a
binding, and a trailing `# note` is kept as its note. The words for each command
come from DESCRIBE below; a command it does not know is shown as itself, so a new
binding still appears, only in AeroSpace's own words.
"""

import json
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = ROOT / "aerospace.toml"
MARKDOWN = ROOT / "docs" / "KEYS.md"
PAGE = ROOT / "docs" / "keys.html"
README = ROOT / "README.md"
IMAGE = ROOT / "docs" / "keys.png"
CARD_RADIUS = 56  # px at 2x, the keys.png corners

MODS = ["cmd", "ctrl", "alt", "shift"]
GLYPH = {"cmd": "⌘", "ctrl": "⌃", "alt": "⌥", "shift": "⇧"}
KEY_GLYPH = {"left": "←", "right": "→", "up": "↑", "down": "↓", "tab": "⇥",
             "backspace": "⌫", "enter": "↩", "minus": "−", "equal": "=", "slash": "/",
             "space": "Space"}

# What each command does, in words. Directions and numbers are filled in.
DESCRIBE = [
    (r"^focus (left|right|up|down)$", "Focus the window {0}", "focus"),
    (r"^swap (left|right|up|down)$", "Swap with the window {0}", "swap"),
    (r"^join-with (left|right|up|down)$", "Stack with the window {0}", "stack"),
    (r"^move-workspace-to-monitor (left|right|up|down)$", "Move the workspace to the screen {0}", "to screen"),
    (r"^workspace (\d+)$", "Go to workspace {0}", "go {0}"),
    (r"^workspace S$", "Go to the scratch workspace", "scratch"),
    (r"^exec-and-forget .*agent_space\.sh look F(\d+)$", "Look at agent space F{0}", "agent"),
    (r"^move-node-to-workspace F(\d+)$", "Send the window to agent space F{0}, stay here", "to agent"),
    (r"^move-node-to-workspace --focus-follows-window (\d+)$", "Move the window to workspace {0} and follow", "take {0}"),
    (r"^move-node-to-workspace (\d+)$", "Move the window to workspace {0}, stay here", "send {0}"),
    (r"^move-node-to-workspace S$", "Send the window to the scratch workspace", "stash"),
    (r"^workspace next$", "Next workspace", "next"),
    (r"^workspace prev$", "Previous workspace", "prev"),
    (r"^workspace-back-and-forth$", "Back to the last workspace", "last"),
    (r"^focus dfs-next$", "Next window", "next"),
    (r"^focus dfs-prev$", "Previous window", "prev"),
    (r"^focus-monitor next$", "Next screen", "screen"),
    (r"^focus-monitor prev$", "Previous screen", "screen"),
    (r"^close$", "Close the window", "close"),
    (r"^close-all-windows-but-current.*$", "Close every other window", "others"),
    (r"^layout floating tiling$", "Float or tile the window", "float"),
    (r"^fullscreen$", "Fullscreen", "full"),
    (r"^layout tiles horizontal vertical$", "Flip the split", "flip"),
    (r"^resize smart -(\d+)$", "Shrink by {0} pt", "−{0}"),
    (r"^resize smart \+(\d+)$", "Grow by {0} pt", "+{0}"),
    (r"^reload-config$", "Reload the AeroSpace config", "reload"),
    (r"^exec-and-forget .*kuro-apply\.sh.*$", "Apply your own bindings and reload AeroSpace", "reload"),
    (r"^exec-and-forget open .*keys\.html$", "Open this reference", "keys"),
    (r"^echo .*ignored$", "Blocked, so no app can use it", "blocked"),
]


def describe(command: str) -> tuple[str, str]:
    """What a command does, in a sentence and in a word for its key."""
    for pattern, words, short in DESCRIBE:
        m = re.match(pattern, command)
        if m:
            return words.format(*m.groups()), short.format(*m.groups())
    return command, command.split()[0]


def parse(text: str) -> list[dict]:
    """Groups of bindings from [mode.main.binding], in file order."""
    section = text.split("[mode.main.binding]", 1)[1].split("\n[", 1)[0]
    groups: list[dict] = []
    current = None
    lines = section.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        i += 1
        heading = re.match(r"#\s*---\s*(.+?)(\s*---)?\s*$", line)
        if heading:
            name = re.sub(r"\s*\(.*$", "", heading.group(1)).strip(" -")
            current = {"name": name, "bindings": []}
            groups.append(current)
            continue
        m = re.match(r"^([a-z0-9-]+)\s*=\s*(.*)$", line)
        if not m or current is None:
            continue
        key, rest = m.group(1), m.group(2)
        note = ""
        if rest.startswith("["):
            body = rest
            while "]" not in body and i < len(lines):
                body += "\n" + lines[i]
                i += 1
            commands = re.findall(r"'([^']*)'", body)
        else:
            value = re.match(r"'([^']*)'\s*(#\s*(.*))?$", rest)
            commands = [value.group(1)] if value else []
            note = (value.group(3) or "").strip() if value else ""
        action = next((c for c in commands if "sketchybar --trigger" not in c), commands[0] if commands else "")
        parts = key.split("-")
        mods = [p for p in parts if p in MODS]
        base = "-".join(p for p in parts if p not in MODS)
        current["bindings"].append({"key": key, "mods": mods, "base": base, "command": action,
                                    "does": describe(action)[0], "short": describe(action)[1], "note": note})
    return [g for g in groups if g["bindings"]]


def combo(mods: list[str]) -> str:
    return "".join(GLYPH[m] for m in ["ctrl", "alt", "shift", "cmd"] if m in mods)


ARROWS = ("left", "right", "up", "down")

# KEYS.md folds the config's small groups into four sections, so GitHub shows a
# few full tables instead of a dozen one-row ones. A group not named here gets a
# section of its own.
SECTIONS = [
    ("Windows", ["Focus", "Swap", "Stack", "Window", "Window cycling", "Resize"],
     "Arrows move between windows; the modifiers decide what comes along."),
    ("Workspaces", ["Workspaces", "Workspace cycling", "Scratch workspace", "Agent spaces"],
     "Workspace numbers belong to screens: one screen has 1 to 10, two share 1 to 5 "
     "(main) and 6 to 10, three 1 to 4, 5 to 7 and 8 to 10. The bar keeps them there "
     "whenever a screen comes or goes. The agent spaces F1 to F12 are hidden workspaces "
     "for what agents open, one layer up on the same number row."),
    ("Screens", ["Screen focus", "Move the workspace to another screen"], ""),
    ("Everything else", ["Everything else"], ""),
]


def rows(group: dict) -> list[tuple[list[str], str, str]]:
    """A group's bindings as (mods, key, what) rows, with the four arrows and the
    ten digits of one modifier folded into one row each."""
    out, seen = [], set()
    for b in group["bindings"]:
        if b["key"] in seen:
            continue
        family = None
        if b["base"] in ARROWS:
            family = [x for x in group["bindings"] if x["mods"] == b["mods"] and x["base"] in ARROWS]
            key, what = "←↑↓→", re.sub(r"\b(left|right|up|down)\b", "in that direction", b["does"])
        elif b["base"].isdigit():
            family = [x for x in group["bindings"] if x["mods"] == b["mods"] and x["base"].isdigit()]
            key, what = "1…0", re.sub(r"\bF\d+\b", "F1 to F10", re.sub(r"\b\d+\b", "1 to 10", b["does"]))
        if family and len(family) > 1:
            seen.update(x["key"] for x in family)
            out.append((b["mods"], key, what))
            continue
        seen.add(b["key"])
        out.append((b["mods"], KEY_GLYPH.get(b["base"], b["base"].upper()), b["does"]))
    return out


def caps(mods: list[str], key: str) -> str:
    """Keycaps for GitHub, held together by non-breaking spaces so a combo
    never wraps across lines in a table cell."""
    if key == "←↑↓→":
        keys = list(key)
    elif key == "1…0":
        keys = ["1", "…", "0"]
    else:
        keys = [key] if key else []
    held = [GLYPH[m] for m in ["ctrl", "alt", "shift", "cmd"] if m in mods]
    return "&nbsp;".join(k if k == "…" else f"<kbd>{k}</kbd>" for k in held + keys)


def glance(groups: list[dict]) -> list[str]:
    """One table of the layers: a row per modifier combo, a column for the
    arrows, the digits and tab, and in each cell the word on that key."""
    # The arrows and digits say it in the word on the key; tab's sentences are
    # already short, and its words (next, prev) would not say next what.
    columns = [("←↑↓→", lambda base: base in ARROWS, lambda b: b["short"]),
               ("1…0", str.isdigit, lambda b: re.sub(r"\s*\d+$", "", b["short"])),
               ("⇥", lambda base: base == "tab", lambda b: b["does"])]
    table: dict[tuple, list[str]] = {}
    for g in groups:
        for b in g["bindings"]:
            for c, (_, fits, word) in enumerate(columns):
                if fits(b["base"]):
                    cells = table.setdefault(tuple(b["mods"]), [""] * len(columns))
                    cells[c] = cells[c] or word(b).capitalize()
    head = "| Hold | " + " | ".join(caps([], k) for k, _, _ in columns) + " |"
    lines = [head, "|---|" + ":---:|" * len(columns)]
    for mods, cells in table.items():
        lines.append(f"| {caps(list(mods), '')} | "
                     + " | ".join(cells) + " |")
    return lines


def sections(groups: list[dict]) -> list[tuple[str, str, list[dict]]]:
    by_name = {g["name"]: g for g in groups}
    named = {n for _, names, _ in SECTIONS for n in names}
    out = [(title, lead, [by_name[n] for n in names if n in by_name]) for title, names, lead in SECTIONS]
    out += [(g["name"], "", [g]) for g in groups if g["name"] not in named]
    return [s for s in out if s[2]]


def write_markdown(groups: list[dict]) -> None:
    count = sum(len(g["bindings"]) for g in groups)
    parts = sections(groups)
    nav = " · ".join(f"<a href=\"#{title.lower().replace(' ', '-')}\">{title}</a>" for title, _, _ in parts)
    legend = " &nbsp; ".join(f"<kbd>{g}</kbd> {w}" for g, w in
                             [("⌘", "Command"), ("⌥", "Option"), ("⌃", "Control"), ("⇧", "Shift"),
                              ("⇥", "Tab"), ("⌫", "Delete"), ("↩", "Return")]
                             if g in "⌘⌥⌃⇧" or any(KEY_GLYPH.get(b["base"]) == g
                                                   for x in groups for b in x["bindings"]))
    out = [
        "<h1 align=\"center\">Keys</h1>",
        "",
        f"<p align=\"center\">All {count} AeroSpace bindings in Kuro, read straight out of "
        "<a href=\"../aerospace.toml\"><code>aerospace.toml</code></a>, so this page cannot drift from the config."
        "<br>The layout follows Omarchy, with <kbd>⌘</kbd> in the place of its Super key.</p>",
        "",
        "<p align=\"center\"><img src=\"keys.png\" alt=\"The Kuro keyboard under Command: every bound key lit "
        "in its group's colour, with the word for what it does\" width=\"100%\"></p>",
        "",
        "<p align=\"center\"><sub>The <kbd>⌘</kbd> layer. Each key wears its group's colour and the word for "
        "what it does.</sub></p>",
        "",
        "> [!TIP]",
        f"> {caps(['cmd', 'shift'], '/')} opens the interactive version: the same keyboard, lighting up under "
        "whatever modifiers you hold, with search. GitHub shows [`keys.html`](keys.html) as source, so open it "
        "locally with `open docs/keys.html`.",
        "",
        f"<p align=\"center\">{legend}</p>",
        "",
        f"<p align=\"center\">{nav}</p>",
        "",
        "## At a glance",
        "",
        "The same keys work on every layer; the modifiers you hold decide what moves. <em>Take</em> moves the "
        "window and follows it, <em>send</em> moves it and stays.",
        "",
        *glance(groups),
    ]
    for title, lead, members in parts:
        out += ["", f"## {title}", ""]
        if lead:
            out += [lead, ""]
        out += ["| Keys | Does |", "|---|---|"]
        out += [f"| {caps(mods, key)} | {what} |" for g in members for mods, key, what in rows(g)]
    out += ["", "---", "",
            "<sub>Generated by <code>python3 docs/make_keys.py</code>, which also writes "
            "<code>keys.html</code> and <code>keys.png</code>. Edit the config, not this file.</sub>"]
    MARKDOWN.write_text("\n".join(out) + "\n", encoding="utf-8")


def write_page(groups: list[dict]) -> None:
    data = json.dumps([{"name": g["name"], "bindings": [
        {k: b[k] for k in ("key", "mods", "base", "does", "short", "note")} for b in g["bindings"]]}
        for g in groups], ensure_ascii=False)
    template = (ROOT / "docs" / "keys.template.html").read_text(encoding="utf-8")
    PAGE.write_text(template.replace("/*BINDINGS*/[]", data), encoding="utf-8")


def write_image() -> None:
    """The page's keyboard under ⌘, snapshotted by WebKit at 2x."""
    from PIL import Image, ImageDraw
    with tempfile.TemporaryDirectory() as t:
        tool, shot = pathlib.Path(t) / "snapshot", pathlib.Path(t) / "page.png"
        subprocess.run(["/usr/bin/xcrun", "swiftc", "-O", str(ROOT / "docs" / "snapshot.swift"), "-o", str(tool)],
                       check=True, capture_output=True)
        # poster() leaves the keyboard and its legend, so the whole page is the still.
        subprocess.run([str(tool), str(PAGE), str(shot), "1280", "poster()"], check=True)
        # Rounded corners over transparency, so the still sits on GitHub's light
        # and dark themes alike as a card rather than a dark rectangle.
        page = Image.open(shot).convert("RGBA")
        mask = Image.new("L", page.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, page.width - 1, page.height - 1), radius=CARD_RADIUS, fill=255)
        page.putalpha(mask)
        page.save(IMAGE, optimize=True)


def main() -> None:
    groups = parse(CONFIG.read_text(encoding="utf-8"))
    write_markdown(groups)
    write_page(groups)
    write_image()
    count = sum(len(g["bindings"]) for g in groups)
    # The README says how many there are; it said 66 long after there were 89.
    readme = README.read_text(encoding="utf-8")
    README.write_text(re.sub(r"All \d+ bindings", f"All {count} bindings", readme), encoding="utf-8")
    print(f"wrote docs/KEYS.md, docs/keys.html and docs/keys.png: {count} bindings in {len(groups)} groups")


if __name__ == "__main__":
    main()
