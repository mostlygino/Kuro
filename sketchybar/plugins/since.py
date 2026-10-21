"""Since when a badge has been in its current state, for the cards' "since" rows.

    import since                      # from a plugin's Python, PYTHONPATH=plugins
    since.row("tailscale", "up", "Connected since")  ->  ("Connected since 08:12", "2 h 3 min")

    python3 since.py ago <seconds>    # from a shell plugin: "2 h 3 min"
    python3 since.py --self-test      # the rules below, checked

Each badge keeps one line under ~/.cache/sketchybar/since/<name>: its state and
the moment it entered it. A poll that sees the same state leaves the moment
alone, a different state starts the clock again. On disk rather than in memory
because every poll is a fresh process and a reload must not reset the clocks.

The moment is when a poll first saw the state, not when the change happened:
nothing here was watching while the bar was not running. Every poll is seconds
to a minute apart, which is well inside the minute the rows are written to.
"""

import pathlib
import sys
import time

DIRECTORY = pathlib.Path.home() / ".cache" / "sketchybar" / "since"


def track(name, state, now=None):
    """The epoch `name` entered `state`, starting the clock if it just did."""
    now = int(now or time.time())
    path = DIRECTORY / name
    try:
        recorded, _, moment = path.read_text().strip().rpartition(" ")
        if recorded == state:
            return int(moment)
    except (OSError, ValueError):
        pass
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    path.write_text(f"{state} {now}\n")
    return now


def ago(seconds):
    """A duration the way a card says it: just now, 25 min, 2 h 3 min, 1 d 4 h."""
    minutes = max(0, int(seconds)) // 60
    if minutes < 1:
        return "just now"
    if minutes < 60:
        return f"{minutes} min"
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return f"{hours} h {minutes} min"
    return f"{hours // 24} d {hours % 24} h"


def clock(epoch):
    """08:12 today, Mon 08:12 on an earlier day."""
    moment = time.localtime(epoch)
    if time.strftime("%Y%m%d", moment) == time.strftime("%Y%m%d"):
        return time.strftime("%H:%M", moment)
    return time.strftime("%a %H:%M", moment)


def row(name, state, label, now=None):
    """(context, value) for a card row: "<label> 08:12" and how long ago."""
    now = int(now or time.time())
    started = track(name, state, now)
    return f"{label} {clock(started)}", ago(now - started)


def self_test():
    """The rules above, checked against a scratch directory."""
    import tempfile
    global DIRECTORY
    DIRECTORY = pathlib.Path(tempfile.mkdtemp())
    assert ago(0) == ago(59) == "just now"
    assert ago(60) == "1 min" and ago(3599) == "59 min"
    assert ago(3600) == "1 h 0 min" and ago(3 * 3600 + 180) == "3 h 3 min"
    assert ago(26 * 3600) == "1 d 2 h"
    assert track("x", "up", 1000) == 1000
    assert track("x", "up", 5000) == 1000, "the same state keeps its moment"
    assert track("x", "down", 6000) == 6000, "a new state starts the clock"
    context, value = row("x", "down", "Off since", 7500)
    assert value == "25 min" and context.startswith("Off since "), (context, value)
    print("since.py: ok")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "ago":
        print(ago(int(sys.argv[2])))
    elif sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit("usage: since.py ago <seconds> | --self-test")
