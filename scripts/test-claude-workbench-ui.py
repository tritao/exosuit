#!/usr/bin/env python3
"""Compatibility entry for the Claude integrated-session desktop regression."""
from pathlib import Path
import subprocess
import sys
raise SystemExit(subprocess.call([sys.executable, str(Path(__file__).with_name('test-agent-session-creation-ui.py')),
                                 '--provider', 'claude', '--mode', 'integrated', *sys.argv[1:]]))
