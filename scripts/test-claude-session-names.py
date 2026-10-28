#!/usr/bin/env python3
"""Native SDK metadata acceptance on disposable transcripts; no model or Claude process."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
from prepare_agent_naming import prepare
os.environ.setdefault("EXOSUIT_SUIT_AUTOSTART", "0")  # tests must not start the user's suit daemon

ROOT = Path(__file__).resolve().parent.parent
prepare(ROOT, required=True)
with tempfile.TemporaryDirectory(prefix='exosuit-native-claude-names-') as temporary:
    fixture = Path(temporary)
    workspace = fixture / 'workspace'
    workspace.mkdir()
    config = fixture / 'claude'
    session = str(uuid.uuid4())
    project = config / 'projects' / ''.join(c if c.isascii() and c.isalnum() else '-' for c in str(workspace))
    project.mkdir(parents=True)
    transcript = project / (session + '.jsonl')
    original = (json.dumps({'type': 'user', 'sessionId': session, 'uuid': str(uuid.uuid4()), 'parentUuid': None,
                           'cwd': str(workspace), 'isSidechain': False, 'timestamp': '2026-01-01T00:00:00Z',
                           'message': {'role': 'user', 'content': 'Fixture, never delivered to a model'}}) + '\n').encode()
    transcript.write_bytes(original)
    # Exercise the same relocated dependency layout that ships in a release.
    adapter = fixture / 'tools' / 'claude-naming'
    shutil.copytree(ROOT / 'agent/naming', adapter, ignore=shutil.ignore_patterns('package-lock.json', '.exosuit-naming-lock'))
    env = dict(os.environ, CLAUDE_CONFIG_DIR=str(config), ANTHROPIC_API_KEY='', ANTHROPIC_AUTH_TOKEN='')
    helper = subprocess.Popen(['node', str(adapter / 'claude-session-names.mjs'), str(workspace)],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    serial = 0
    def request(method, **params):
        global serial
        serial += 1
        helper.stdin.write(json.dumps({'id': serial, 'method': method, 'params': {'sessionId': session, 'cwd': str(workspace), **params}}) + '\n')
        helper.stdin.flush()
        response = json.loads(helper.stdout.readline())
        assert response['id'] == serial, response
        return response
    def sdk(expression):
        source = "import {getSessionInfo,listSessions,renameSession} from './node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';\n" + expression
        return subprocess.check_output(['node', '--input-type=module', '-e', source], cwd=adapter, env=env, text=True)
    try:
        assert request('session/name/read')['result']['name'] is None
        assert request('session/name/set', expected=None, name='Design α')['result']['name'] == 'Design α'
        assert transcript.read_bytes().startswith(original), 'SDK rewrote the transcript'
        sessions = json.loads(sdk('console.log(JSON.stringify(await listSessions({dir:' + json.dumps(str(workspace)) + '})));'))
        assert next(s for s in sessions if s['sessionId'] == session)['customTitle'] == 'Design α', sessions
        before = transcript.read_bytes()
        assert request('session/name/set', expected=None, name='Stale')['error']['message'].startswith('conflict:')
        assert transcript.read_bytes() == before
        sdk('await renameSession(' + json.dumps(session) + ',"Renamed outside Exosuit",{dir:' + json.dumps(str(workspace)) + '});')
        assert request('session/name/read')['result']['name'] == 'Renamed outside Exosuit'
        before = transcript.read_bytes()
        assert request('session/name/set', expected='Design α', name='Would overwrite')['error']['message'].startswith('conflict:')
        assert transcript.read_bytes() == before
        assert request('session/name/read', cwd=str(fixture))['error']['message'].startswith('invalid_scope:')
        assert request('session/name/read', sessionId='../escape')['error']['message'].startswith('invalid_request:')
        missing = str(uuid.uuid4())
        assert request('session/name/set', sessionId=missing, expected=None, name='Must not create')['error']['message'].startswith('unknown_session:')
        assert not (project / (missing + '.jsonl')).exists()
        assert request('session/name/set', expected='Renamed outside Exosuit', name='bad\nname')['error']['message'].startswith('invalid_name:')
        print('PASS: pinned Claude SDK native rename/list visibility, external edits, conflicts, append-only history, scope validation and relocated runtime without agent/model execution')
    finally:
        helper.stdin.close()
        helper.wait(timeout=10)
        assert helper.returncode == 0, helper.stderr.read()
