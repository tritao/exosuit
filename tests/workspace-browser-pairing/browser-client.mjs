import fs from 'node:fs';

const [invitePath, statusPath, decisionPath, successPath] = process.argv.slice(2);
if (!invitePath || !statusPath || !decisionPath || !successPath) throw new Error('Expected invite, status, decision and success files');
const chrome = `http://127.0.0.1:${process.env.EXOSUIT_CDP_PORT || 9224}`;
const appOrigin = `http://localhost:${process.env.EXOSUIT_APP_PORT || 5173}`;
const targetResponse = await fetch(`${chrome}/json/new?${appOrigin}/`, {method: 'PUT'});
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
  const rawRecord = await expression(`(async()=>{const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('exosuit-remote-devices-v1');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});const values=await new Promise((resolve,reject)=>{const r=db.transaction('devices','readonly').objectStore('devices').get(${JSON.stringify(`${invitation.machineId}:${invitation.deviceId}`)});r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});const key=await new Promise((resolve,reject)=>{const r=db.transaction('meta','readonly').objectStore('meta').get('noise-device-wrap-v1');r.onsuccess=()=>resolve(r.result?.key);r.onerror=()=>reject(r.error)});return {ciphertextBytes:values?.ciphertext?.byteLength||0,cleartextFields:!!values&&(Object.hasOwn(values,'staticPrivateKey')||Object.hasOwn(values,'deviceToken')),keyExtractable:key?.extractable}})()`);
  if (rawRecord.ciphertextBytes < 32 || rawRecord.cleartextFields || rawRecord.keyExtractable !== false)
    throw new Error(`Browser device storage did not preserve encrypted-at-rest custody: ${JSON.stringify(rawRecord)}`);
  console.log(`PASS: browser reached workspace identity at ${connected.state.workspaceRoot}`);
  console.log('PASS: IndexedDB re-opened the saved device credential; raw record is ciphertext with a non-extractable wrapping key');
  console.log(`PASS: browser received ${connected.state.grants.length} explicitly approved workspace grants`);

  // Disconnect through the panel, select the saved device and establish a new ticketed Noise channel.
  await pause(500);
  await click(28, 160); // Return from the connected Files view to Remote Access.
  await pause(300);
  await click(120, 508); // Disconnect button after the optional file-read grant row.
  const disconnected = await waitFor('saved device after disconnect', async () => {
    const state = await remoteState();
    const device = state?.savedDevices?.find(item => item.machineId === invitation.machineId
      && item.deviceId === invitation.deviceId && item.relayOrigin === connected.relayOrigin);
    return state?.workspaceRoot == null && device ? {state, device} : null;
  });
  await click(120, 370);
  const reconnected = await waitFor('saved-device authenticated reconnect', async () => {
    const state = await remoteState();
    if (state?.error) throw new Error(`Saved-device reconnect failed: ${state.error}`);
    return state?.workspaceRoot ? state : null;
  });
  if (reconnected.workspaceRoot !== connected.state.workspaceRoot
    || !reconnected.grants?.includes('workspace.identity') || !reconnected.grants?.includes('workspace.read')
    || !reconnected.grants?.includes('workspace.files.read'))
    throw new Error('Saved-device reconnect changed workspace identity or approved grants');
  writePrivate(successPath, {machineId: invitation.machineId, deviceId: invitation.deviceId,
    workspaceRoot: reconnected.workspaceRoot});
  console.log('PASS: saved browser device obtained a fresh ticket and reconnected with its pinned machine identity');
} finally {
  socket.close();
}
