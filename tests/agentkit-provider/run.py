#!/usr/bin/env python3
"""Runs the built-in agent provider against a local Anthropic-compatible SSE server."""
import json, os, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HAXEON = REPO / "haxeon"
PROJECT = Path(__file__).resolve().parent / "haxeon.json"
problems = []

def frame(name, data):
    return f"event: {name}\ndata: {json.dumps(data)}\n\n".encode()

def text_frames(text):
    return [frame("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": text}}),
            frame("message_delta", {"delta": {"stop_reason": "end_turn"}}), frame("message_stop", {})]

def tool_frames(call_id, name, args, lead=""):
    frames = []
    if lead:
        frames.append(frame("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": lead}}))
    text = json.dumps(args)
    frames += [frame("content_block_start", {"index": 1, "content_block": {"type": "tool_use", "id": call_id, "name": name, "input": {}}}),
               frame("content_block_delta", {"index": 1, "delta": {"type": "input_json_delta", "partial_json": text[:len(text) // 2]}}),
               frame("content_block_delta", {"index": 1, "delta": {"type": "input_json_delta", "partial_json": text[len(text) // 2:]}}),
               frame("content_block_stop", {"index": 1}),
               frame("message_delta", {"delta": {"stop_reason": "tool_use"}}), frame("message_stop", {})]
    return frames

def check_well_formed(messages):
    """The API rejects histories where a tool_use is not answered by the next user message."""
    for index, message in enumerate(messages):
        uses = [b["id"] for b in message["content"] if b["type"] == "tool_use"] if isinstance(message["content"], list) else []
        if uses:
            following = messages[index + 1] if index + 1 < len(messages) else None
            answered = [b["tool_use_id"] for b in following["content"] if b["type"] == "tool_result"] if following else []
            if sorted(uses) != sorted(answered):
                problems.append(f"unanswered tool_use {uses} at message {index}")

def respond(messages):
    check_well_formed(messages)
    last = messages[-1]
    prompt = ""
    for message in reversed(messages):
        blocks = message["content"]
        if message["role"] == "user" and blocks and blocks[0]["type"] == "text":
            prompt = blocks[0]["text"]
            break
    result = last["content"][0] if last["content"][0]["type"] == "tool_result" else None
    if result is None:
        if prompt == "read it": return tool_frames("t_read", "read_file", {"path": "hello.txt"}, "Reading. ")
        if prompt == "edit it": return tool_frames("t_edit", "edit_file", {"path": "hello.txt", "old_text": "hello", "new_text": "goodbye"})
        if prompt == "write it": return tool_frames("t_write", "write_file", {"path": "new.txt", "content": "nope"})
        if prompt == "escape it": return tool_frames("t_escape", "read_file", {"path": "../agentkit-outside-%d.txt" % PORT})
        if prompt == "count": return text_frames("messages:%d" % len(messages))
        if prompt == "slow": return None
        return text_frames("unknown prompt " + prompt)
    if prompt == "read it": return text_frames("It says: " + result["content"].strip().replace("\n", " "))
    return text_frames("Finished: " + result["content"][:60])

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        if self.headers.get("x-api-key") != "sk-test": problems.append("missing api key")
        frames = respond(body["messages"])
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        try:
            if frames is None:  # a long answer the test interrupts
                for i in range(200):
                    self.wfile.write(frame("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": "tick "}})); self.wfile.flush()
                    time.sleep(0.05)
                return
            for item in frames:
                self.wfile.write(item); self.wfile.flush(); time.sleep(0.005)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
PORT = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()

subprocess.run([str(HAXEON / "scripts/haxeon"), "build", "--project", str(PROJECT)], check=True, stdout=subprocess.DEVNULL)
output = PROJECT.parent / "build/host"
env = dict(os.environ)
env["LD_LIBRARY_PATH"] = ":".join(str(p) for p in [HAXEON / "out", HAXEON / ".tools/hashlink", *sorted(p for p in (output / "native").iterdir() if p.is_dir())])
with tempfile.TemporaryDirectory(prefix="exosuit-agentkit-") as work:
    root = Path(work) / "workspace"
    root.mkdir()
    result = subprocess.run([str(HAXEON / ".tools/hashlink/hl"), str(output / "main.hl"), str(root), str(PORT)], env=env, capture_output=True, text=True, timeout=120)
    outside = Path(work) / f"agentkit-outside-{PORT}.txt"
print(result.stdout.strip())
if result.returncode != 0:
    print(result.stderr.strip()[-2000:])
assert result.returncode == 0, f"provider test exited with {result.returncode}"
assert not problems, problems
print("PASS: built-in agent provider end to end")
