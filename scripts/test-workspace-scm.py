#!/usr/bin/env python3
"""Run WorkspaceScmService and RPC acceptance against an isolated Git repository."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
os.environ.setdefault("EXOSUIT_SUIT_AUTOSTART", "0")  # tests must not start the user's suit daemon

ROOT = Path(__file__).resolve().parent.parent


def command(arguments: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(arguments, cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="exosuit-workspace-scm-") as temporary:
        directory = Path(temporary)
        root = directory / "repository"
        root.mkdir()
        command(["git", "init", str(root)])
        command(["git", "-C", str(root), "config", "user.name", "Exosuit Test"])
        command(["git", "-C", str(root), "config", "user.email", "exosuit-test@example.invalid"])
        (root / "tracked.txt").write_text("initial repository state\n", encoding="utf-8")
        (root / "large.txt").write_bytes(b"x" * 131073)
        command(["git", "-C", str(root), "add", "tracked.txt"])
        command(["git", "-C", str(root), "add", "large.txt"])
        command(["git", "-C", str(root), "commit", "-m", "fixture"])

        if os.name == "nt":
            command_line = [sys.executable, str(ROOT / "scripts" / "haxeon_cli.py"), "run"]
        else:
            haxeon_root = Path(os.environ.get("HAXEON_ROOT", ROOT / "haxeon"))
            haxeon = os.environ.get("HAXEON_BIN", str(haxeon_root / "scripts" / "haxeon"))
            command_line = [haxeon, "run"]
        compiler_mode = ["--self-hosted"] if os.environ.get("HAXEON_SELF_HOSTED") == "1" else []
        command_line.extend(["--project", str(ROOT / "tests" / "workspace-scm" / "haxeon.json"), *compiler_mode, "--",
            str(root), str(directory / "scm-trust.json")])
        subprocess.run(command_line, cwd=ROOT, check=True, timeout=300)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
