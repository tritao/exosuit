#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root_dir" <<'PY'
import json, os, pathlib, secrets, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request
root=pathlib.Path(sys.argv[1])
haxeon=os.environ.get('HAXEON_BIN', str(pathlib.Path(os.environ.get('HAXEON_ROOT', str(root/'haxeon')))/'scripts/haxeon'))
with tempfile.TemporaryDirectory(prefix="exosuit-rpc-") as temporary:
 directory=pathlib.Path(temporary); os.chmod(directory,0o700)
 token=directory/'credential'; token.write_text(secrets.token_hex(32)); os.chmod(token,0o600)
 def free_port():
  with socket.socket() as probe:
   probe.bind(('127.0.0.1',0)); return probe.getsockname()[1]
 agent_port=free_port(); relay_port=free_port()
 machine_id=secrets.token_hex(16); machine_token=secrets.token_hex(32)
 device_id=secrets.token_hex(16); device_token=secrets.token_hex(32)
 relay_config=directory/'relay-config.json'
 relay_config.write_text(json.dumps({
  'origin':f'http://127.0.0.1:{relay_port}',
  'machineId':machine_id,
  'machineToken':machine_token,
  'deviceId':device_id,
  'deviceToken':device_token,
 }))
 os.chmod(relay_config,0o600)
 worker_log=(directory/'worker.log').open('w+')
 worker=subprocess.Popen([
  str(root/'relay/worker/node_modules/.bin/wrangler'), 'dev', '--local',
  '--ip', '127.0.0.1', '--port', str(relay_port),
  '--persist-to', str(directory/'wrangler-state'),
  '--var', 'ALLOWED_ORIGINS:http://localhost:5173',
 ],cwd=root/'relay/worker',stdout=worker_log,stderr=subprocess.STDOUT)
 origin=f'http://127.0.0.1:{relay_port}'
 try:
  deadline=time.monotonic()+60
  while True:
   if worker.poll() is not None:
    worker_log.flush(); raise RuntimeError('local relay Worker exited:\n'+worker_log.read())
   try:
    request=urllib.request.Request(
     f'{origin}/v1/machines/{machine_id}/register',
     data=b'',headers={'Authorization':'Bearer '+machine_token},method='POST')
    with urllib.request.urlopen(request,timeout=1) as response:
     if response.status != 201: raise RuntimeError(f'machine enrollment returned {response.status}')
    request=urllib.request.Request(
     f'{origin}/v1/machines/{machine_id}/devices/{device_id}',
     data=json.dumps({'token':device_token}).encode(),
     headers={'Authorization':'Bearer '+machine_token,'Content-Type':'application/json'},method='PUT')
    with urllib.request.urlopen(request,timeout=1) as response:
     if response.status != 201: raise RuntimeError(f'device enrollment returned {response.status}')
    break
   except (urllib.error.URLError, TimeoutError, ConnectionError):
    if time.monotonic() >= deadline:
     worker_log.flush(); raise RuntimeError('local relay Worker did not become ready:\n'+worker_log.read())
    time.sleep(0.2)
  compiler_mode=['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED') == '1' else []
  completed=subprocess.run([haxeon,'run','--project',str(root/'tests/workspace-transport/haxeon.json'),*compiler_mode,'--',str(directory/'agent.sock'),str(agent_port),str(token),str(relay_config)],cwd=root,timeout=120)
  if completed.returncode != 0:
   worker_log.flush(); print('Local relay Worker log:\n'+worker_log.read(),file=sys.stderr)
   raise RuntimeError(f'workspace transport test exited with status {completed.returncode}')
 finally:
  worker.terminate()
  try: worker.wait(timeout=5)
  except subprocess.TimeoutExpired: worker.kill(); worker.wait()
  worker_log.close()
PY
