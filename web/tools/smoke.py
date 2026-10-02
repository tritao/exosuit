#!/usr/bin/env python3
"""Drives the browser editor in Chrome over the DevTools protocol.

Waits until the page reports that the editor has drawn --frames frames (window.exosuit),
prints the page's console output, and optionally saves a screenshot. Exits non-zero if the
editor fails or does not start in time.
"""

import argparse
import base64
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../../nativekit/tools"))
from web_smoke import WebSocket, wait_for_page  # noqa: E402


class Page:
    def __init__(self, socket):
        self.socket = socket
        self.next_id = 0
        self.console = []
        self.network_failures = []
        self.loaded_documents = set()

    def command(self, method, params=None):
        self.next_id += 1
        self.socket.send({"id": self.next_id, "method": method, "params": params or {}})
        while True:
            kind, payload = self.socket.receive()
            if kind != 1:
                continue
            message = json.loads(payload)
            event, params_ = message.get("method"), message.get("params", {})
            if event == "Page.lifecycleEvent" and params_.get("name") == "load":
                self.loaded_documents.add((params_["frameId"], params_["loaderId"]))
            if event == "Network.loadingFailed":
                self.network_failures.append(params_)
            if event == "Runtime.consoleAPICalled":
                text = " ".join(str(argument.get("value", argument.get("description", "")))
                                for argument in params_.get("args", []))
                self.console.append(f"[{params_.get('type')}] {text}")
            elif event == "Runtime.exceptionThrown":
                details = params_.get("exceptionDetails", {})
                self.console.append("[exception] " + (details.get("exception", {}).get("description")
                                                      or details.get("text", "")))
            elif event == "Log.entryAdded":
                entry = params_.get("entry", {})
                if entry.get("level") == "error":
                    self.console.append("[error] " + entry.get("text", ""))
            if message.get("id") == self.next_id:
                if "error" in message:
                    raise RuntimeError(json.dumps(message["error"]))
                return message.get("result", {})

    def evaluate(self, expression):
        result = self.command("Runtime.evaluate", {"expression": expression, "returnByValue": True})
        if result.get("exceptionDetails"):
            raise RuntimeError(json.dumps(result["exceptionDetails"]))
        return result.get("result", {}).get("value")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--debug-port", type=int, required=True)
    parser.add_argument("--page-url", required=True)
    parser.add_argument("--frames", type=int, default=30)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--screenshot")
    options = parser.parse_args()

    target = wait_for_page(options.debug_port, options.page_url, 30)
    page = Page(WebSocket(target["webSocketDebuggerUrl"]))
    page.command("Runtime.enable")
    page.command("Page.enable")
    page.command("Page.setLifecycleEventsEnabled", {"enabled": True})
    page.command("Log.enable")
    page.command("Network.enable")
    page.command("Page.bringToFront")
    deadline = time.monotonic() + options.timeout
    state = {}
    while time.monotonic() < deadline:
        state = page.evaluate("JSON.stringify(window.exosuit || null)")
        state = (json.loads(state) if state else None) or {}
        if state.get("state") in ("failed", "stopped") or state.get("frames", 0) >= options.frames:
            break
        time.sleep(0.25)
    if state.get("state") != "running":
        raise AssertionError(json.dumps({"state": state, "console": page.console, "networkFailures": page.network_failures}, ensure_ascii=False))

    def snapshot():
        return json.loads(page.evaluate("window.exosuit.snapshot(); JSON.stringify(window.exosuit.document)"))

    def wait_document(predicate, description):
        limit = time.monotonic() + 15
        latest = snapshot()
        while time.monotonic() < limit:
            if predicate(latest):
                return latest
            lifecycle = page.evaluate("window.exosuit.state")
            if lifecycle in ("failed", "stopped"):
                raise AssertionError(page.evaluate("JSON.stringify(window.exosuit)"))
            time.sleep(0.1)
            latest = snapshot()
        raise AssertionError(f"Timed out waiting for {description}: {latest}")

    original = "class Main { static function main():Int { return 1; } }\n"
    edited = "class Main { static function main():Int { return 42; } } // browser smoke é🙂!\n"
    initial = snapshot()
    assert initial["content"] == original and not initial["dirty"], initial
    assert not initial["errors"], initial
    assert "build" not in initial["shell"]["panels"], initial
    assert not any(name.startswith(("build:", "lang:", "plugins:")) for name in initial["commands"]), initial

    def key(letter):
        for kind in ("keyDown", "keyUp"):
            page.command("Input.dispatchKeyEvent", {"type": kind, "modifiers": 2, "key": letter.lower(),
                                                   "code": "Key" + letter, "windowsVirtualKeyCode": ord(letter)})

    for kind in ("mousePressed", "mouseReleased"):
        page.command("Input.dispatchMouseEvent", {"type": kind, "x": 550, "y": 130,
                                                 "button": "left", "clickCount": 1})
    focus_deadline = time.monotonic() + 10
    while time.monotonic() < focus_deadline and page.evaluate("document.activeElement.id") != "__nativekit_text_input":
        time.sleep(0.1)
    assert page.evaluate("document.activeElement.id") == "__nativekit_text_input", page.evaluate("document.activeElement.outerHTML")
    # DOM focus can precede the guest consuming the queued pointer event.
    # Wait for complete event-pump frames before sending the shortcut.
    focus_frame = page.evaluate("window.exosuit.frames") + 2
    focus_limit = time.monotonic() + 15
    while page.evaluate("window.exosuit.frames") < focus_frame and time.monotonic() < focus_limit:
        time.sleep(0.1)
    assert page.evaluate("window.exosuit.frames") >= focus_frame, page.evaluate("JSON.stringify(window.exosuit)")
    key("A")
    selection_deadline = time.monotonic() + 15
    while time.monotonic() < selection_deadline:
        if page.evaluate("(() => { const e=document.activeElement; return e.selectionStart === 0 && e.selectionEnd === e.value.length; })()"):
            break
        time.sleep(0.1)
    assert page.evaluate("(() => { const e=document.activeElement; return e.selectionStart === 0 && e.selectionEnd === e.value.length; })()"), page.evaluate("(() => {const e=document.activeElement;return {selection:[e.selectionStart,e.selectionEnd],value:e.value,active:e._nkActive,frames:window.exosuit.frames,state:window.exosuit.state,error:window.exosuit.error};})()")
    page.command("Input.insertText", {"text": edited.rstrip("!\n")})
    wait_document(lambda document: document["buffer"] == edited.rstrip("!\n"), "Unicode text insertion")
    page.command("Input.dispatchKeyEvent", {"type": "keyDown", "key": "!", "code": "Digit1",
                                            "text": "!", "windowsVirtualKeyCode": 49, "modifiers": 8})
    page.command("Input.dispatchKeyEvent", {"type": "keyUp", "key": "!", "code": "Digit1",
                                            "windowsVirtualKeyCode": 49, "modifiers": 8})
    wait_document(lambda document: document["buffer"] == edited.rstrip("\n"), "ordinary character insertion")
    for kind in ("keyDown", "keyUp"):
        page.command("Input.dispatchKeyEvent", {"type":kind, "key":"Enter", "code":"Enter", "windowsVirtualKeyCode":13})
    changed = wait_document(lambda document: document["buffer"] == edited, "newline insertion")
    assert changed["dirty"] and changed["content"] == original, changed
    key("S")
    saved = wait_document(lambda document: document["content"] == edited and not document["dirty"], "save/readback")
    assert saved["content"] == edited and not saved["dirty"] and not saved["errors"], saved

    def capture(path):
        shot = page.command("Page.captureScreenshot", {"format": "png"})
        with open(path, "wb") as handle:
            handle.write(base64.b64decode(shot["data"]))

    if options.screenshot:
        stem, extension = os.path.splitext(options.screenshot)
        capture(stem + "-edited" + extension)

    opened = page.evaluate("""(() => {
      const previous = window.open;
      const calls = [];
      window.open = (...args) => { calls.push(args); return {}; };
      try { return {result: window.exosuit.openDocumentation(), calls}; }
      finally { window.open = previous; }
    })()""")
    assert opened["result"] == 0 and opened["calls"] == [["https://github.com/tritao/pragtical-haxeon", "_blank", "noopener,noreferrer"]], opened

    previous_origin = page.evaluate("performance.timeOrigin")
    previous_frame = page.command("Page.getFrameTree")["frameTree"]["frame"]
    page.command("Page.reload", {"ignoreCache": True})
    reloaded = False
    probe = None
    while time.monotonic() < deadline:
        # A reload cancels requests in the outgoing document. Its callbacks may
        # report failure before Chrome replaces the execution context. Inspect
        # application state only after the new main-frame loader commits and
        # emits load; failures in that document remain fatal below.
        current_frame = page.command("Page.getFrameTree")["frameTree"]["frame"]
        loaded = (current_frame["id"], current_frame["loaderId"]) in page.loaded_documents
        if current_frame["loaderId"] == previous_frame["loaderId"] or not loaded:
            time.sleep(0.25)
            continue
        try:
            probe = json.loads(page.evaluate("JSON.stringify({origin: performance.timeOrigin, state: window.exosuit || null})"))
        except RuntimeError as error:
            if "Execution context was destroyed" not in str(error) and "Cannot find context" not in str(error):
                raise
            time.sleep(0.25)
            continue
        if probe["origin"] == previous_origin:
            time.sleep(0.25)
            continue
        state = probe["state"] or {}
        if state.get("state") == "failed":
            raise AssertionError(json.dumps({"state": state, "console": page.console, "networkFailures": page.network_failures}, ensure_ascii=False))
        if state.get("state") == "running" and state.get("frames", 0) >= options.frames:
            reloaded = True
            break
        time.sleep(0.25)
    assert reloaded, json.dumps({"message": "fresh document did not reach the requested running frames",
                                 "probe": probe, "console": page.console,
                                 "networkFailures": page.network_failures}, ensure_ascii=False)
    restored = snapshot()
    assert restored["content"] == original and not restored["dirty"] and not restored["errors"], restored
    state = json.loads(page.evaluate("JSON.stringify(window.exosuit || null)") or "null") or {}
    if options.screenshot:
        capture(options.screenshot)
    for line in page.console:
        print(line)
    print("exosuit:", json.dumps(state))
    if state.get("state") != "running" or state.get("frames", 0) < options.frames:
        print("smoke: the editor did not reach", options.frames, "frames", file=sys.stderr)
        return 1
    failures = [line for line in page.console if line.startswith(("[error]", "[exception]", "[assert]"))]
    if failures:
        raise AssertionError("Browser errors:\n" + "\n".join(failures))
    print("PASS: browser typing, dirty tracking, save/readback, URL and fresh session reload")
    return 0


if __name__ == "__main__":
    sys.exit(main())
