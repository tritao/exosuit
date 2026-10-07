// Starts the browser editor: the Emscripten host (exosuit_web.js/.wasm) owns the linear memory and the
// NativeKit, UIKit and SceneKit C ABIs; the Haxeon guest (exosuit_guest.wasm, wasm32 or wasm-gc) is the editor.
// haxeon-host.js connects them. window.exosuit reports progress for tests: {state, frames, error, unavailable}.
"use strict";

const canvas = document.getElementById("canvas");
const statusLine = document.getElementById("status");
const report = window.exosuit = {state: "loading", frames: 0, error: null, unavailable: []};
report.remoteDeviceStore = window.ExosuitRemoteDeviceStore;
let hostMemory = null;
let guest = null;
let departing = false;
const pendingRemoteStoreRequests = new Set();
const cancelledRemoteStoreRequests = new Set();
window.addEventListener("pagehide", () => { departing = true; });

function completeRemoteStore(event, success) {
  pendingRemoteStoreRequests.delete(event.request);
  const callback = guest && guest["app.WebMain.remoteCredentialStored"];
  if (callback) callback(event.request, success ? 1 : 0);
}

function completeRemotePayload(request, kind, value, success) {
  const chunk = guest && guest["app.WebMain.remoteStorePayloadChunk"];
  const complete = guest && guest["app.WebMain.remoteStorePayloadComplete"];
  if (!chunk || !complete) return;
  if (success) {
    if (typeof value !== "string" || value.length > 32768) {
      complete(request, kind, 0, 0);
      return;
    }
    for (let index = 0; index < value.length; index++)
      chunk(request, kind, index, value.charCodeAt(index));
    complete(request, kind, value.length, 1);
  } else {
    complete(request, kind, 0, 0);
  }
}

function listRemoteDevices(text) {
  const request = Number(text.slice("exosuit-remote-list:".length));
  if (!Number.isSafeInteger(request) || request <= 0) return;
  const store = report.remoteDeviceStore;
  if (!store) {
    completeRemotePayload(request, 1, "", false);
    return;
  }
  store.list().then(devices => completeRemotePayload(request, 1, JSON.stringify(devices), true),
    () => completeRemotePayload(request, 1, "", false));
}

function loadRemoteDevice(text) {
  let event;
  try {
    event = JSON.parse(text.slice("exosuit-remote-load:".length));
    if (!Number.isSafeInteger(event.request) || event.request <= 0
      || !/^[0-9a-f]{32}$/.test(event.machineId) || !/^[0-9a-f]{32}$/.test(event.deviceId))
      throw new Error("invalid saved-device request");
  } catch (_error) {
    return;
  }
  const store = report.remoteDeviceStore;
  if (!store) {
    completeRemotePayload(event.request, 2, "", false);
    return;
  }
  store.load(event.machineId, event.deviceId).then(credentials => {
    if (!credentials) {
      completeRemotePayload(event.request, 2, "", false);
      return;
    }
    const payload = JSON.stringify({machineId: event.machineId, deviceId: event.deviceId, credentials});
    credentials.staticPrivateKey = "";
    credentials.deviceToken = "";
    credentials.machineStaticPublicKey = "";
    credentials.relayOrigin = null;
    completeRemotePayload(event.request, 2, payload, true);
  }, () => completeRemotePayload(event.request, 2, "", false));
}

function persistRemoteDevice(text) {
  let event;
  try {
    event = JSON.parse(text.slice("exosuit-remote-store:".length));
    if (!Number.isSafeInteger(event.request) || event.request <= 0 || pendingRemoteStoreRequests.has(event.request))
      throw new Error("invalid credential request");
    pendingRemoteStoreRequests.add(event.request);
  } catch (_error) {
    console.error("The browser rejected an invalid remote-device storage request.");
    return;
  }
  const store = report.remoteDeviceStore;
  if (!store) {
    completeRemoteStore(event, false);
    return;
  }
  const credentials = {
    staticPrivateKey: event.staticPrivateKey,
    deviceToken: event.deviceToken,
    machineStaticPublicKey: event.machineStaticPublicKey,
    relayOrigin: event.relayOrigin
  };
  event.staticPrivateKey = "";
  event.deviceToken = "";
  event.machineStaticPublicKey = "";
  store.save(event.machineId, event.deviceId, credentials).then(async () => {
    credentials.staticPrivateKey = "";
    credentials.deviceToken = "";
    credentials.machineStaticPublicKey = "";
    if (cancelledRemoteStoreRequests.delete(event.request)) {
      try { await store.remove(event.machineId, event.deviceId); }
      catch (_error) { console.error("Could not clean up an abandoned remote-device record."); }
      pendingRemoteStoreRequests.delete(event.request);
      return;
    }
    completeRemoteStore(event, true);
  }, error => {
    credentials.staticPrivateKey = "";
    credentials.deviceToken = "";
    credentials.machineStaticPublicKey = "";
    if (cancelledRemoteStoreRequests.delete(event.request)) {
      pendingRemoteStoreRequests.delete(event.request);
      return;
    }
    // Never include event data or credentials in diagnostics.
    console.error("Could not protect remote-device credentials in browser storage:", error && error.message);
    completeRemoteStore(event, false);
  });
}

function cancelRemoteDeviceStore(text) {
  const request = Number(text.slice("exosuit-remote-cancel:".length));
  if (Number.isSafeInteger(request) && pendingRemoteStoreRequests.has(request))
    cancelledRemoteStoreRequests.add(request);
}

function fail(message) {
  if (departing) return;
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
  if (departing) return;
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
  if (departing) return;
  const started = await HaxeonWasmHost.instantiate(fetch("exosuit_guest.wasm"),
    {emscripten: Module, memory: hostMemory, contract: hostContract(), print: text => {
      if (text.startsWith("exosuit-state:")) report.document = JSON.parse(text.slice("exosuit-state:".length));
      else if (text.startsWith("exosuit-remote-store:")) persistRemoteDevice(text);
      else if (text.startsWith("exosuit-remote-cancel:")) cancelRemoteDeviceStore(text);
      else if (text.startsWith("exosuit-remote-list:")) listRemoteDevices(text);
      else if (text.startsWith("exosuit-remote-load:")) loadRemoteDevice(text);
      else console.log(text);
    }});
  if (departing) return;
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
        if (departing) return;
        hostMemory = Object.values(result.instance.exports).find(value => value instanceof WebAssembly.Memory);
        receiveInstance(result.instance);
      })
      .catch(error => {
        if (!departing) fail("The NativeKit host failed to load: " + error.message);
      });
    return {};
  },
  onRuntimeInitialized() {
    if (departing) return;
    if (!hostMemory) {
      fail("The NativeKit host did not export its memory");
      return;
    }
    startGuest().catch(error => {
      if (!departing) fail("The editor failed to start: " + (error.stack || error.message));
    });
  },
  print: text => console.log(text),
  printErr: text => console.error(text)
};
