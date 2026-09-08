#!/usr/bin/env python3
import json
import sys

minimal = len(sys.argv) > 1 and sys.argv[1] == "minimal"


def read_message():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, value = line.decode("ascii").split(":", 1)
        if name.lower() == "content-length":
            length = int(value.strip())
    if length is None:
        raise RuntimeError("missing Content-Length")
    return json.loads(sys.stdin.buffer.read(length))


def send(message):
    body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode())
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


held = None
documents = {}
while True:
    message = read_message()
    if message is None:
        break
    method = message.get("method")
    if method == "initialize":
        capabilities = {"positionEncoding": "utf-16", "textDocumentSync": {"openClose": True, "change": 2}}
        if not minimal:
            capabilities.update({"hoverProvider": True, "completionProvider": {}, "definitionProvider": True,
                                 "signatureHelpProvider": {"triggerCharacters": ["(", ","]}})
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": capabilities}})
    elif method == "initialized":
        pass
    elif method == "textDocument/didOpen":
        item = message["params"]["textDocument"]
        documents[item["uri"]] = item
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
            "uri": item["uri"], "version": item["version"], "diagnostics": []}})
    elif method == "textDocument/didChange":
        item = message["params"]["textDocument"]
        documents[item["uri"]] = item
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
            "uri": item["uri"], "version": item["version"] - 1, "diagnostics": [{"severity": 1,
                "message": "stale", "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}}]}})
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
            "uri": item["uri"], "version": item["version"], "diagnostics": [{"severity": 2,
                "message": "current 😀", "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 2}}}]}})
        if message["params"]["contentChanges"][0]["text"] == "CRASH":
            sys.exit(7)
    elif method == "textDocument/didClose":
        documents.pop(message["params"]["textDocument"]["uri"], None)
    elif method == "textDocument/hover":
        item = documents[message["params"]["textDocument"]["uri"]]
        send({"jsonrpc": "2.0", "id": 9001, "method": "workspace/applyEdit", "params": {"edit": {"documentChanges": [{
            "textDocument": {"uri": item["uri"], "version": item["version"]},
            "edits": [{"range": {"start": {"line": 0, "character": 2}, "end": {"line": 0, "character": 2}}, "newText": "server"}]}]}}})
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"contents": {"kind": "markdown", "value": "hover 😀"}}})
    elif method == "textDocument/completion":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"items": [{"label": "completed", "detail": "fake", "insertText": "completion"}]}})
    elif method == "textDocument/definition":
        position = message["params"]["position"]
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"uri": message["params"]["textDocument"]["uri"],
            "range": {"start": position, "end": position}}})
    elif method == "textDocument/signatureHelp":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"activeSignature": 0, "activeParameter": 1,
            "signatures": [{"label": "sum(left:Int, right:Int):Int", "documentation": {"kind": "markdown", "value": "Adds values"},
                            "parameters": [{"label": "left:Int"}, {"label": "right:Int"}]}]}})
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})
    elif method == "exit":
        break
    elif method == "hold":
        held = message
    elif method == "fast":
        send({"jsonrpc": "2.0", "id": message["id"], "result": "Olá 😀"})
        if held is not None:
            send({"jsonrpc": "2.0", "id": held["id"], "result": "held"})
            held = None
    elif method == "quit":
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})
        break
    elif method == "stderrFlood":
        sys.stderr.write("e" * 70000)
        sys.stderr.flush()
        send({"jsonrpc": "2.0", "id": message["id"], "result": True})
    elif method == "$/cancelRequest":
        send({"jsonrpc": "2.0", "method": "cancelSeen", "params": message["params"]})
