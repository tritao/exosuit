#!/usr/bin/env python3
"""Profile production UIKit startup with disposable state and sampled process memory."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", choices=["long-line", "multiline"], default="long-line")
    parser.add_argument("--bytes", type=int, default=1024 * 1024)
    parser.add_argument("--seconds", type=int, default=45)
    parser.add_argument("--port", type=int, default=7943)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--drive", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.bytes < 1 or args.seconds < 1:
        parser.error("bytes and seconds must be positive")
    if not args.drive:
        return subprocess.call(["xvfb-run", "-a", sys.executable, str(Path(__file__).resolve()),
                                *sys.argv[1:], "--drive"])
    root = Path(__file__).resolve().parent.parent
    haxeon = Path(os.environ.get("HAXEON_ROOT", root / "haxeon")).resolve()
    artifacts = args.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    unit = ("ordinary editable text with é🙂 " * 6 + "\n").encode()
    body = b"a" * args.bytes if args.fixture == "long-line" else (
        unit * (args.bytes // len(unit)) + b"x" * (args.bytes % len(unit)))
    (artifacts / "input.txt").write_bytes(body)
    env = os.environ.copy()
    env["PRAGTICAL_PORTABLE"] = str(artifacts / "state")
    libraries = [haxeon / "out", haxeon / ".tools/hashlink",
                 root / "graphical/build/host/native/pluginhost",
                 root / "graphical/build/host/native/exosuit-ui-native"]
    env["LD_LIBRARY_PATH"] = ":".join(map(str, libraries)) + (
        ":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
    started = time.monotonic()
    samples = []
    timed_out = False
    with (artifacts / "app.log").open("w") as app_log, (artifacts / "profile.log").open("w") as profile_log:
        app = subprocess.Popen([
            str(haxeon / ".tools/hashlink/hl"), "--diagnostics", str(args.port),
            str(root / "graphical/build/host/main.hl"), "--smoke-frames=3",
            "--record-path=" + str(artifacts / "events.jsonl"),
            "--capture-dir=" + str(artifacts / "capture"), str(artifacts / "input.txt")],
            env=env, cwd=artifacts, stdout=app_log, stderr=subprocess.STDOUT, start_new_session=True)
        profiler = None
        try:
            profiler = subprocess.Popen([
                str(haxeon / ".tools/hashlink/hlprof-live"), "--connect-timeout", "15",
                "--duration", str(args.seconds), "--rate", "100", "--interval", "5000",
                "--top", "20", "--output", str(artifacts / "profile.bin"), str(args.port)],
                stdout=profile_log, stderr=subprocess.STDOUT)
            while app.poll() is None:
                elapsed = time.monotonic() - started
                try:
                    status = Path(f"/proc/{app.pid}/status").read_text().splitlines()
                    memory = {line.split(":")[0]: int(line.split()[1]) for line in status
                              if line.startswith(("VmRSS:", "VmHWM:"))}
                    samples.append(dict(seconds=elapsed, **memory))
                except FileNotFoundError:
                    break
                if elapsed >= args.seconds:
                    timed_out = True
                    break
                time.sleep(.2)
        finally:
            if app.poll() is None:
                os.killpg(app.pid, signal.SIGTERM)
                try:
                    app.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
            app.wait()
            if profiler is not None:
                try:
                    profiler.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    profiler.terminate()
                    profiler.wait(timeout=5)
    result = dict(fixture=args.fixture, bytes=args.bytes, seconds=time.monotonic() - started,
                  appExit=app.returncode, timedOut=timed_out,
                  sampledPeakRssKiB=max((s.get("VmHWM", s.get("VmRSS", 0)) for s in samples), default=0),
                  memoryScope="HashLink process only; excludes profiler/Xvfb; sampled every 200 ms",
                  profilerExit=profiler.returncode if profiler is not None else None)
    (artifacts / "memory.json").write_text(json.dumps(samples, indent=2) + "\n")
    (artifacts / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 124 if timed_out else (0 if app.returncode == 0 and profiler is not None and profiler.returncode == 0 else 1)


if __name__ == "__main__":
    sys.exit(main())
