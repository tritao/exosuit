#!/usr/bin/env python3
"""Opt-in real inference acceptance; owns only one isolated test thread.

Never stops/restarts the shared daemon or changes global Codex settings.
The test thread remains in Codex history for inspection.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
LIMIT = 262144


class Peer:
    def __init__(self):
        self.process = subprocess.Popen(
            ['python3', str(ROOT / 'scripts/run-codex-proxy.py'), 'codex'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        os.set_blocking(self.process.stdout.fileno(), False)
        self.buffer = bytearray()
        self.sequence = 0

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b'\n')
        self.process.stdin.flush()

    def receive(self, deadline):
        while time.monotonic() < deadline:
            at = self.buffer.find(b'\n')
            if at >= 0:
                if at > LIMIT:
                    raise RuntimeError('Oversized shared-server message')
                line = bytes(self.buffer[:at])
                del self.buffer[:at + 1]
                return json.loads(line)
            if len(self.buffer) > LIMIT:
                raise RuntimeError('Oversized shared-server message')
            if not self.selector.select(min(.5, deadline - time.monotonic())):
                continue
            data = os.read(self.process.stdout.fileno(), 65536)
            if not data:
                raise RuntimeError('Shared-server proxy closed')
            self.buffer.extend(data)
        raise TimeoutError('Shared-server response timed out')

    def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.send({'id': request_id, 'method': method, 'params': params})
        deadline = time.monotonic() + 20
        while True:
            value = self.receive(deadline)
            if value.get('method'):
                # No approval or user-input replies are sent by this fixture.
                if 'id' in value:
                    raise RuntimeError('Unexpected server request in no-tool fixture')
                continue
            if value.get('id') == request_id:
                if 'error' in value:
                    error = value['error']
                    raise RuntimeError('Shared server rejected ' + method + ': ' + str(error.get('message', 'Unknown error'))[:300])
                return value['result']

    def initialize(self):
        result = self.request('initialize', {
            'clientInfo': {'name': 'exosuit', 'title': 'Exosuit lifecycle acceptance', 'version': '1'},
            'capabilities': {'experimentalApi': False}})
        if not isinstance(result.get('userAgent'), str) or not result['userAgent']:
            raise RuntimeError('Shared server omitted its user agent')
        self.send({'method': 'initialized'})

    def close(self):
        self.selector.close()
        if self.process.poll() is None:
            self.process.terminate()
        self.process.wait(timeout=10)


def latest(peer, thread):
    page = peer.request('thread/turns/list', {
        'threadId': thread, 'limit': 1, 'sortDirection': 'desc', 'itemsView': 'summary'})
    if len(page['data']) != 1:
        raise RuntimeError('Expected exactly one test turn')
    return page['data'][0]


def run():
    peers = []
    thread = turn = None
    finished = False
    def connect():
        peer = Peer()
        peers.append(peer)
        peer.initialize()
        return peer
    try:
        with tempfile.TemporaryDirectory(prefix='exosuit-codex-lifecycle-') as root:
            first = connect()
            auth = first.request('account/read', {'refreshToken': False})
            if auth.get('requiresOpenaiAuth') and auth.get('account') is None:
                raise RuntimeError('Codex authentication is unavailable')
            created = first.request('thread/start', {
                'cwd': root, 'sandbox': 'read-only', 'approvalPolicy': 'never',
                'developerInstructions': 'This is a transport lifecycle test. Do not use tools, read files, access the network or spawn agents. Only produce the requested text.'})
            thread = created['thread']['id']
            print('Created isolated read-only test thread: ' + thread, flush=True)
            if created['sandbox'].get('type') != 'readOnly' or created['approvalPolicy'] != 'never':
                raise RuntimeError('Shared server did not retain the requested test policy')
            second = connect()
            # Start one turn only. Ambiguous errors never cause another prompt.
            started = first.request('turn/start', {'threadId': thread, 'input': [{
                'type': 'text', 'text': 'Produce exactly 80 numbered lines. Each line should contain only its number and the words lifecycle test. Do not use tools.',
                'text_elements': []}]})
            turn = started['turn']['id']
            second.request('thread/resume', {'threadId': thread, 'excludeTurns': True})
            before = latest(second, thread)
            if before['id'] != turn or before['status'] != 'inProgress':
                raise RuntimeError('Turn ended before disconnect; lifecycle result is inconclusive')
            first.close()
            peers.remove(first)
            sibling = latest(second, thread)
            if sibling['id'] != turn or sibling['status'] != 'inProgress':
                raise RuntimeError('Turn ended before final disconnect; lifecycle result is inconclusive')
            second.close()
            peers.remove(second)
            print('Both fixture clients disconnected while the same turn was active.', flush=True)
            recovered = connect()
            metadata = recovered.request('thread/read', {'threadId': thread, 'includeTurns': False})
            if metadata['thread']['cwd'] != root:
                raise RuntimeError('Recovered thread changed directory')
            recovered.request('thread/resume', {'threadId': thread, 'excludeTurns': True})
            deadline = time.monotonic() + 120
            while True:
                current = latest(recovered, thread)
                if current['id'] != turn:
                    raise RuntimeError('Recovered a different turn')
                if current['status'] == 'completed':
                    finished = True
                    break
                if current['status'] != 'inProgress':
                    raise RuntimeError('Test turn did not survive disconnect: ' + current['status'])
                if time.monotonic() > deadline:
                    raise TimeoutError('Test turn did not finish in 120 seconds')
                time.sleep(.5)
            history = recovered.request('thread/items/list', {
                'threadId': thread, 'turnId': turn, 'limit': 8, 'sortDirection': 'desc'})
            if history.get('nextCursor') is not None:
                raise RuntimeError('No-tool fixture history exceeds its eight-item bound')
            items = [entry['item'] for entry in history['data']]
            if not any(item.get('type') == 'agentMessage' and 'lifecycle test' in item.get('text', '') for item in items):
                raise RuntimeError('Completed assistant response missing from persisted history')
            if any(item.get('type') in ('commandExecution', 'fileChange', 'mcpToolCall', 'collabAgentToolCall') for item in items):
                raise RuntimeError('Unexpected tool activity in no-tool fixture')
            if any(Path(root).iterdir()):
                raise RuntimeError('Read-only fixture directory was changed')
            print('PASS: real inference, two-client attachment, sibling disconnect, all-client disconnect, same-turn recovery and persisted assistant history', flush=True)
    finally:
        # Interrupt only the fixture turn on failure, never unrelated work.
        if thread and turn and not finished:
            try:
                cleanup = connect()
                cleanup.request('turn/interrupt', {'threadId': thread, 'turnId': turn})
            except Exception:
                print('Test turn cleanup was unconfirmed; inspect the printed fixture thread.', flush=True)
        for peer in peers:
            peer.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', help='Opt in to one real inference turn using existing Codex authentication')
    args = parser.parse_args()
    if not args.run:
        parser.error('--run is required; this test creates a persistent thread and uses model inference')
    run()
