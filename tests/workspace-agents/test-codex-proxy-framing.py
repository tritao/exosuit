#!/usr/bin/env python3
"""Exercise the actual raw proxy without starting or modifying a Codex daemon."""
import base64
import hashlib
import json
import os
from pathlib import Path
import queue
import struct
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / 'scripts' / 'run-codex-proxy.py'
LIMIT = 6 * 1024 * 1024

def server_frame(payload, opcode=1, final=True):
    n = len(payload)
    size = bytes([n]) if n < 126 else bytes([126]) + struct.pack('!H', n) if n <= 65535 else bytes([127]) + struct.pack('!Q', n)
    return bytes([(0x80 if final else 0) | opcode]) + size + payload

def peer(mode):
    header = bytearray()
    while not header.endswith(b'\r\n\r\n'):
        byte = sys.stdin.buffer.read(1)
        if not byte: return
        header.extend(byte)
        assert len(header) <= 8192
    key = next(line.split(b':', 1)[1].strip() for line in header.split(b'\r\n') if line.lower().startswith(b'sec-websocket-key:'))
    accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
    sys.stdout.buffer.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
    sys.stdout.buffer.flush()
    if mode == 'valid':
        payload = json.dumps({'method':'item/agentMessage/delta','params':{'delta':'é' * 140000}}, ensure_ascii=False).encode()
        split = payload.index('é'.encode()) + 1  # Split a multibyte character between WebSocket fragments.
        sys.stdout.buffer.write(server_frame(payload[:split],1,False) + server_frame(b'ping',9) + server_frame(payload[split:],0))
    elif mode == 'echo':
        def exact(n):
            data=bytearray()
            while len(data)<n:
                part=sys.stdin.buffer.read(n-len(data))
                if not part: raise EOFError()
                data.extend(part)
            return bytes(data)
        first,second=exact(2)
        assert first==0x81 and second&0x80
        n=second&127
        if n==126: n=struct.unpack('!H',exact(2))[0]
        elif n==127: n=struct.unpack('!Q',exact(8))[0]
        mask=exact(4);encoded=exact(n)
        decoded=bytes(byte ^ mask[index%4] for index,byte in enumerate(encoded))
        assert json.loads(decoded)['params']['text']=='é'*140000
        sys.stdout.buffer.write(server_frame(b'{"id":1,"result":"ok"}'))
    elif mode == 'nested':
        sys.stdout.buffer.write(server_frame(b'{',1,False) + server_frame(b'{}',1,True))
    elif mode == 'invalid-utf8':
        sys.stdout.buffer.write(server_frame(b'\xff'))
    elif mode == 'oversize':
        sys.stdout.buffer.write(b'\x81\x7f' + struct.pack('!Q',LIMIT+1))
    sys.stdout.buffer.flush()
    while sys.stdin.buffer.read(4096): pass

def test(mode):
    process = subprocess.Popen([sys.executable, str(BRIDGE), sys.executable, str(Path(__file__).resolve()), '--peer', mode],
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    lines = queue.Queue()
    threading.Thread(target=lambda: lines.put(process.stdout.readline()),daemon=True).start()
    if mode == 'echo':
        request=json.dumps({'id':1,'method':'test','params':{'text':'é'*140000}},ensure_ascii=False).encode()+b'\n'
        process.stdin.write(request);process.stdin.flush()
        assert json.loads(lines.get(timeout=20))['result']=='ok', 'large masked outbound frame changed'
        process.stdin.close();assert process.wait(timeout=10)==0, 'outbound bridge failed'
    elif mode == 'valid':
        line = lines.get(timeout=20)
        assert json.loads(line)['params']['delta'] == 'é' * 140000, 'fragmented UTF-8 changed'
        process.stdin.close()
        assert process.wait(timeout=10) == 0, 'valid bridge failed'
    else:
        code = process.wait(timeout=10)
        assert code != 0 and lines.get(timeout=2) == b'', 'invalid WebSocket message was accepted'
        error=process.stderr.read().decode('utf-8','replace')
        expected='Nested Codex WebSocket message' if mode=='nested' else 'utf-8' if mode=='invalid-utf8' else 'frame exceeds bound'
        assert expected in error, error
    for stream in (process.stdin,process.stdout,process.stderr):
        if stream and not stream.closed: stream.close()

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--peer': peer(sys.argv[2])
    else:
        for scenario in ('valid','echo','nested','invalid-utf8','oversize'): test(scenario)
        print('PASS: Codex raw WebSocket bridge large UTF-8 in both directions, fragmentation, ping and invalid-frame bounds')
