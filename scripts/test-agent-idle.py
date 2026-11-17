#!/usr/bin/env python3
"""A workspace service's idle stop: a connection that never speaks does not keep it up, a linked client does, and the
catalog database outlives it."""
import contextlib
from pathlib import Path
import socket
import tempfile
import time

from test_driver import (ROOT, WINDOWS, build_test, launcher_path, isolated_environment, process_runs, run_tree, service_log,
                         start_service, stop_services, workspace_id)

LAUNCHER = launcher_path(ROOT)
RUNNER = build_test('workspace-attachment')


@contextlib.contextmanager
def raw_connection(address):
    """A connection to the service's endpoint that never speaks: a named pipe on Windows, else a Unix socket."""
    if WINDOWS:
        with open(address, 'r+b', buffering=0) as pipe:
            yield pipe
    else:
        with socket.socket(socket.AF_UNIX) as raw:
            raw.connect(address)
            yield raw


with tempfile.TemporaryDirectory(prefix='exidle-', ignore_cleanup_errors=True) as temporary:
    fixture = Path(temporary)
    root = fixture / 'project'; root.mkdir()
    state = fixture / 'state'
    environment = isolated_environment(state, LAUNCHER, 'workspace-attachment')
    try:
        first = start_service(environment, state, root, idle_seconds=2)
        with raw_connection(first.endpoint):
            assert first.wait(timeout=15) == 0, 'the idle stop reported a failure'
        log = service_log(state, workspace_id(root)).read_text()
        assert 'service stopped: idle' in log, log[-2000:]
        database = service_log(state, workspace_id(root)).parent / 'catalog.sqlite'
        assert database.exists(), 'the idle stop discarded the catalog database'
        # A new service reopens the same database; a linked client keeps it past its idle time, and it stops after.
        environment['EXOSUIT_SERVICE_IDLE_SECONDS'] = '4'
        run_tree([*RUNNER, 'hold', str(root), str(LAUNCHER)], environment, timeout=150)
        log = service_log(state, workspace_id(root)).read_text()
        assert log.count('service starting: generation ') == 2, log[-2000:]
        second = [line for line in log.splitlines() if 'service starting: generation ' in line][-1]
        assert second.split('generation ')[1].split(',')[0] != first.generation
        pid = int(second.rsplit(', pid ', 1)[1])
        deadline = time.monotonic() + 20
        while process_runs(pid) and time.monotonic() < deadline:
            time.sleep(0.1)
        assert not process_runs(pid), 'the service outlived its idle time after its last client left'
        print('PASS: a silent connection does not keep a service up, a linked client does, and the catalog database stays', flush=True)
    finally:
        stop_services(state)
