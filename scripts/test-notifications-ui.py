#!/usr/bin/env python3
"""Xvfb acceptance of the real notification controls; crash-report output is an isolated fixture."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / 'tests/notifications-ui-smoke/haxeon.json'
subprocess.run([str(ROOT / 'haxeon/scripts/haxeon'), 'build', '--project', str(PROJECT)], check=True)
with tempfile.TemporaryDirectory(prefix='exosuit-notifications-') as temporary:
    fixture = Path(temporary)
    executable = fixture / 'coredumpctl'
    executable.write_text('#!/bin/sh\n[ "$1" = info ] && [ "$2" = 1234 ] && [ "$3" = --no-pager ] || exit 1\nprintf "Fixture retained crash report\\n"\n')
    executable.chmod(0o755)
    native = PROJECT.parent / 'build/host/native'
    libraries = [ROOT / 'haxeon/out', ROOT / 'haxeon/.tools/hashlink', *sorted(path for path in native.iterdir() if path.is_dir())]
    environment = dict(os.environ, PATH=str(fixture) + os.pathsep + os.environ['PATH'],
                       LD_LIBRARY_PATH=os.pathsep.join(map(str, libraries)),
                       XDG_STATE_HOME=str(fixture / 'state'), PRAGTICAL_PORTABLE=str(fixture / 'settings'))
    subprocess.run([str(ROOT / 'haxeon/.tools/hashlink/hl'), str(PROJECT.parent / 'build/host/main.hl'), str(fixture / 'capture')],
                   cwd=ROOT, env=environment, check=True, timeout=30)
