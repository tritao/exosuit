"""Run the Haxeon CLI with the toolchain for the current platform."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
import sys

import haxeon_paths


def run_cli(
    project_root: Path,
    arguments: list[str],
    environment_overrides: dict[str, str] | None = None,
) -> int:
    haxeon_root = Path(
        os.environ.get("HAXEON_ROOT") or str(project_root / "haxeon")
    ).expanduser().resolve(strict=True)
    if not haxeon_root.is_dir():
        raise RuntimeError(f"Haxeon checkout is not a directory: {haxeon_root}")

    environment = os.environ.copy()
    environment["HAXEON_ROOT"] = str(haxeon_root)
    environment["HAXEON_HOME"] = str(haxeon_root)
    # The CLI run as `hl haxeon-cli.hl` finds its SDK from this, as the haxeon launcher tells it.
    environment["HAXEON_SDK"] = str(haxeon_root / "out" / "sdk")
    if environment_overrides:
        environment.update(environment_overrides)

    haxeon_bin = os.environ.get("HAXEON_BIN")
    if haxeon_bin:
        return subprocess.run(
            [haxeon_bin, *arguments], env=environment, check=False
        ).returncode

    if os.name != "nt":
        haxeon_script = haxeon_root / "scripts" / "haxeon"
        return subprocess.run(
            [str(haxeon_script), *arguments], env=environment, check=False
        ).returncode

    # On Windows hl.exe runs the CLI's bytecode from the VM directory: the command line keeps `hl.exe ... haxeon-cli.hl`,
    # which exohost classifies, and HAXEON_HOME stays the caller's (haxeon.exe would overwrite it with its build checkout).
    hashlink = haxeon_paths.hl(haxeon_root)
    cli = haxeon_paths.cli(haxeon_root)
    if not hashlink.is_file() or not cli.is_file():
        raise RuntimeError(
            f"The Haxeon VM is not built ({hashlink if not hashlink.is_file() else cli} is missing); "
            "run scripts/build-windows.ps1"
        )
    # As scripts/haxeon does on POSIX, bring the CLI's bytecode up to date with its sources first (the inputs its CMake rule names).
    built = cli.stat().st_mtime_ns
    inputs = [
        haxeon_root / "common.hxml",
        haxeon_root / ".tools" / "haxe" / "haxe.exe",
        *(haxeon_root / "src").rglob("*.hx"),
        *(haxeon_root / "lib").rglob("*.hx"),
    ]
    if any(source.is_file() and source.stat().st_mtime_ns > built for source in inputs):
        build = subprocess.run(
            ["cmake", "--build", "--preset", "windows-msvc", "--target", "haxeon-command"],
            cwd=haxeon_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if build.returncode != 0:
            raise RuntimeError(
                f"{build.stdout}Rebuilding the Haxeon CLI ({cli}) failed; run scripts/build-windows.ps1"
            )
    environment["PATH"] = ";".join(
        [str(hashlink.parent), str(haxeon_root / "out"), environment.get("PATH", "")]
    )
    return subprocess.run(
        [str(hashlink), str(cli), *arguments], env=environment, check=False
    ).returncode


def main() -> int:
    project_root = Path(
        os.environ.get("EXOSUIT_PROJECT_ROOT") or Path(__file__).resolve().parent.parent
    ).expanduser().resolve()
    try:
        return run_cli(project_root, sys.argv[1:])
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 127


if __name__ == "__main__":
    raise SystemExit(main())
