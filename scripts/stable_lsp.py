#!/usr/bin/env python3
"""Launch the Haxeon language server bundled with this stable snapshot."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from pathlib import Path


def is_dynamic_library(path: Path) -> bool:
    name = path.name.lower()
    return name.endswith((".dll", ".hdll", ".dylib")) or re.search(r"\.so(?:\.\d+)*$", name) is not None


bundle = Path(__file__).resolve().parent
runtime_name = "hl.exe" if os.name == "nt" else "hl"
runtime = bundle / "haxeon" / ".tools" / "hashlink" / runtime_name
server = bundle / "haxeon" / "out" / "haxeon-lsp.hl"
if not runtime.is_file() or not server.is_file():
    raise SystemExit(f"Stable Haxeon language server is incomplete: {bundle}")

roots = [
    bundle / "haxeon" / ".tools" / "hashlink",
    bundle / "haxeon" / "out",
    bundle / "graphical" / "native",
    bundle / "agent" / "native",
]
directories = []
for root in roots:
    if root.is_dir():
        candidates = [root, *(item for item in root.iterdir() if item.is_dir())]
        directories.extend(
            str(path)
            for path in candidates
            if any(item.is_file() and is_dynamic_library(item) for item in path.iterdir())
        )
variable = "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
inherited = os.environ.get(variable)
if inherited:
    directories.append(inherited)
os.environ[variable] = os.pathsep.join(directories)
os.environ["HAXEON_HOME"] = str(bundle / "haxeon")
os.environ["HAXEON_ROOT"] = str(bundle / "haxeon")
lease = bundle / f".running-lsp-{os.getpid()}-{time.time_ns()}"
lease.write_text(str(os.getpid()) + "\n", encoding="ascii")
try:
    result = subprocess.run([str(runtime), str(server), *sys.argv[1:]], check=False)
finally:
    lease.unlink(missing_ok=True)
raise SystemExit(result.returncode)
