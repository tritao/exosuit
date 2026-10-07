#!/usr/bin/env python3
"""Exercise replacement builds with isolated managers and two real editor clients."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
MANAGER = ROOT / 'scripts/run-agent.py'
HAXEON = os.environ.get('HAXEON_BIN', str(Path(os.environ.get('HAXEON_ROOT', str(ROOT / 'haxeon'))) / 'scripts/haxeon'))
spec = importlib.util.spec_from_file_location('workspace_manager_updates', MANAGER)
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class UpdateTests(unittest.TestCase):
    def test_identity_tracks_service_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir(); (root / 'src').mkdir(); (root / 'graphical').mkdir()
            launcher = root / 'scripts/run-agent.py'; launcher.write_text('manager')
            source = root / 'src/Service.hx'; source.write_text('first')
            with patch.object(manager, 'REPO', root), patch.object(manager, '__file__', str(launcher)):
                first = manager.agent_build_id()
                (root / 'graphical/Panel.hx').write_text('UI changes')
                self.assertEqual(first, manager.agent_build_id())
                source.write_text('second')
                self.assertNotEqual(first, manager.agent_build_id())
                native = root / 'haxeon/vendor/nativekit/src/transport'
                native.mkdir(parents=True)
                transport = native / 'transport.cpp'; transport.write_text('first native build')
                native_build = manager.agent_build_id()
                transport.write_text('updated native build')
                self.assertNotEqual(native_build, manager.agent_build_id())

    def test_failed_build_does_not_stop_manager(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(manager.subprocess, 'run') as run:
            run.return_value.returncode = 1
            with self.assertRaisesRegex(RuntimeError, 'existing sessions are unchanged'):
                manager.prepare_update(Path(temporary), ROOT)
            self.assertEqual(run.call_count, 1)

    def test_generation_guard_precedes_signal(self):
        with patch.object(manager, 'read_discovery', return_value={'generation': 'new'}), patch.object(manager.os, 'pidfd_open') as opened:
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                manager.stop_legacy_manager(ROOT, ROOT, 'old')
            opened.assert_not_called()


def integration():
    for mode in ['update-idle', 'update-busy', 'update-now', 'update-legacy']:
        with tempfile.TemporaryDirectory(prefix='exa-update-') as temporary:
            base = Path(temporary)
            project = base / 'project'; project.mkdir()
            revision = base / 'revision'; revision.write_text('a' * 64)
            wrapper = base / 'run-agent.py'
            wrapper.write_text(f'''import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("real_manager", {str(MANAGER)!r})
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.__file__ = {str(wrapper)!r}
m.agent_build_id = lambda: Path({str(revision)!r}).read_text().strip()
original_popen = m.subprocess.Popen
def popen(command, *args, **kwargs):
    if {mode!r} == "update-legacy" and m.agent_build_id() == "a" * 64 and any("agent/build/host/main.hl" in str(arg) for arg in command):
        kwargs["env"] = dict(m.os.environ, EXOSUIT_AGENT_MANAGED_UPDATES="0")
    return original_popen(command, *args, **kwargs)
m.subprocess.Popen = popen
sys.exit(m.main())
''')
            state = base / 'state'
            environment = dict(os.environ, XDG_STATE_HOME=str(state))
            try:
                subprocess.run([HAXEON, 'run', '--project', str(ROOT / 'tests/workspace-attachment/haxeon.json'), '--',
                                mode, str(project), str(wrapper), str(revision)], env=environment, check=True, timeout=150)
            finally:
                for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
                    try:
                        os.kill(json.loads(endpoint.read_text())['managerPid'], signal.SIGTERM)
                    except (FileNotFoundError, ProcessLookupError):
                        pass
                deadline = time.monotonic() + 10
                while list(state.glob('exosuit/workspaces/*/endpoint.json')) and time.monotonic() < deadline:
                    time.sleep(.05)


if __name__ == '__main__':
    result = unittest.main(exit=False).result
    if not result.wasSuccessful():
        raise SystemExit(1)
    integration()
