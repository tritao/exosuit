#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root_dir" <<'PY'
import os, pathlib, secrets, socket, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1])
haxeon=os.environ.get('HAXEON_BIN', str(pathlib.Path(os.environ.get('HAXEON_ROOT', str(root.parent/'haxeon')))/'scripts/haxeon'))
with tempfile.TemporaryDirectory(prefix="exosuit-rpc-") as temporary:
 directory=pathlib.Path(temporary); os.chmod(directory,0o700)
 token=directory/'credential'; token.write_text(secrets.token_hex(32)); os.chmod(token,0o600)
 with socket.socket() as probe:
  probe.bind(('127.0.0.1',0)); port=probe.getsockname()[1]
 compiler_mode=['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED') == '1' else []
 subprocess.run([haxeon,'run','--project',str(root/'tests/workspace-transport/haxeon.json'),*compiler_mode,'--',str(directory/'agent.sock'),str(port),str(token)],cwd=root,check=True,timeout=120)
PY
