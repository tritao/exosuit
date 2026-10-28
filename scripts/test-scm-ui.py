#!/usr/bin/env python3
"""Run Source Control UI acceptance on native Windows or a Linux display."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
os.environ.setdefault("EXOSUIT_SUIT_AUTOSTART", "0")  # tests must not start the user's suit daemon

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "tests" / "decoration-ui-smoke" / "haxeon.json"


def run(arguments: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None,
        expected: bool = True, stdout: int | None = None,
        stderr: int | None = None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(arguments, cwd=cwd, env=env, stdout=stdout, stderr=stderr,
                            text=True, check=False, timeout=300)
    if expected and result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, arguments,
                                            output=result.stdout, stderr=result.stderr)
    if not expected and result.returncode == 0:
        raise RuntimeError(f"command unexpectedly succeeded: {' '.join(arguments)}")
    return result


def git(repository: Path, *arguments: str) -> None:
    run(["git", "-C", str(repository), *arguments], stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE)


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as stream:
        stream.write(content)


def make_conflict_repo(repository: Path) -> None:
    repository.mkdir(parents=True)
    write(repository / "Main.hx", "class Main { static function main():Int { return 42; } }\n")
    git(repository, "-c", "init.defaultBranch=main", "init")
    git(repository, "config", "user.name", "SCM UI Test")
    git(repository, "config", "user.email", "scm-ui@example.invalid")
    for name in ("staged.txt", "changed.txt", "conflict.txt"):
        write(repository / name, "base\n")
    git(repository, "add", ".")
    git(repository, "commit", "-m", "baseline")

    write(repository / "staged.txt", "staged\n")
    git(repository, "add", "staged.txt")
    write(repository / "changed.txt", "changed\n")
    write(repository / "untracked.txt", "untracked\n")
    git(repository, "switch", "-c", "conflict-side")
    write(repository / "conflict.txt", "theirs\n")
    git(repository, "add", "conflict.txt")
    git(repository, "commit", "-m", "theirs")
    git(repository, "switch", "main")
    write(repository / "conflict.txt", "ours\n")
    git(repository, "add", "conflict.txt")
    git(repository, "commit", "-m", "ours")
    run(["git", "-C", str(repository), "merge", "conflict-side"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, expected=False)


def make_mutation_repo(repository: Path) -> None:
    repository.mkdir(parents=True)
    write(repository / "Main.hx", "class Main { static function main():Int { return 42; } }\n")
    write(repository / "tracked.txt", "base\n")
    write(repository / "commit.txt", "base\n")
    git(repository, "-c", "init.defaultBranch=main", "init")
    git(repository, "config", "user.name", "SCM UI Test")
    git(repository, "config", "user.email", "scm-ui@example.invalid")
    git(repository, "add", ".")
    git(repository, "commit", "-m", "baseline")
    write(repository / "tracked.txt", "working tree edit\n")
    write(repository / "commit.txt", "commit edit\n")
    git(repository, "add", "commit.txt")


def make_commit_repo(repository: Path) -> None:
    repository.mkdir(parents=True)
    write(repository / "Main.hx", "class Main { static function main():Int { return 42; } }\n")
    write(repository / "commit.txt", "base\n")
    git(repository, "-c", "init.defaultBranch=main", "init")
    git(repository, "config", "user.name", "SCM UI Test")
    git(repository, "config", "user.email", "scm-ui@example.invalid")
    git(repository, "add", ".")
    git(repository, "commit", "-m", "baseline")
    write(repository / "commit.txt", "commit edit\n")
    git(repository, "add", "commit.txt")


def make_submodule_ui_repo(repository: Path, submodule_source: Path) -> None:
    submodule_source.mkdir(parents=True)
    write(submodule_source / "nested-change.txt", "base\n")
    git(submodule_source, "-c", "init.defaultBranch=main", "init")
    git(submodule_source, "config", "user.name", "SCM UI Test")
    git(submodule_source, "config", "user.email", "scm-ui@example.invalid")
    git(submodule_source, "add", "nested-change.txt")
    git(submodule_source, "commit", "-m", "submodule baseline")

    repository.mkdir(parents=True)
    write(repository / "Main.hx", "class Main { static function main():Int { return 42; } }\n")
    git(repository, "-c", "init.defaultBranch=main", "init")
    git(repository, "config", "user.name", "SCM UI Test")
    git(repository, "config", "user.email", "scm-ui@example.invalid")
    git(repository, "-c", "protocol.file.allow=always", "submodule", "add",
        str(submodule_source), "nested")
    git(repository, "add", "Main.hx")
    git(repository, "commit", "-m", "parent baseline")
    write(repository / "nested" / "nested-change.txt", "submodule edit\n")


def make_explorer_status_repo(repository: Path, remote: Path, writer: Path) -> None:
    write(repository / "Main.hx", "class Main { static function main():Int { return 42; } }\n")
    write(repository / "src" / "rollup" / "baseline.txt", "baseline\n")
    git(repository, "-c", "init.defaultBranch=main", "init")
    git(repository, "config", "user.name", "SCM UI Test")
    git(repository, "config", "user.email", "scm-ui@example.invalid")
    git(repository, "add", ".")
    git(repository, "commit", "-m", "baseline")
    run(["git", "-c", "init.defaultBranch=main", "init", "--bare", str(remote)],
        cwd=ROOT, stdout=subprocess.DEVNULL)
    git(repository, "remote", "add", "origin", str(remote))
    git(repository, "push", "--set-upstream", "origin", "main")

    run(["git", "clone", str(remote), str(writer)], cwd=ROOT,
        stdout=subprocess.DEVNULL)
    git(writer, "config", "user.name", "SCM UI Remote Writer")
    git(writer, "config", "user.email", "scm-ui-remote@example.invalid")
    write(writer / "remote-only.txt", "remote commit\n")
    git(writer, "add", "remote-only.txt")
    git(writer, "commit", "-m", "remote-only")
    git(writer, "push", "origin", "main")

    write(repository / "local-only.txt", "local commit\n")
    git(repository, "add", "local-only.txt")
    git(repository, "commit", "-m", "local-only")
    git(repository, "fetch", "origin")
    write(repository / "src" / "rollup" / "new.txt", "untracked Explorer decoration\n")


def haxeon_command() -> list[str]:
    if os.name == "nt":
        command = [sys.executable, str(ROOT / "scripts" / "haxeon_cli.py"), "run"]
    else:
        haxeon_root = Path(os.environ.get("HAXEON_ROOT", ROOT / "haxeon"))
        haxeon = os.environ.get("HAXEON_BIN", str(haxeon_root / "scripts" / "haxeon"))
        command = [haxeon, "run"]
    command.extend(["--project", str(PROJECT)])
    if os.environ.get("HAXEON_SELF_HOSTED") == "1":
        command.append("--self-hosted")
    return command


def display_command(command: list[str]) -> list[str]:
    if sys.platform.startswith("linux"):
        xvfb_run = shutil.which("xvfb-run")
        if xvfb_run is None:
            raise RuntimeError("Linux Source Control UI smoke requires xvfb-run")
        return [xvfb_run, "-a", *command]
    return command


def run_phase(phase: str, source: Path, captures: Path, state: Path) -> None:
    environment = os.environ.copy()
    environment["PRAGTICAL_PORTABLE"] = str(state)
    print(f"== {phase} ==", flush=True)
    run(display_command([*haxeon_command(), "--", str(source), str(captures), phase]),
        cwd=ROOT, env=environment)


def main() -> int:
    if shutil.which("git") is None:
        raise RuntimeError("Git is required for Source Control UI smoke")

    with tempfile.TemporaryDirectory(prefix="exosuite-scm-ui-") as temporary:
        fixture = Path(temporary)
        for phase in ("scm-panel", "scm-panel-phone", "scm-panel-conflict",
                      "scm-panel-remote-read"):
            repository = fixture / phase / "project"
            make_conflict_repo(repository)
            run_phase(phase, repository / "Main.hx", fixture / f"{phase}-captures",
                      fixture / f"state-{phase}")

        phase = "scm-panel-mutations"
        repository = fixture / phase / "project"
        make_mutation_repo(repository)
        run_phase(phase, repository / "Main.hx", fixture / f"{phase}-captures",
                  fixture / f"state-{phase}")

        phase = "scm-panel-commit"
        repository = fixture / phase / "project"
        make_commit_repo(repository)
        run_phase(phase, repository / "Main.hx", fixture / f"{phase}-captures",
                  fixture / f"state-{phase}")

        phase = "scm-panel-submodule"
        repository = fixture / phase / "project"
        make_submodule_ui_repo(repository, fixture / phase / "submodule-source")
        run_phase(phase, repository / "Main.hx", fixture / f"{phase}-captures",
                  fixture / f"state-{phase}")

        phase = "scm-explorer-status"
        repository = fixture / phase / "project"
        repository.mkdir(parents=True)
        make_explorer_status_repo(repository, fixture / phase / "origin.git",
                                  fixture / phase / "writer")
        run_phase(phase, repository / "Main.hx", fixture / f"{phase}-captures",
                  fixture / f"state-{phase}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
