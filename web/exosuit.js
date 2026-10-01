// Starts the browser editor: the Emscripten host (exosuit_web.js/.wasm) owns the linear memory and the
// NativeKit, UIKit and SceneKit C ABIs; the Haxeon guest (exosuit_guest.wasm, wasm32 or wasm-gc) is the editor.
// haxeon-host.js connects them. window.exosuit reports progress for tests: {state, frames, error, unavailable}.
"use strict";

const canvas = document.getElementById("canvas");
const statusLine = document.getElementById("status");
const report = window.exosuit = {state: "loading", frames: 0, error: null, unavailable: []};
let hostMemory = null;
let guest = null;

function fail(message) {
  report.state = "failed";
  report.error = message;
  statusLine.textContent = message;
  statusLine.hidden = false;
  console.error(message);
}

function nativeError() {
  const pointer = Module["_nk_last_error"] ? Module["_nk_last_error"]() : 0;
  if (!pointer) return "";
  const bytes = new Uint8Array(hostMemory.buffer);
  let end = pointer;
  while (bytes[end] !== 0) end++;
  return new TextDecoder().decode(bytes.subarray(pointer, end));
}

// The host's half of the linear-memory partition the guest was compiled against.
function hostContract() {
  const read = name => Module["_nkui_haxeon_memory_contract_" + name]() >>> 0;
  if (Module["_nkui_haxeon_memory_contract_status"]() !== 0)
    throw new Error("the native heap crossed into the guest's memory");
  const contract = {
    version: read("version"), pageSize: read("page_size"), hostBase: read("host_base"), hostLimit: read("host_limit"),
    guestBase: read("guest_base"), guestLimit: read("guest_limit"), memorySize: read("memory_size")
  };
  if (hostMemory.buffer.byteLength !== contract.memorySize)
    throw new Error("the host memory does not have the contract's size");
  return contract;
}

function frame(time) {
  try {
    const result = guest["app.WebMain.frame"](time);
    if (result < 0) {
      fail("The editor stopped with an error; see the console. " + nativeError());
      return;
    }
    report.frames++;
    if (report.state === "loading") {
      report.state = "running";
      statusLine.hidden = true;
    }
    if (result > 0) requestAnimationFrame(frame);
    else report.state = "stopped";
  } catch (error) {
    fail("The editor failed: " + (error.stack || error.message));
  }
}

async function startGuest() {
  const started = await HaxeonWasmHost.instantiate(fetch("exosuit_guest.wasm"),
    {emscripten: Module, memory: hostMemory, contract: hostContract(), print: text => {
      if (text.startsWith("exosuit-state:")) report.document = JSON.parse(text.slice("exosuit-state:".length));
      else console.log(text);
    }});
  guest = started.exports;
  report.snapshot = () => guest["app.WebMain.snapshot"]();
  report.openDocumentation = () => guest["app.WebMain.openDocumentation"]();
  report.unavailable = started.unavailable;
  if (guest["app.WebMain.configure"](canvas.clientWidth, canvas.clientHeight) !== 0)
    throw new Error("the editor rejected the canvas size");
  if (guest["app.WebMain.main"]() !== 0)
    throw new Error("the editor did not start; see the console. " + nativeError());
  requestAnimationFrame(frame);
}

var Module = {
  canvas,
  instantiateWasm(imports, receiveInstance) {
    WebAssembly.instantiateStreaming(fetch("exosuit_web.wasm"), imports)
      .then(result => {
        hostMemory = Object.values(result.instance.exports).find(value => value instanceof WebAssembly.Memory);
        receiveInstance(result.instance);
      })
      .catch(error => fail("The NativeKit host failed to load: " + error.message));
    return {};
  },
  onRuntimeInitialized() {
    if (!hostMemory) {
      fail("The NativeKit host did not export its memory");
      return;
    }
    startGuest().catch(error => fail("The editor failed to start: " + (error.stack || error.message)));
  },
  print: text => console.log(text),
  printErr: text => console.error(text)
};
