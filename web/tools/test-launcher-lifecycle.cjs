#!/usr/bin/env node
// Exercise the shipped launcher with controlled host/guest promise completion.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(process.argv[2] || path.join(__dirname, '../exosuit.js'), 'utf8');

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}
const settle = () => new Promise(resolve => setImmediate(resolve));

function launch() {
  const host = deferred(), guest = deferred();
  const events = new Map(), frames = [], errors = [];
  const memory = new WebAssembly.Memory({initial: 1});
  const canvas = {clientWidth: 800, clientHeight: 600};
  const status = {textContent: '', hidden: false};
  const calls = {received: 0, guest: 0, configure: 0, main: 0, frame: 0};
  const exports = {
    'app.WebMain.configure': () => { calls.configure++; return 0; },
    'app.WebMain.main': () => { calls.main++; return 0; },
    'app.WebMain.frame': () => { calls.frame++; return 1; }
  };
  const sandbox = {
    document: {getElementById: id => id === 'canvas' ? canvas : status},
    console: {error: message => errors.push(message), log() {}},
    WebAssembly: {Memory: WebAssembly.Memory, instantiateStreaming: () => host.promise},
    HaxeonWasmHost: {instantiate: () => { calls.guest++; return guest.promise; }},
    fetch: () => Promise.resolve({}),
    requestAnimationFrame: callback => frames.push(callback),
    addEventListener: (name, callback) => events.set(name, callback)
  };
  sandbox.window = sandbox;
  vm.runInNewContext(source, sandbox, {filename: 'exosuit.js'});
  const module = sandbox.Module;
  module._nkui_haxeon_memory_contract_status = () => 0;
  for (const [key, value] of Object.entries({version: 1, page_size: 65536, host_base: 0,
                                            host_limit: 65536, guest_base: 65536,
                                            guest_limit: 65536, memory_size: 65536}))
    module['_nkui_haxeon_memory_contract_' + key] = () => value;
  module.instantiateWasm({}, () => { calls.received++; module.onRuntimeInitialized(); });
  return {host, guest, memory, exports, calls, frames, errors, report: sandbox.exosuit,
          depart: () => events.get('pagehide')?.()};
}

async function hostReady(test) {
  test.host.resolve({instance: {exports: {memory: test.memory}}});
  await settle();
}

(async () => {
  let test = launch();
  test.host.reject(new Error('host unavailable'));
  await settle();
  assert.equal(test.report.state, 'failed', 'active host failures remain visible');

  test = launch();
  test.depart();
  test.host.reject(new Error('canceled departing host'));
  await settle();
  assert.equal(test.report.state, 'loading', 'departing host rejection must not publish failure');
  assert.equal(test.errors.length, 0);

  test = launch();
  test.depart();
  await hostReady(test);
  assert.equal(test.calls.received, 0, 'departing host completion must not initialize a runtime');
  assert.equal(test.calls.guest, 0);

  test = launch();
  await hostReady(test);
  test.guest.reject(new Error('guest unavailable'));
  await settle();
  assert.equal(test.report.state, 'failed', 'active guest failures remain visible');

  test = launch();
  await hostReady(test);
  test.depart();
  test.guest.reject(new Error('canceled departing guest'));
  await settle();
  assert.equal(test.report.state, 'loading', 'departing guest rejection must not publish failure');
  assert.equal(test.errors.length, 0);

  test = launch();
  await hostReady(test);
  test.depart();
  test.guest.resolve({exports: test.exports, unavailable: []});
  await settle();
  assert.equal(test.calls.configure, 0, 'departing guest completion must not configure/start an editor');
  assert.equal(test.calls.main, 0);
  assert.equal(test.frames.length, 0);

  test = launch();
  await hostReady(test);
  test.guest.resolve({exports: test.exports, unavailable: []});
  await settle();
  test.frames.shift()(0);
  assert.equal(test.report.state, 'running');
  assert.equal(test.calls.frame, 1);
  test.depart();
  test.frames.shift()(1);
  assert.equal(test.calls.frame, 1, 'a queued frame must retire when its document departs');
  assert.equal(test.frames.length, 0);
  console.log('PASS: active startup failures and retired browser startup/frame callbacks');
})().catch(error => { console.error(error); process.exitCode = 1; });
