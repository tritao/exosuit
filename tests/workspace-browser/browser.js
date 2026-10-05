"use strict";
window.rpcTest = {ready: false, generations: 0, epochs: 0, error: null};
let hostMemory, guest;

function tick() {
  try {
    const state = guest["app.BrowserRpcMain.frame"]();
    if (state < 0) throw new Error("RPC client failed: " + state);
    window.rpcTest.diagnostic = guest["app.BrowserRpcMain.diagnostic"]();
    window.rpcTest.generations = state;
    window.rpcTest.epochs = guest["app.BrowserRpcMain.epochChanges"]();
  } catch (error) {
    window.rpcTest.error = String(error);
    return;
  }
  requestAnimationFrame(tick);
}

window.startRpcTest = (port, token) => {
  for (let index = 0; index < token.length; index++)
    guest["app.BrowserRpcMain.credential"](index, token.charCodeAt(index));
  guest["app.BrowserRpcMain.start"](port);
  tick();
};
window.suspendRpcTest = () => guest["app.BrowserRpcMain.suspend"]();

var Module = {
  instantiateWasm(imports, receive) {
    WebAssembly.instantiateStreaming(fetch("workspace_rpc_host.wasm"), imports)
      .then(result => {
        hostMemory = Object.values(result.instance.exports)
          .find(value => value instanceof WebAssembly.Memory);
        receive(result.instance);
      }).catch(error => { window.rpcTest.error = String(error); });
    return {};
  },
  onRuntimeInitialized() {
    (async () => {
      const result = await HaxeonWasmHost.instantiate(fetch("guest.wasm"), {
        emscripten: Module,
        memory: hostMemory,
        contract: {
          version: 1, pageSize: 65536,
          hostBase: 0, hostLimit: 33554432,
          guestBase: 33554432, guestLimit: 134217728, memorySize: 134217728
        }
      });
      guest = result.exports;
      window.rpcTest.ready = true;
    })().catch(error => { window.rpcTest.error = String(error); });
  }
};
