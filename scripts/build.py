#!/usr/bin/env python3
"""Build the graphical app with the Haxeon CLI."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from haxeon_cli import run_cli


def main() -> int:
    root_dir = Path(__file__).resolve().parent.parent
    arguments = [
        "build",
        "--project",
        str(root_dir / "graphical" / "haxeon.json"),
    ]
    if os.environ.get("HAXEON_SELF_HOSTED", "0") == "1":
        arguments.append("--self-hosted")
    arguments.extend(sys.argv[1:])

    try:
        return run_cli(root_dir, arguments)
    except (OSError, RuntimeError) as error:
        print(f"Unable to prepare the Haxeon CLI: {error}", file=sys.stderr)
        return 127


if __name__ == "__main__":
    sys.exit(main())
