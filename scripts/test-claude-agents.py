#!/usr/bin/env python3
"""Build and run native Claude adapter tests with a deterministic CLI protocol peer (tests/claude-agents/fake-claude.py).

--real runs the acceptance test against the real `claude` (EXOSUIT_CLAUDE_BIN or PATH) instead, which spends quota; it
needs CLAUDE_CONFIG_DIR to name a signed-in configuration folder of its own (never ~/.claude). Without --real the test
gets an empty one."""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

from test_driver import HL, MODE, ROOT, agent_homes, haxeon, run_tree, signed_in_home, with_libraries

real = '--real' in sys.argv[1:]
if real:
    signed_in_home('CLAUDE_CONFIG_DIR')
project = ROOT / ('tests/claude-agents/real.haxeon.json' if real else 'tests/claude-agents/haxeon.json')
haxeon(['build', '--project', str(project), *MODE])
output = project.parent / ('build-real/host' if real else 'build/host')
# The test starts the fake with EXOSUIT_TEST_PYTHON, and reads graphical/assets relative to the checkout.
environment = dict(with_libraries(dict(os.environ), output / 'native'), EXOSUIT_TEST_PYTHON=sys.executable)


def text_of(content) -> str:
    """A prompt's text: the content itself, or the text blocks of a prompt with images."""
    if isinstance(content, list):
        return ''.join(part.get('text', '') for part in content if part.get('type') == 'text')
    return content


with tempfile.TemporaryDirectory(prefix='exosuit-claude-', ignore_cleanup_errors=True) as temporary:
    peer = (os.environ.get('EXOSUIT_CLAUDE_BIN') or shutil.which('claude')) if real else str(project.parent / 'fake-claude.py')
    if not real:  # the provider reads transcripts from the configuration folder
        environment.update(agent_homes(Path(temporary) / 'homes'))
    run_tree([str(HL), str(output / 'main.hl'), temporary, peer], environment, timeout=200, cwd=ROOT)
    if real:
        sys.exit(0)
    wire = [json.loads(line) for line in (Path(temporary) / 'wire.jsonl').read_text().splitlines()]
    prompts = [text_of(v['message']['content']) for v in wire if v['type'] == 'user']
    # The prompt the fake dies on is sent once; the one after its uncertain delivery is refused, not sent.
    assert prompts.count('image-crash') == 1 and 'must-not-send' not in prompts, prompts
    assert prompts.count('hello') == 1, prompts
    print('PASS: no duplicate or automatically resent prompt side effects')
