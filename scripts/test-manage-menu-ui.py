#!/usr/bin/env python3
"""Desktop acceptance for the activity bar Manage menu and its destinations."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "tests/manage-menu-ui-smoke/haxeon.json"
subprocess.run([str(ROOT / "haxeon/scripts/haxeon"), "build", "--project", str(PROJECT)], check=True)
with tempfile.TemporaryDirectory(prefix="exosuit-manage-menu-") as temporary:
    fixture = Path(temporary)
    native = PROJECT.parent / "build/host/native"
    libraries = [ROOT / "haxeon/out", ROOT / "haxeon/.tools/hashlink",
                 *sorted(path for path in native.iterdir() if path.is_dir())]
    environment = dict(os.environ, LD_LIBRARY_PATH=os.pathsep.join(map(str, libraries)),
                       XDG_STATE_HOME=str(fixture / "state"), PRAGTICAL_PORTABLE=str(fixture / "settings"))
    subprocess.run([str(ROOT / "haxeon/.tools/hashlink/hl"), str(PROJECT.parent / "build/host/main.hl"),
                    str(fixture / "capture")], cwd=ROOT, env=environment, check=True, timeout=30)
