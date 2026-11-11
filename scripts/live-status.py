#!/usr/bin/env python3
"""Print what the live-mode watcher last did with an edit.

`scripts/run.py --live` (haxeon `run --watch --live`) appends one JSON event per line to
<output>.watch-events.jsonl: rebuild-started, output-line, build-failed, build-ok, patch-published, and from the
running app patch-applied, patch-rejected, reload. This prints the last rebuild's state, revision and errors, and
exits 1 when it failed or the app refused its patch, 2 when there is no events file.

    python scripts/live-status.py                      # graphical/build/host/live.hl, what run.py --live uses
    python scripts/live-status.py path/to/main.hl      # another watched output
    python scripts/live-status.py --history 20         # also the last 20 events (output lines left out)
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
from pathlib import Path

ERROR_LINE = re.compile(r"^(?:[A-Za-z]:[\\/])?[^:]+:\d+:|failed|error", re.IGNORECASE)


def default_output() -> Path:
    return Path(__file__).resolve().parent.parent / "graphical" / "build" / "host" / "live.hl"


def when(milliseconds: object) -> str:
    if not isinstance(milliseconds, (int, float)):
        return "-"
    moment = datetime.datetime.fromtimestamp(milliseconds / 1000)
    return f"{moment:%H:%M:%S} ({int((datetime.datetime.now() - moment).total_seconds())} s ago)"


def describe(event: dict) -> str:
    kind = event.get("kind", "?")
    parts = [when(event.get("time")), kind]
    for key in ("build", "revision"):
        if event.get(key) is not None:
            parts.append(f"{key}={event[key]}")
    if event.get("changedFiles"):
        parts.append(", ".join(event["changedFiles"]))
    if event.get("reloadReasons"):
        parts.append("reload: " + ", ".join(event["reloadReasons"]))
    if event.get("message"):
        parts.append(event["message"])
    return "  ".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output", nargs="?", type=Path, default=default_output(), help="the watched output (default: %(default)s)")
    parser.add_argument("--history", type=int, metavar="N", default=0, help="also print the last N events")
    options = parser.parse_args()

    path = Path(str(options.output) + ".watch-events.jsonl")
    if not path.is_file():
        print(f"no watch events at {path}: is `run.py --live` running, with a haxeon that writes them?", file=sys.stderr)
        return 2
    events = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue  # a line still being written
        if isinstance(event, dict):
            events.append(event)

    # The last rebuild: its output and result, then what the app did with it.
    start = max((index for index, event in enumerate(events) if event.get("kind") == "rebuild-started"), default=None)
    state, revision, running, message = "watching", None, None, ""
    errors: list[str] = []
    for event in events[start:] if start is not None else events:
        kind = event.get("kind")
        if kind == "rebuild-started":
            state = "building"
        elif kind == "output-line" and ERROR_LINE.search(event.get("line") or ""):
            errors.append(event["line"])
        elif kind == "build-failed":
            state = "failed"
        elif kind == "build-ok":
            state, revision = "ok", event.get("revision", revision)
        elif kind == "patch-published":
            revision = event.get("revision", revision)
        elif kind == "patch-applied":
            state, running, message = "ok", event.get("revision"), event.get("message") or ""
        elif kind == "patch-rejected":
            state, message = "patch-rejected", event.get("message") or ""
        elif kind == "reload":
            message = event.get("message") or ""
    for event in events:
        reloaded = event.get("kind") == "reload" and (event.get("message") or "").startswith("reloaded")
        if (event.get("kind") == "patch-applied" or reloaded) and event.get("revision") is not None:
            running = event["revision"]

    started = events[start] if start is not None else None
    print(f"state:     {state}")
    print(f"revision:  {'-' if revision is None else revision}   running: {'-' if running is None else running}")
    if started is not None:
        print(f"rebuild:   {started.get('build')} at {when(started.get('time'))}")
        if started.get("changedFiles"):
            print("changed:   " + "\n           ".join(started["changedFiles"]))
    if message:
        print(f"message:   {message}")
    if state == "failed":
        print(f"errors ({len(errors)}):" if errors else "errors: none recognised; the build's output:")
        lines = errors or [event.get("line", "") for event in events[start:] if event.get("kind") == "output-line"][:40]
        for line in lines:
            print("  " + line)
    print(f"file:      {path}")

    if options.history > 0:
        print()
        recent = [event for event in events if event.get("kind") != "output-line"][-options.history:]
        for event in recent:
            print(describe(event))

    return 1 if state in ("failed", "patch-rejected") else 0


if __name__ == "__main__":
    sys.exit(main())
