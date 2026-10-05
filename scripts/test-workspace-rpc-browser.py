#!/usr/bin/env python3
"""Real browser/native-daemon RPC acceptance; build the fixture first."""
import functools
import http.server
import json
import os
import pathlib
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
HAXEON = os.environ.get('HAXEON_BIN', str(pathlib.Path(os.environ.get('HAXEON_ROOT', str(ROOT / 'haxeon'))) / 'scripts/haxeon'))
sys.path.insert(0, str(ROOT.parent / 'nativekit/tools'))
from web_smoke import WebSocket, wait_for_page


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def stop(process):
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix='exosuit-browser-rpc-') as temporary:
    directory = pathlib.Path(temporary)
    os.chmod(directory, 0o700)
    token = secrets.token_hex(32)
    credential = directory / 'credential'
    credential.write_text(token)
    os.chmod(credential, 0o600)
    port, debug_port = free_port(), free_port()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(ROOT / 'tests/workspace-browser/build/site')))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/index.html'
    agent = browser = cdp = None
    identifier = 0
    log = open(directory / 'agent.log', 'w+')

    def start_agent():
        process = subprocess.Popen([HAXEON, 'run', '--project', str(ROOT / 'agent/haxeon.json'), '--', str(directory / 'agent.sock'), str(port), str(credential), secrets.token_hex(16), str(directory / 'catalog.sqlite')], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        return process

    def evaluate(expression):
        global identifier
        identifier += 1
        return cdp.evaluate(expression, identifier)

    def wait_state(predicate, label):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            if agent.poll() is not None:
                raise RuntimeError('Agent exited: ' + (directory / 'agent.log').read_text()[-2000:])
            state = evaluate('window.rpcTest')
            if state and state.get('error'):
                raise RuntimeError(state['error'])
            if state and predicate(state):
                print('PASS: ' + label, flush=True)
                return state
            time.sleep(0.05)
        log.flush()
        print((directory / 'agent.log').read_text()[-2000:])
        raise RuntimeError(f'Timed out: {label}: {state}; console: {cdp.errors}')

    try:
        agent = start_agent()
        chrome = shutil.which('google-chrome') or shutil.which('chromium')
        if chrome is None:
            raise RuntimeError('Chrome/Chromium is required')
        browser = subprocess.Popen([chrome, '--headless', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', f'--remote-debugging-port={debug_port}', '--remote-allow-origins=*', f'--user-data-dir={directory / "chrome"}', url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        page = wait_for_page(debug_port, url, 15)
        cdp = WebSocket(page['webSocketDebuggerUrl'])
        cdp.command('Runtime.enable', {}, 0)
        wait_state(lambda state: state['ready'], 'browser guest initialized')
        evaluate(f'window.startRpcTest({port}, {json.dumps(token)})')
        wait_state(lambda state: state['generations'] >= 1 and state['epochs'] == 1, 'browser authenticated workspace snapshot')
        evaluate('window.renameRpcTest()')
        wait_state(lambda state: state['renameDone'] and state['savedRevision'] == 2, 'browser mutation committed and observed')
        evaluate('window.suspendRpcTest()')
        wait_state(lambda state: state['generations'] >= 2 and state['epochs'] == 1, 'browser reconnect preserves epoch')
        stop(agent)
        time.sleep(0.2)
        agent = start_agent()
        wait_state(lambda state: state['generations'] >= 3 and state['epochs'] == 1 and state['savedRevision'] == 2, 'daemon restart preserves durable epoch and browser mutation')
        if cdp.errors:
            raise RuntimeError('\n'.join(cdp.errors))
    finally:
        if cdp is not None:
            cdp.close()
        stop(browser)
        stop(agent)
        server.shutdown()
        server.server_close()
        log.close()
