#!/usr/bin/env python3
"""Install the pinned, metadata-only Claude SDK dependency during build, never daemon runtime."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys


def prepare(root: Path, required: bool = False) -> bool:
    directory = root / 'agent' / 'naming'
    lock = directory / 'package-lock.json'
    digest = hashlib.sha256(lock.read_bytes()).hexdigest()
    modules = directory / 'node_modules'
    stamp = modules / '.exosuit-naming-lock'
    sdk = modules / '@anthropic-ai' / 'claude-agent-sdk' / 'sdk.mjs'
    if sdk.is_file() and stamp.is_file() and stamp.read_text() == digest:
        return True
    npm = shutil.which('npm')
    if not npm:
        if required:
            raise RuntimeError('npm is required to prepare the pinned Claude session metadata adapter')
        print('Claude native naming is unavailable until its metadata SDK is prepared with npm.', file=sys.stderr)
        return False
    try:
        subprocess.run([npm, 'ci', '--omit=optional', '--omit=peer', '--ignore-scripts', '--no-audit', '--no-fund'], cwd=directory, check=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        if required:
            raise
        print('Claude metadata SDK preparation failed; native naming is unavailable. Workbench labels remain supported.', file=sys.stderr)
        return False
    stamp.write_text(digest)
    return True


if __name__ == '__main__':
    prepare(Path(__file__).resolve().parent.parent, required=True)
