"""Run the Haxeon CLI with the toolchain for the current platform."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
import sys


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

    haxe = haxeon_root / ".tools" / "haxe" / "haxe.exe"
    hashlink = haxeon_root / ".tools" / "hashlink" / "hl.exe"
    if not haxe.is_file():
        raise RuntimeError(
            "Pinned Haxe compiler is not bootstrapped; run the Haxeon Windows "
            "toolchain bootstrap first"
        )
    if not hashlink.is_file():
        return subprocess.run(
            [
                str(haxe),
                "-cp",
                str(haxeon_root / "src"),
                "--run",
                "tools.HaxeonCli",
                *arguments,
            ],
            env=environment,
            check=False,
        ).returncode

    cli = haxeon_root / "out" / "haxeon-cli.hl"
    sources = list((haxeon_root / "src").rglob("*.hx"))
    rebuild_cli = not cli.is_file() or haxe.stat().st_mtime_ns > cli.stat().st_mtime_ns
    if cli.is_file() and not rebuild_cli:
        rebuild_cli = any(source.stat().st_mtime_ns > cli.stat().st_mtime_ns for source in sources)

    if rebuild_cli:
        cli.parent.mkdir(parents=True, exist_ok=True)
        temporary = cli.with_name(f"{cli.name}.tmp.{os.getpid()}")
        try:
            result = subprocess.run(
                [
                    str(haxe),
                    "-cp",
                    str(haxeon_root / "src"),
                    "-main",
                    "tools.HaxeonCli",
                    "-hl",
                    str(temporary),
                ],
                env=environment,
                check=False,
            )
            if result.returncode != 0:
                return result.returncode
            os.replace(temporary, cli)
        finally:
            temporary.unlink(missing_ok=True)

    hashlink_directory = hashlink.parent
    runtime_directory = haxeon_root / "out"
    environment["PATH"] = ";".join(
        [str(hashlink_directory), str(runtime_directory), environment.get("PATH", "")]
    )
    return subprocess.run(
        [str(hashlink), str(cli), *arguments], env=environment, check=False
    ).returncode


def main() -> int:
    project_root = Path(
        os.environ.get("EXOSUIT_PROJECT_ROOT") or Path(__file__).resolve().parent.parent
    ).expanduser().resolve()
    return run_cli(project_root, sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
