#!/usr/bin/env python3
"""Runs the NativeKit transport check against a local Anthropic-compatible SSE server."""
import json, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / "haxeon"
PROJECT = Path(__file__).resolve().parent / "haxeon.json"
requests = []

def event(name, data):
    return f"event: {name}\ndata: {json.dumps(data)}\n\n".encode()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        requests.append((dict(self.headers), body))
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        if len(requests) == 1:
            frames = [
                event("message_start", {"type": "message_start"}),
                event("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": "Shouting"}}),
                event("content_block_start", {"index": 1, "content_block": {"type": "tool_use", "id": "toolu_1", "name": "upper", "input": {}}}),
                event("content_block_delta", {"index": 1, "delta": {"type": "input_json_delta", "partial_json": "{\"text\":"}}),
                event("content_block_delta", {"index": 1, "delta": {"type": "input_json_delta", "partial_json": "\"hello\"}"}}),
                event("content_block_stop", {"index": 1}),
                event("message_delta", {"delta": {"stop_reason": "tool_use"}}),
                event("message_stop", {}),
            ]
        else:
            frames = [
                event("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": "Done: HELLO"}}),
                event("message_delta", {"delta": {"stop_reason": "end_turn"}}),
                event("message_stop", {}),
            ]
        for frame in frames:
            # Split inside frames so the decoder sees mid-line chunk boundaries.
            half = len(frame) // 2
            self.wfile.write(frame[:half]); self.wfile.flush(); time.sleep(0.02)
            self.wfile.write(frame[half:]); self.wfile.flush(); time.sleep(0.02)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]

subprocess.run([str(ROOT / "scripts/haxeon"), "build", "--project", str(PROJECT)], check=True, stdout=subprocess.DEVNULL)
env = dict(os.environ)
output = PROJECT.parent / "build/host"
env["LD_LIBRARY_PATH"] = ":".join(str(p) for p in [ROOT / "out", ROOT / ".tools/hashlink", *sorted(p for p in (output / "native").iterdir() if p.is_dir())])
result = subprocess.run([str(ROOT / ".tools/hashlink/hl"), str(output / "main.hl"), str(port)], env=env, capture_output=True, text=True, timeout=60)
print(result.stdout.strip(), result.stderr.strip()[:500])
assert result.returncode == 0, f"check exited with {result.returncode}"
assert "text:Shouting" in result.stdout and "tool:upper=HELLO" in result.stdout and "text:Done: HELLO|ended" in result.stdout, result.stdout
assert len(requests) == 2, len(requests)
headers, first = requests[0]
assert headers.get("x-api-key") == "sk-local" and headers.get("anthropic-version") == "2023-06-01"
assert first["stream"] is True and first["tools"][0]["name"] == "upper" and first["system"] == "be terse"
last = requests[1][1]["messages"][-1]
assert last["role"] == "user" and last["content"][0]["type"] == "tool_result" and last["content"][0]["content"] == "HELLO", last
print("PASS: NativeKit streaming transport, Anthropic decoding and tool round trip")
