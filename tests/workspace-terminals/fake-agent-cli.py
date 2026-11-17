#!/usr/bin/env python3
"""A stand-in for the Claude Code, Codex and Pi terminal UIs that reports its conversation the way the real one does.

Started by the workspace service as a provider terminal: EXOSUIT_<PROVIDER>_BIN=<python>, EXOSUIT_<PROVIDER>_SCRIPT=<this>,
FAKE_AGENT_PROVIDER=claude|codex|pi, FAKE_AGENT_COUNT=<file counting starts>, FAKE_AGENT_INPUT=<file of received lines>.

It prints `TUI_<provider>:<argc>:<cwd>` and `ARGS:[<arguments>]`, then reads lines:
- `turn`: one turn is answered (Codex reports its conversation after a turn);
- `switch`: a new conversation begins and is reported (Claude's `/clear`, Codex's and Pi's `/new`);
- `exit`: the program ends;
- anything else is appended to FAKE_AGENT_INPUT and echoed as `RECEIVED:<line>`.
Each report prints `REPORTED:<id>` once the reporting program has finished.

Reports go through what the service passed: Claude's SessionStart hook from `--settings <file>` (run at startup too), the
Codex `-c notify=[...]` program with the turn's JSON as last argument, Pi's `--extension <file>` `session_start` handler
(run at startup too, through node).
"""
import json
import os
import subprocess
import sys
import uuid

PROVIDER = os.environ['FAKE_AGENT_PROVIDER']
ARGS = sys.argv[1:]


def after(flag):
    return ARGS[ARGS.index(flag) + 1] if flag in ARGS and ARGS.index(flag) + 1 < len(ARGS) else None


def report(conversation):
    if PROVIDER == 'claude':
        settings = after('--settings')
        if settings is None:
            return
        with open(settings, encoding='utf-8') as handle:
            hook = json.load(handle)['hooks']['SessionStart'][0]['hooks'][0]
        shell = ['powershell', '-NoProfile', '-Command'] if hook.get('shell') == 'powershell' else ['sh', '-c']
        subprocess.run(shell + [hook['command']], input=json.dumps({'session_id': conversation, 'hook_event_name': 'SessionStart',
                       'cwd': os.getcwd()}), text=True, check=True)
    elif PROVIDER == 'codex':
        setting = next((ARGS[i + 1] for i, a in enumerate(ARGS[:-1]) if a == '-c' and ARGS[i + 1].startswith('notify=')), None)
        if setting is None:
            return
        program = [part.strip("'") for part in setting[len('notify=['):-1].split(',')]
        subprocess.run(program + [json.dumps({'type': 'agent-turn-complete', 'thread-id': conversation, 'turn-id': '1',
                       'cwd': os.getcwd(), 'input-messages': ['say "hi"'], 'last-assistant-message': 'hi'})], check=True)
    elif PROVIDER == 'pi':
        extension = after('--extension')
        if extension is None:
            return
        harness = ('import { pathToFileURL } from "node:url";'
                   'const m = await import(pathToFileURL(process.argv[1]).href);'
                   'm.default({ on: (event, handler) => { if (event === "session_start")'
                   ' handler({ type: "session_start", reason: "startup" }, { sessionManager: { getSessionId: () => process.argv[2] } }); } });')
        subprocess.run(['node', '--input-type=module', '-e', harness, extension, conversation], check=True)
    print('REPORTED:' + conversation, flush=True)


count = os.environ.get('FAKE_AGENT_COUNT')
if count:
    previous = int(open(count).read()) if os.path.exists(count) else 0
    with open(count, 'w') as handle:
        handle.write(str(previous + 1))
print('TUI_%s:%d:%s' % (PROVIDER, len(sys.argv), os.getcwd()), flush=True)
print('ARGS:[' + ' '.join(ARGS) + ']', flush=True)
if PROVIDER == 'codex':
    current = after('resume')
else:
    current = after('--session-id') or after('--resume')
if PROVIDER != 'codex' and current:
    report(current)
for line in sys.stdin:
    line = line.strip()
    if line == 'exit':
        break
    if line == 'turn':
        if current is None:
            current = str(uuid.uuid4())
        if PROVIDER == 'codex':
            report(current)
    elif line == 'switch':
        current = str(uuid.uuid4())
        report(current)
    else:
        if os.environ.get('FAKE_AGENT_INPUT'):
            with open(os.environ['FAKE_AGENT_INPUT'], 'a', encoding='utf-8') as handle:
                handle.write(line + '\n')
        print('RECEIVED:' + line, flush=True)
