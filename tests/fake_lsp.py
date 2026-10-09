#!/usr/bin/env python3
import json
import sys
import os
import threading

output_lock = threading.Lock()

events_path = sys.argv[sys.argv.index("--events") + 1] if "--events" in sys.argv else None
root_uri = ""

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
    with output_lock:
        sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode())
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()


held = None
held_rename = None
documents = {}
while True:
    message = read_message()
    if message is None:
        break
    method = message.get("method")
    if method == "initialize":
        root_uri = message["params"]["rootUri"]
    if events_path:
        with open(events_path, "a") as events:
            events.write(json.dumps({"pid": os.getpid(), "root": root_uri, "method": method,
                                     "params": message.get("params")}) + "\n")
    if method == "initialize":
        capabilities = {"positionEncoding": "utf-8" if "bad-encoding" in sys.argv else "utf-16", "textDocumentSync": {"openClose": True, "change": 2}}
        if not minimal:
            capabilities.update({"hoverProvider": True, "completionProvider": {}, "definitionProvider": True, "typeDefinitionProvider": True,
                                 "signatureHelpProvider": {"triggerCharacters": ["(", ","]}, "documentSymbolProvider": True, "referencesProvider": True, "renameProvider": {}, "documentFormattingProvider": True, "documentRangeFormattingProvider": True})
        if "--semantic" in sys.argv:
            capabilities["semanticTokensProvider"] = {"legend": {"tokenTypes": ["function", "class"], "tokenModifiers": ["readonly"]}, "full": True}
        response = {"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": capabilities}}
        if "--slow-initialize" in sys.argv:
            threading.Timer(5.2, send, args=(response,)).start()
        elif "--initialize-delay" in sys.argv:
            threading.Timer(0.4, send, args=(response,)).start()
        else:
            send(response)
    elif method == "initialized":
        pass
    elif method == "textDocument/didOpen":
        item = message["params"]["textDocument"]
        documents[item["uri"]] = item
        if "--idle-diagnostic" in sys.argv:
            notification = {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
                "uri": item["uri"], "version": item["version"], "diagnostics": [{"severity": 1,
                    "message": "Idle background diagnostic", "range": {
                        "start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}}}]}}
            timer = threading.Timer(2.0, send, args=[notification])
            timer.daemon = True
            timer.start()
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
        if held_rename is not None:
            send(held_rename)
            held_rename = None
        if message["params"]["contentChanges"][0]["text"] == "CRASH":
            sys.exit(7)
    elif method == "textDocument/didClose":
        documents.pop(message["params"]["textDocument"]["uri"], None)
    elif method in ("textDocument/formatting", "textDocument/rangeFormatting"):
        options = message["params"]["options"]
        if options != {"tabSize": 3, "insertSpaces": True}:
            send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32602, "message": "wrong formatting settings"}})
            continue
        edit_range = message["params"].get("range", {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}})
        send({"jsonrpc": "2.0", "id": message["id"], "result": [{"range": edit_range, "newText": "   "}]})
    elif method == "textDocument/hover":
        item = documents[message["params"]["textDocument"]["uri"]]
        send({"jsonrpc": "2.0", "id": 9001, "method": "workspace/applyEdit", "params": {"edit": {"documentChanges": [{
            "textDocument": {"uri": item["uri"], "version": item["version"]},
            "edits": [{"range": {"start": {"line": 0, "character": 2}, "end": {"line": 0, "character": 2}}, "newText": "server"}]}]}}})
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"contents": {"kind": "markdown", "value": "hover 😀"}}})
    elif method == "textDocument/completion":
        response = {"jsonrpc": "2.0", "id": message["id"], "result": {"items": [{"label": "completed", "detail": "fake", "insertText": "completion", "filterText": "completion", "kind": 3, "documentation": {"kind": "markdown", "value": "Completion documentation"}}]}}
        if "--slow-completion" in sys.argv:
            threading.Timer(6.0, send, args=(response,)).start()
        else:
            send(response)
    elif method in ("textDocument/definition", "textDocument/typeDefinition"):
        def reply(response):
            if "--definition-delay" in sys.argv:
                threading.Timer(0.4, send, args=(response,)).start()
            else:
                send(response)
        position = message["params"]["position"]
        location = {"uri": message["params"]["textDocument"]["uri"], "range": {"start": position, "end": position}}
        if position["character"] == 5:
            other = {"uri": root_uri + "/Other.hx", "range": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 2}}}
            reply({"jsonrpc": "2.0", "id": message["id"], "result": [location, other]})
        elif position["character"] == 6:
            reply({"jsonrpc": "2.0", "id": message["id"], "result": None})
        elif position["character"] == 7:
            reply({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32801, "message": "Document is still being analysed"}})
        else:
            reply({"jsonrpc": "2.0", "id": message["id"], "result": location})
    elif method == "textDocument/signatureHelp":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"activeSignature": 0, "activeParameter": 1,
            "signatures": [{"label": "sum(left:Int, right:Int):Int", "documentation": {"kind": "markdown", "value": "Adds values"},
                            "parameters": [{"label": "left:Int"}, {"label": "right:Int"}]}]}})
    elif method == "textDocument/documentSymbol":
        span = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 2}}
        send({"jsonrpc": "2.0", "id": message["id"], "result": [{"name": "Main", "kind": 5, "range": span, "selectionRange": span,
              "children": [{"name": "value", "kind": 13, "detail": "Int", "range": span, "selectionRange": span}]}]})
    elif method == "textDocument/references":
        span = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}
        send({"jsonrpc": "2.0", "id": message["id"], "result": [
              {"uri": message["params"]["textDocument"]["uri"], "range": {"start": message["params"]["position"], "end": message["params"]["position"]}},
              {"uri": root_uri + "/Other.hx", "range": span}]})
    elif method == "textDocument/rename":
        item = documents[message["params"]["textDocument"]["uri"]]
        name = message["params"]["newName"]
        origin = {"textDocument": {"uri": item["uri"], "version": item["version"]},
                  "edits": [{"range": {"start": message["params"]["position"], "end": message["params"]["position"]}, "newText": name}]}
        changes = [origin]
        if name in ("multi", "overlap"):
            span = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}
            edits = [{"range": span, "newText": "other"}]
            if name == "overlap": edits.append({"range": span, "newText": "conflict"})
            changes.append({"textDocument": {"uri": root_uri + "/Other.hx", "version": None}, "edits": edits})
        if name == "version-conflict": origin["textDocument"]["version"] -= 1
        response = {"jsonrpc": "2.0", "id": message["id"], "result": {"documentChanges": changes}}
        if name == "stale": held_rename = response
        else: send(response)
    elif method == "textDocument/semanticTokens/full":
        item = documents[message["params"]["textDocument"]["uri"]]
        version = item["version"]
        response = {"jsonrpc": "2.0", "id": message["id"], "result": {"data": [0, 3 + version - 1, 5, 0, 1]}}
        timer = threading.Timer(0.3, send, args=[response])
        timer.daemon = True
        timer.start()
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
