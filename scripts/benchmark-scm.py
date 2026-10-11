#!/usr/bin/env python3
"""Measure real-repository SCM refresh, wire snapshots, and Git blob reads."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FILE_COUNT = 50_000


def run_git(arguments: list[str], cwd: Path, *, environment: dict[str, str] | None = None) -> None:
    subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        env=environment,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )


def make_synthetic_repository(parent: Path) -> tuple[Path, str]:
    repository = parent / "synthetic-50000"
    repository.mkdir()
    run_git(["init"], repository)

    environment = os.environ.copy()
    environment.update(
        GIT_AUTHOR_NAME="Exosuite SCM benchmark",
        GIT_AUTHOR_EMAIL="scm-benchmark@example.invalid",
        GIT_COMMITTER_NAME="Exosuite SCM benchmark",
        GIT_COMMITTER_EMAIL="scm-benchmark@example.invalid",
    )
    blob_path = "tracked-blob.txt"
    (repository / blob_path).write_text("committed benchmark blob\n", encoding="utf-8")
    run_git(["add", blob_path], repository, environment=environment)
    run_git(["commit", "-m", "seed SCM benchmark"], repository, environment=environment)

    for index in range(FILE_COUNT - 1):
        name = f"untracked-{index:05}.txt"
        (repository / name).write_text(f"synthetic source file {index:05}\n", encoding="utf-8")
    return repository, blob_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository",
        action="append",
        nargs=3,
        metavar=("LABEL", "PATH", "COMMITTED_BLOB"),
        help="also benchmark an existing repository and a committed blob path (repeatable)",
    )
    parser.add_argument(
        "--fixture-dir",
        type=Path,
        help="keep or reuse the synthetic repository in this directory instead of a temporary directory",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="override the Haxeon benchmark module output path",
    )
    arguments = parser.parse_args()

    repositories = arguments.repository or [
        ("exosuit", str(ROOT), "src/scm/ScmSnapshot.hx")
    ]
    temporary = None
    if arguments.fixture_dir is None:
        temporary = tempfile.TemporaryDirectory(prefix="exosuit-scm-benchmark-")
        fixture_parent = Path(temporary.name)
    else:
        fixture_parent = arguments.fixture_dir.resolve()
        fixture_parent.mkdir(parents=True, exist_ok=True)
    try:
        synthetic = fixture_parent / "synthetic-50000"
        started = time.perf_counter()
        reused = synthetic.is_dir()
        if reused:
            file_count = sum(path.is_file() for path in synthetic.iterdir())
            if file_count != FILE_COUNT:
                raise RuntimeError(
                    f"Refusing to reuse {synthetic}: expected {FILE_COUNT} worktree files, found {file_count}"
                )
            blob_path = "tracked-blob.txt"
        else:
            synthetic, blob_path = make_synthetic_repository(fixture_parent)
        print(
            f"SCM_BENCH_FIXTURE files={FILE_COUNT} untracked={FILE_COUNT - 1} "
            f"creation_ms={(time.perf_counter() - started) * 1000:.1f} reused={str(reused).lower()}",
            flush=True,
        )
        command = [
            sys.executable,
            str(ROOT / "scripts" / "haxeon_cli.py"),
            "run",
            "--project",
            str(ROOT / "tests" / "scm-git" / "haxeon.json"),
            "--",
            "--scm-benchmark",
        ]
        for label, repository, committed_blob in repositories:
            command.extend([label, repository, committed_blob])
        command.extend(["synthetic-50000", str(synthetic), blob_path])
        if arguments.output is not None:
            separator_index = command.index("--")
            command[separator_index:separator_index] = ["--output", str(arguments.output.resolve())]
        subprocess.run(command, cwd=ROOT, check=True)
    finally:
        if temporary is not None:
            temporary.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
