#!/usr/bin/env python3
"""agentkit: core unit tests, then the NativeKit transport and the Workbench provider against a local mock model (no paid APIs)."""
import os, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HAXEON = ROOT / "haxeon"
core = HAXEON / "packages/agentkit/tests"
subprocess.run([str(HAXEON / "scripts/haxeon"), "build", "--project", str(core / "haxeon.json")], check=True, stdout=subprocess.DEVNULL)
env = dict(os.environ, LD_LIBRARY_PATH=f"{HAXEON / 'out'}:{HAXEON / '.tools/hashlink'}")
subprocess.run([str(HAXEON / ".tools/hashlink/hl"), str(core / "build/host/main.hl")], env=env, check=True)
for check in ("tests/agentkit-transport/run.py", "tests/agentkit-provider/run.py"):
    subprocess.run([sys.executable, str(ROOT / check)], check=True)
