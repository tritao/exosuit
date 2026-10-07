import fs from 'node:fs';

const [invitePath, statusPath, decisionPath, successPath] = process.argv.slice(2);
if (!invitePath || !statusPath || !decisionPath || !successPath) throw new Error('Expected invite, status, decision and success files');
const chrome = `http://127.0.0.1:${process.env.EXOSUIT_CDP_PORT || 9224}`;
const appOrigin = `http://localhost:${process.env.EXOSUIT_APP_PORT || 5173}`;
const targetResponse = await fetch(`${chrome}/json/new?about:blank`, {method: 'PUT'});
if (!targetResponse.ok) throw new Error(`Could not open browser app: ${targetResponse.status}`);
const target = await targetResponse.json();
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
let next = 1;
const pending = new Map();
const browserDiagnostics = [];
socket.onmessage = event => {
  const message = JSON.parse(event.data);
  if (message.method === 'Runtime.exceptionThrown')
    browserDiagnostics.push(message.params.exceptionDetails?.text || 'Browser JavaScript exception');
  if (message.method === 'Log.entryAdded')
    browserDiagnostics.push(message.params.entry?.text || 'Browser log entry');
  if (message.method === 'Runtime.consoleAPICalled')
    browserDiagnostics.push((message.params.args || []).map(item => item.value ?? item.description ?? '').join(' '));
  if (!message.id || !pending.has(message.id)) return;
  const request = pending.get(message.id);
  pending.delete(message.id);
  message.error ? request.reject(new Error(message.error.message)) : request.resolve(message.result);
};
function send(method, params = {}) {
  const id = next++;
  const result = new Promise((resolve, reject) => pending.set(id, {resolve, reject}));
  socket.send(JSON.stringify({id, method, params}));
  return result;
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function click(x, y) {
  await send('Input.dispatchMouseEvent', {type: 'mouseMoved', x, y});
  await send('Input.dispatchMouseEvent', {type: 'mousePressed', x, y, button: 'left', clickCount: 1});
  await send('Input.dispatchMouseEvent', {type: 'mouseReleased', x, y, button: 'left', clickCount: 1});
}
async function expression(source) {
  const response = await send('Runtime.evaluate', {expression: source, awaitPromise: true, returnByValue: true});
  if (response.exceptionDetails) throw new Error(response.exceptionDetails.text || 'Browser evaluation failed');
  return response.result?.value;
}
async function remoteState() {
  await expression('window.exosuit.snapshot()');
  return expression('window.exosuit.document?.remoteAccess');
}
async function shellState() {
  await expression('window.exosuit.snapshot()');
  return expression('window.exosuit.document?.shell');
}
function readStatus() {
  try { return JSON.parse(fs.readFileSync(statusPath, 'utf8')); }
  catch (_error) { return null; }
}
function writePrivate(path, value) {
  const temporary = `${path}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value), {mode: 0o600});
  fs.renameSync(temporary, path);
}
async function waitFor(description, predicate, timeout = 60000) {
  const deadline = Date.now() + timeout;
  let value;
  while (Date.now() < deadline) {
    value = await predicate();
    if (value) return value;
    const app = await expression('({state:window.exosuit?.state,error:window.exosuit?.error})');
    if (app?.state === 'failed') throw new Error(`Browser app failed: ${app.error}\n${browserDiagnostics.join('\n')}`);
    await pause(200);
  }
  throw new Error(`Timed out waiting for ${description}: ${JSON.stringify(value)}`);
}
try {
  await send('Runtime.enable');
  await send('Log.enable');
  await send('Page.enable');
  await send('Page.addScriptToEvaluateOnNewDocument', {source: `(()=>{
    const NativeWebSocket = window.WebSocket;
    window.__exosuitTestSockets = [];
    window.WebSocket = new Proxy(NativeWebSocket, {construct(target, args) {
      const socket = Reflect.construct(target, args);
      window.__exosuitTestSockets.push(socket);
      return socket;
    }});
  })();`});
  await send('Page.navigate', {url: `${appOrigin}/`});
  await waitFor('editor startup', async () => (await expression('window.exosuit?.state')) === 'running');

  // Select Remote Access in the activity rail and submit the host-created one-use URL.
  await click(28, 160);
  const invitation = JSON.parse(fs.readFileSync(invitePath, 'utf8'));
  await click(160, 289);
  await send('Input.insertText', {text: invitation.pairingSocketUrl});
  await click(110, 337);

  const browser = await waitFor('browser Noise authentication code', async () => {
    const state = await remoteState();
    if (state?.error) throw new Error(`Browser pairing failed: ${state.error}`);
    return state?.authenticationCode ? state : null;
  });
  const desktop = await waitFor('matching desktop pending pairing', () => {
    const status = readStatus();
    const candidate = status?.pending?.find(item => item.deviceId === invitation.deviceId);
    return candidate ? {status, candidate} : null;
  });
  if (browser.authenticationCode !== desktop.candidate.authenticationCode)
    throw new Error('Browser and desktop authentication codes differ');
  writePrivate(decisionPath, {deviceId: invitation.deviceId, authenticationCode: browser.authenticationCode});
  console.log('PASS: browser and desktop display the same Noise authentication code');

  // Confirm the code in the same panel; approval is gated on the exact matching code above.
  await click(160, 405);
  const connected = await waitFor('authenticated workspace identity and credential storage', async () => {
    const state = await remoteState();
    if (state?.error) throw new Error(`Browser pairing failed: ${state.error}`);
    if (!state?.workspaceRoot) return null;
    const records = await expression('window.ExosuitRemoteDeviceStore.list()');
    const record = records?.find(item => item.machineId === invitation.machineId && item.deviceId === invitation.deviceId);
    if (!record) return null;
    const credentials = await expression(`window.ExosuitRemoteDeviceStore.load(${JSON.stringify(invitation.machineId)},${JSON.stringify(invitation.deviceId)})`);
    const pairingUrl = new URL(invitation.pairingSocketUrl);
    const relayOrigin = `${pairingUrl.protocol === 'wss:' ? 'https:' : 'http:'}//${pairingUrl.host}`;
    if (!credentials || !/^[0-9a-f]{64}$/.test(credentials.staticPrivateKey)
      || !/^[0-9a-f]{64}$/.test(credentials.deviceToken)
      || !/^[0-9a-f]{64}$/.test(credentials.machineStaticPublicKey)
      || credentials.relayOrigin !== relayOrigin || record.relayOrigin !== relayOrigin)
      throw new Error('Browser could not authenticate its encrypted device credential record');
    return {state, record, relayOrigin};
  });
  if (!connected.state.status.includes('Connected'))
    throw new Error(`RPC identity arrived with unexpected state: ${connected.state.status}`);
  if (!connected.state.grants?.includes('workspace.identity') || !connected.state.grants?.includes('workspace.read')
    || !connected.state.grants?.includes('workspace.files.read'))
    throw new Error('The connected browser did not receive the approved workspace grants');
  const remoteExplorer = await waitFor('connected remote file explorer', async () => {
    const shell = await shellState();
    return shell?.explorerWatching && shell?.explorerIdentity?.includes(connected.state.workspaceRoot) ? shell : null;
  });
  if (process.env.EXOSUIT_CAPTURE_BROWSER_PATH) {
    const image = await send('Page.captureScreenshot', {format: 'png'});
    fs.writeFileSync(process.env.EXOSUIT_CAPTURE_BROWSER_PATH, Buffer.from(image.data, 'base64'));
  }
  console.log(`PASS: connected Explorer subscribed to ${remoteExplorer.explorerIdentity}`);
  // Open the remote fixture through the rendered Explorer and verify the
  // desktop's single-click preview behavior is wired to authenticated RPC.
  await click(145, 114);
  const remotePreview = await waitFor('remote file preview', async () => {
    const shell = await shellState();
    const file = shell?.workspaceFileTabs?.find(item => item.path === 'remote.md'
      && item.scope === connected.state.workspaceRoot);
    return file?.preview === true && file?.revision && file?.syntax ? file : null;
  }, 20000);
  if (remotePreview.syntax !== 'Markdown')
    throw new Error(`Remote preview used unexpected syntax mode: ${remotePreview.syntax}`);
  console.log('PASS: single-click opened the remote Markdown file as a revision-checked preview tab');
  const rawRecord = await expression(`(async()=>{const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('exosuit-remote-devices-v1');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});const values=await new Promise((resolve,reject)=>{const r=db.transaction('devices','readonly').objectStore('devices').get(${JSON.stringify(`${invitation.machineId}:${invitation.deviceId}`)});r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});const key=await new Promise((resolve,reject)=>{const r=db.transaction('meta','readonly').objectStore('meta').get('noise-device-wrap-v1');r.onsuccess=()=>resolve(r.result?.key);r.onerror=()=>reject(r.error)});return {ciphertextBytes:values?.ciphertext?.byteLength||0,cleartextFields:!!values&&(Object.hasOwn(values,'staticPrivateKey')||Object.hasOwn(values,'deviceToken')),keyExtractable:key?.extractable}})()`);
  if (rawRecord.ciphertextBytes < 32 || rawRecord.cleartextFields || rawRecord.keyExtractable !== false)
    throw new Error(`Browser device storage did not preserve encrypted-at-rest custody: ${JSON.stringify(rawRecord)}`);
  console.log(`PASS: browser reached workspace identity at ${connected.state.workspaceRoot}`);
  console.log('PASS: IndexedDB re-opened the saved device credential; raw record is ciphertext with a non-extractable wrapping key');
  console.log(`PASS: browser received ${connected.state.grants.length} explicitly approved workspace grants`);

  // Drop the active relay WebSocket. The RpcClient must obtain a fresh ticket
  // and Noise channel without another user action.
  const oldConnectCount = await expression(`window.__exosuitTestSockets.filter(socket =>
    socket.url.includes('/connect?') && socket.readyState === WebSocket.OPEN).length`);
  const forcedDrop = await expression(`(()=>{
    const socket = [...window.__exosuitTestSockets].reverse().find(value =>
      value.readyState === WebSocket.OPEN && (value.url.includes('/pair/') || value.url.includes('/connect?')));
    if (!socket) return false;
    socket.close(4000, 'test connection interruption');
    return true;
  })()`);
  if (!forcedDrop) throw new Error('Could not locate the active relay socket to interrupt');
  await waitFor('workspace reconnect state after network loss', async () => {
    const state = await remoteState();
    return state?.connecting && state.status?.includes('Reconnecting') ? state : null;
  }, 20000);
  const automaticReconnect = await waitFor('automatic authenticated workspace reconnect', async () => {
    const state = await remoteState();
    if (state?.error) throw new Error(`Automatic reconnect failed: ${state.error}`);
    return state?.workspaceRoot && !state.connecting ? state : null;
  }, 60000);
  if (automaticReconnect.workspaceRoot !== connected.state.workspaceRoot
    || !automaticReconnect.grants?.includes('workspace.identity')
    || !automaticReconnect.grants?.includes('workspace.read')
    || !automaticReconnect.grants?.includes('workspace.files.read'))
    throw new Error('Automatic reconnect changed workspace identity or approved grants');
  const freshConnectCount = await expression(`window.__exosuitTestSockets.filter(socket =>
    socket.url.includes('/connect?') && socket.readyState === WebSocket.OPEN).length`);
  if (freshConnectCount <= oldConnectCount)
    throw new Error('Workspace recovered without opening a fresh ticketed relay socket');
  const recoveredExplorer = await waitFor('remote Explorer watch after reconnect', async () => {
    const shell = await shellState();
    return shell?.explorerWatching && shell?.explorerIdentity?.includes(automaticReconnect.workspaceRoot)
      ? shell : null;
  });
  if (!recoveredExplorer.explorerWatching)
    throw new Error('Remote Explorer did not restore its workspace watch after reconnect');
  writePrivate(successPath, {machineId: invitation.machineId, deviceId: invitation.deviceId,
    workspaceRoot: automaticReconnect.workspaceRoot});
  console.log('PASS: relay disconnect recovered with a fresh ticket, pinned Noise handshake, workspace grants and Explorer watch');
} finally {
  socket.close();
}
