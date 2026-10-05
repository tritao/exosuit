#!/usr/bin/env python3
"""Bounded JSONL <-> WebSocket bridge over Codex's raw stdio socket proxy.

Owns only the proxy child. No daemon lifetime or inference policy is changed.
"""
import base64,hashlib,json,os,selectors,struct,subprocess,sys,time,signal

LIMIT=262144
QUEUE=1048576
GUID=b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

def frame(payload,opcode=1):
    mask=os.urandom(4)
    n=len(payload)
    head=bytes([0x80|opcode,0x80|n]) if n<126 else bytes([0x80|opcode,0xfe if n<=65535 else 0xff])+struct.pack('!H' if n<=65535 else '!Q',n)
    return head+mask+bytes(byte^mask[i%4] for i,byte in enumerate(payload))

def main():
    if len(sys.argv)!=2: raise ValueError('Expected Codex executable')
    child=subprocess.Popen([sys.argv[1],'app-server','proxy'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
    selector=selectors.DefaultSelector()
    key=base64.b64encode(os.urandom(16))
    expected=base64.b64encode(hashlib.sha1(key+GUID).digest())
    network=bytearray(b'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+key+b'\r\n\r\n')
    output=bytearray();incoming=bytearray();lines=bytearray();fragment=bytearray()
    handshake=False;fragmenting=False;closing=False
    deadline=time.monotonic()+10
    watched={}
    handles={'input':sys.stdin.buffer,'proxy':child.stdout,'errors':child.stderr,'send':child.stdin,'output':sys.stdout.buffer}
    for handle in handles.values(): os.set_blocking(handle.fileno(),False)
    def watch(name,events):
        handle=handles[name]
        if events:
            if name in watched: selector.modify(handle,events,name)
            else: selector.register(handle,events,name);watched[name]=True
        elif name in watched: selector.unregister(handle);watched.pop(name)
    def append(queue,data):
        if len(data)>QUEUE-len(queue): raise ValueError('Codex bridge queue exceeds bound')
        queue.extend(data)
    try:
        while True:
            if closing and not output: return
            if not handshake and time.monotonic()>deadline: raise TimeoutError('Codex WebSocket handshake timed out')
            watch('input',0 if closing else selectors.EVENT_READ)
            watch('proxy',0 if closing else selectors.EVENT_READ)
            if 'errors' in handles: watch('errors',selectors.EVENT_READ)
            watch('send',selectors.EVENT_WRITE if network else 0)
            watch('output',selectors.EVENT_WRITE if output else 0)
            for selected,event in selector.select(1):
                name=selected.data
                if name in ('send','output'):
                    queue=network if name=='send' else output
                    try: n=os.write(selected.fileobj.fileno(),memoryview(queue)[:65536])
                    except BlockingIOError: continue
                    del queue[:n]
                    continue
                try: data=os.read(selected.fileobj.fileno(),65536)
                except BlockingIOError: continue
                if name=='errors':
                    if not data: watch('errors',0);handles.pop('errors')
                    continue
                if not data:
                    if name=='input': return
                    closing=True;continue
                append(lines if name=='input' else incoming,data)
            if not handshake:
                at=incoming.find(b'\r\n\r\n')
                if at<0:
                    if len(incoming)>8192: raise ValueError('Codex upgrade header exceeds bound')
                    continue
                if at>8192: raise ValueError("Codex upgrade header exceeds bound")
                header=bytes(incoming[:at]);del incoming[:at+4]
                fields=header.split(b'\r\n')
                if not fields[0].startswith(b'HTTP/1.1 101 '): raise ValueError('Codex WebSocket upgrade refused')
                headers={k.strip().lower():v.strip().lower() for line in fields[1:] for k,v in [line.split(b':',1)]}
                accept=next((line.split(b':',1)[1].strip() for line in fields[1:] if line.lower().startswith(b'sec-websocket-accept:')),None)
                if accept!=expected or headers.get(b'upgrade')!=b'websocket' or b'upgrade' not in headers.get(b'connection',b''):
                    raise ValueError('Invalid Codex WebSocket upgrade')
                handshake=True
            for _ in range(32):
                at=lines.find(b'\n')
                if at<0: break
                if at>LIMIT: raise ValueError('Codex JSONL frame exceeds bound')
                line=bytes(lines[:at]);del lines[:at+1]
                if not line: continue
                line.decode('utf-8')  # Text frames must carry valid UTF-8.
                append(network,frame(line))
            if len(lines)>LIMIT and b'\n' not in lines: raise ValueError('Codex JSONL frame exceeds bound')
            for _ in range(32):
                if len(incoming)<2: break
                a,b=incoming[:2];fin=bool(a&0x80);opcode=a&15;n=b&127;offset=2
                if a&0x70 or b&0x80: raise ValueError('Unsupported Codex WebSocket frame')
                if n==126:
                    if len(incoming)<4: break
                    n=struct.unpack('!H',incoming[2:4])[0];offset=4
                elif n==127:
                    if len(incoming)<10: break
                    n=struct.unpack('!Q',incoming[2:10])[0];offset=10
                if n>LIMIT or (opcode>=8 and (not fin or n>125)): raise ValueError('Codex WebSocket frame exceeds bound')
                if len(incoming)<offset+n: break
                payload=bytes(incoming[offset:offset+n]);del incoming[:offset+n]
                if opcode==8: closing=True;break
                if opcode==9: append(network,frame(payload,10));continue
                if opcode==10: continue
                if opcode==1:
                    if fragmenting: raise ValueError('Nested Codex WebSocket message')
                    fragment.clear();fragmenting=not fin
                elif opcode!=0 or not fragmenting: raise ValueError('Expected Codex WebSocket text')
                if len(payload)>LIMIT-len(fragment): raise ValueError('Codex WebSocket message exceeds bound')
                fragment.extend(payload)
                if fin:
                    fragmenting=False
                    fragment.decode('utf-8')
                    payload=bytes(fragment)
                    if b'\n' in payload: payload=json.dumps(json.loads(payload),separators=(',',':')).encode()
                    append(output,payload+b'\n');fragment.clear()
    finally:
        selector.close()
        # Ending this transport closes the raw proxy, never the shared daemon.
        if child.poll() is None: child.terminate()
        child.wait(timeout=5)

if __name__=='__main__':
    def stop(*_): raise SystemExit(0)
    signal.signal(signal.SIGTERM,stop)
    try: main()
    except Exception as error:
        print('Codex proxy bridge: '+str(error),file=sys.stderr)
        sys.exit(1)
