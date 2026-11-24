#!/usr/bin/env python3
"""timeout.py [--kill-after=SECONDS] SECONDS COMMAND [ARG...]: coreutils `timeout` for machines without it (macOS).

Runs COMMAND in its own process group. After SECONDS it sends SIGTERM to the group, and SIGKILL --kill-after seconds
later if anything is still running. Exits with COMMAND's status, or 124 when it timed out, as coreutils does.
"""
import os
import signal
import subprocess
import sys


def main(argv: list[str]) -> int:
    kill_after = None
    while argv and argv[0].startswith("--kill-after"):
        option = argv.pop(0)
        kill_after = float(option.split("=", 1)[1] if "=" in option else argv.pop(0))
    if len(argv) < 2:
        print("usage: timeout.py [--kill-after=SECONDS] SECONDS COMMAND [ARG...]", file=sys.stderr)
        return 125
    seconds = float(argv[0])
    process = subprocess.Popen(argv[1:], start_new_session=True)

    # The command has its own session, so pass an interrupt or stop on to it as coreutils would.
    def forward(signum, _frame):
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    try:
        status = process.wait(timeout=seconds)
        # A command ended by signal N exits 128+N, as with coreutils, not Python's -N.
        return 128 - status if status < 0 else status
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return 124
    try:
        process.wait(timeout=kill_after if kill_after is not None else None)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    return 124


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
