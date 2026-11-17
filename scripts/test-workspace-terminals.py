#!/usr/bin/env python3
"""Two separate native editor clients share a shell its terminal host keeps while the service idles out and comes back."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'scripts'))
from test_driver import build_test, isolated_environment, launcher_path, process_runs, run_tree, service_log, start_service, stop_services, workspace_id

SERVICE=launcher_path(ROOT)
RUNNER=build_test('workspace-terminals')
# The service idles out IDLE seconds after its last client leaves; a client program takes a moment to start and connect
# (more on a loaded Windows machine), and a service that idles out in that gap is started again by the client itself.
IDLE='12' if os.name=='nt' else '3'
# The longest an idle shutdown may take once nothing keeps the service.
IDLE_EXIT=int(IDLE)+12
def host_pids(fixture):
    """The terminal hosts the run started that may still run (each terminal-hosts folder's host.json)."""
    pids=[]
    for path in fixture.glob('**/terminal-hosts/*/host.json'):
        try: pids.append(int(json.loads(path.read_text())['pid']))
        except (OSError,ValueError,KeyError): pass
    return pids
def end_hosts(fixture):
    """Kills every terminal host (and its program) the run started, so nothing outlives the test."""
    for pid in host_pids(fixture):
        if os.name=='nt': subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        else:
            try: os.kill(pid,9)
            except OSError: pass
with tempfile.TemporaryDirectory(prefix='extty-',ignore_cleanup_errors=True) as temporary:
    fixture=Path(temporary); root=fixture/'project'; root.mkdir(); state=fixture/'state'
    environment=dict(isolated_environment(state,SERVICE,'workspace-terminals'),SHELL='/bin/sh',EXOSUIT_SERVICE_IDLE_SECONDS=IDLE)
    log=service_log(state,workspace_id(root))
    def client(mode,timeout=40): run_tree([*RUNNER,mode,str(root),str(SERVICE)],environment,timeout=timeout)
    try:
        run_tree([*RUNNER,'contracts',str(root),str(SERVICE)],dict(environment,FAKE_AGENT_CLI=str(ROOT/'tests/workspace-terminals/fake-agent-cli.py')))
        # Flow control and history to views (TerminalFlowTests): a 10 s coloured flood among them.
        client('flow',timeout=150)
        deadline=time.monotonic()+10
        while [pid for pid in host_pids(fixture) if process_runs(pid)]:
            assert time.monotonic()<deadline,'the in-process tests left terminal hosts running: %r'%[(path,json.loads(path.read_text())['pid']) for path in fixture.glob('**/terminal-hosts/*/host.json') if process_runs(json.loads(path.read_text())['pid'])]
            time.sleep(.2)
        try:
            service=start_service(environment,state,root,timeout=90)
            for mode in ['catalog','create','attach']:
                client(mode)
                if mode=='create':
                    # A running shell does not keep the service: it idles out and the shell goes on in its host.
                    assert service.wait(IDLE_EXIT)==0,'The service did not idle out with a hosted shell'
                    hosts=[pid for pid in host_pids(fixture) if process_runs(pid)]
                    assert len(hosts)==1,f'the host of the shell did not outlive the service: {hosts}'
                    service=start_service(environment,state,root)
            assert service.wait(IDLE_EXIT)==0,'The service did not idle out after the shell exited'
            print('PASS: the shell outlives the idle service in its host; the next service takes it back for another client process',flush=True)
            service=start_service(environment,state,root)
            client('history-create')
            # Without exohost there is no polite stop on Windows: the service stops when it idles out.
            assert service.wait(IDLE_EXIT)==0,'The service did not idle out after history-create'
            service=start_service(environment,state,root)
            client('history-restore')
            assert service.wait(IDLE_EXIT)==0
        except Exception:
            # Why each service generation ended ("service stopped: ...").
            print(log,log.read_text()[-6000:] if log.exists() else 'no service log',file=sys.stderr)
            raise
    finally:
        stop_services(state)
        end_hosts(fixture)
