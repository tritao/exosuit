#!/usr/bin/env python3
"""Measure a 202-node continuous UI with no client, idle client, inspection and detailed tracking."""
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from importlib.util import spec_from_file_location, module_from_spec

ROOT = Path(__file__).resolve().parent.parent


def main():
    specification = spec_from_file_location("devtools_test", ROOT / "scripts/test-devtools.py")
    helper = module_from_spec(specification)
    specification.loader.exec_module(helper)
    artifacts = ROOT / "build/devtools-overhead"
    artifacts.mkdir(parents=True, exist_ok=True)
    artifacts.chmod(0o700)
    endpoint = str(artifacts / "inspection.sock")
    native = ROOT / "haxeon/out/packages/ui/native"
    libraries = [ROOT / "haxeon/out", ROOT / "haxeon/.tools/hashlink", native, native / "nativekit", native / "nativekit/modules/gpu"]
    environment = dict(os.environ, LD_LIBRARY_PATH=os.pathsep.join(map(str, libraries)))
    subprocess.run([str(helper.CLI), "build", "--project", str(ROOT / "tests/devtools/haxeon.json")], check=True, stdout=subprocess.DEVNULL)
    with (artifacts / "target.log").open("w") as log:
        target = subprocess.Popen([str(ROOT / "haxeon/.tools/hashlink/hl"), str(ROOT / "tests/devtools/build/host/main.hl"),
                                   "--fixture", endpoint, str(artifacts), "100"], env=environment, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 20
            while not Path(endpoint).exists():
                assert target.poll() is None, (artifacts / "target.log").read_text()
                assert time.monotonic() < deadline
                time.sleep(.02)
            start = time.time()
            time.sleep(2)
            with socket.socket(socket.AF_UNIX) as peer:
                peer.settimeout(5)
                peer.connect(endpoint)
                idle = time.time()
                time.sleep(2)
                inspect = time.time()
                for _ in range(8):
                    helper.request(peer, full=False)
                    time.sleep(.25)
                detailed = time.time()
                for _ in range(8):
                    helper.request(peer, details=True)
                    time.sleep(.25)
                end = time.time()
            assert target.wait(timeout=15) == 0, (artifacts / "target.log").read_text()
            rows = [json.loads(line) for line in (artifacts / "frame-timeline.jsonl").read_text().splitlines()]
            report = {}
            for label, begin, finish in [("no client", start + .5, idle), ("connected idle", idle, inspect),
                                          ("inspection 4Hz", inspect, detailed), ("detailed 4Hz", detailed, end)]:
                frames = [row for row in rows if begin <= row["startedAtSeconds"] < finish]
                cpu = sorted(row["frameSeconds"] * 1000 for row in frames)
                intervals = sorted((b["startedAtSeconds"] - a["startedAtSeconds"]) * 1000 for a, b in zip(frames, frames[1:]))
                report[label] = dict(frames=len(frames), median_cpu_ms=round(statistics.median(cpu), 3),
                                     p95_interval_ms=round(intervals[int(.95 * (len(intervals) - 1))], 3))
            (artifacts / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, indent=2))
        finally:
            if target.poll() is None:
                target.terminate()
                target.wait(timeout=5)


if __name__ == "__main__":
    main()
