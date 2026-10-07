import fs from 'node:fs';

const [invitePath, statusPath, decisionPath, successPath, fileChangePath] = process.argv.slice(2);
if (!invitePath || !statusPath || !decisionPath || !successPath || !fileChangePath)
  throw new Error('Expected invite, status, decision, success and file-change files');
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
    if (app?.state === 'failed') {
      const hostError = await expression('window.exosuit.document?.hostError');
      throw new Error(`Browser app failed: ${app.error}\n${JSON.stringify(hostError)}\n${browserDiagnostics.join('\n')}`);
    }
    await pause(200);
  }
  const shell = await shellState().catch(() => null);
  throw new Error(`Timed out waiting for ${description}: ${JSON.stringify({value, shell})}`);
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
  const agentMode = process.env.EXOSUIT_TEST_AGENT === '1';
  if (agentMode && (!connected.state.grants?.includes('workspace.groups.tree')
    || !connected.state.grants?.includes('workspace.terminals.read')
    || !connected.state.grants?.includes('workspace.terminals.catalog')
    || !connected.state.grants?.includes('workspace.terminals.control')
    || !connected.state.grants?.includes('workspace.agents.read')
    || !connected.state.grants?.includes('workspace.agents.control')))
    throw new Error('AgentMain browser did not receive the approved Workbench and Codex grants');
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
  let remotePreview = null;
  for (let attempt = 0; attempt < 8 && remotePreview == null; attempt++) {
    await click(145, 114);
    await pause(350);
    const shell = await shellState();
    remotePreview = shell?.workspaceFileTabs?.find(item => item.path === 'remote.md'
      && item.scope === connected.state.workspaceRoot && item.preview === true && item.revision && item.syntax) || null;
  }
  if (remotePreview == null)
    remotePreview = await waitFor('remote file preview', async () => {
      const shell = await shellState();
      const file = shell?.workspaceFileTabs?.find(item => item.path === 'remote.md'
        && item.scope === connected.state.workspaceRoot);
      return file?.preview === true && file?.revision && file?.syntax ? file : null;
    }, 12000);
  if (remotePreview.syntax !== 'Markdown')
    throw new Error(`Remote preview used unexpected syntax mode: ${remotePreview.syntax}`);
  console.log('PASS: single-click opened the remote Markdown file as a revision-checked preview tab');
  if (agentMode) {
    const previewRevision = remotePreview.revision;
    writePrivate(fileChangePath, {requestId: 'browser-file-change-v1'});
    const stalePreview = await waitFor('AgentMain file-change notification in the browser preview', async () => {
      const shell = await shellState();
      return shell?.workspaceFileTabs?.find(item => item.path === 'remote.md'
        && item.scope === connected.state.workspaceRoot && item.preview === true && item.diskChanged) || null;
    }, 15000);
    if (stalePreview.revision !== previewRevision)
      throw new Error('Remote file notification replaced the browser preview snapshot before explicit refresh');
    console.log('PASS: AgentMain file change reached the browser and marked the saved preview stale');
  }
  let remoteTerminalId = null;
  let remoteAgentId = null;
  let remoteAgentThread = null;
  if (agentMode) {
    await click(30, 160); // Workbench activity-rail icon.
    await pause(120);
    const selectedWorkbench = (await shellState())?.sidebarMode === 'workbench';
    if (!selectedWorkbench) throw new Error('Could not select the connected Workbench from the activity rail');
    console.log('PASS: connected Workbench selected');
    const readyWorkbench = await waitFor('remote terminal catalog', async () => {
      const shell = await shellState();
      return shell?.terminalCatalog?.groups?.some(group => group.id === 'work') ? shell : null;
    }, 20000);
    console.log('PASS: remote terminal catalog loaded');
    await click(74, 90); // Workbench's New terminal action for its selected Work group.
    const openedTerminal = await waitFor('remote terminal tab', async () => {
      const shell = await shellState();
      return shell?.terminalResourceIds?.length === 1 && shell?.terminalIds?.length === 1
        && shell?.terminal !== 'closed' && shell?.terminalColumns > 0
        && shell?.panels?.includes('terminal') ? shell : null;
    }, 30000);
    remoteTerminalId = openedTerminal.terminalResourceIds[0];
    if (remoteTerminalId == null || remoteTerminalId.length === 0)
      throw new Error('Remote terminal tab did not retain a stable session id');
    console.log('PASS: Workbench opened a controlled terminal session from the remote workspace group');

    const beforeCodex = await shellState();
    const createCodex = beforeCodex?.testTargets?.newCodex;
    if (!createCodex || createCodex.width <= 0 || createCodex.height <= 0)
      throw new Error(`New Codex action is not available: ${JSON.stringify(beforeCodex?.testTargets)}`);
    await click(createCodex.x + createCodex.width / 2, createCodex.y + createCodex.height / 2);
    const openCodex = await waitFor('connected Codex session', async () => {
      const shell = await shellState();
      const record = shell?.agentCatalog?.records?.find(value => shell.agentTabs?.includes(value.id));
      const summary = shell?.activeAgentSummary;
      const prompt = shell?.testTargets?.prompt;
      return record && summary?.id === record.id && summary.thread
        && prompt?.width > 0 && prompt?.height > 0 ? {shell, record, summary} : null;
    }, 60000);
    remoteAgentId = openCodex.record.id;
    remoteAgentThread = openCodex.record.thread;
    if (openCodex.record.workspaceRoot !== connected.state.workspaceRoot)
      throw new Error('Created Codex session is outside the approved workspace');

    const initialPrompt = openCodex.shell.testTargets?.prompt;
    if (!initialPrompt || initialPrompt.width <= 0 || initialPrompt.height <= 0)
      throw new Error(`Codex prompt field is not visible: ${JSON.stringify(openCodex.shell.testTargets)}`);
    await click(initialPrompt.x + initialPrompt.width / 2, initialPrompt.y + initialPrompt.height / 2);
    await send('Input.insertText', {text: 'browser'});
    const sendPrompt = (await shellState())?.testTargets?.send;
    if (!sendPrompt || sendPrompt.width <= 0 || sendPrompt.height <= 0)
      throw new Error('Codex Send prompt action is not visible');
    await click(sendPrompt.x + sendPrompt.width / 2, sendPrompt.y + sendPrompt.height / 2);
    await waitFor('Codex command approval in the browser session', async () => {
      const shell = await shellState();
      const summary = shell?.activeAgentSummary;
      return ['working', 'needs-attention'].includes(summary?.state)
        && summary.messageCount > 0
        && summary.requestMethods?.includes('item/commandExecution/requestApproval')
        ? {shell, summary} : null;
    }, 30000);
    const approvalWithTarget = await waitFor('visible Codex approval action', async () => {
      const shell = await shellState();
      const target = shell?.testTargets?.approve;
      return target?.width > 0 && target?.height > 0 ? {shell, target} : null;
    }, 10000);
    const approve = approvalWithTarget.target;
    if (!approve || approve.width <= 0 || approve.height <= 0)
      throw new Error(`Codex approval action is not visible: ${JSON.stringify(approval.shell.testTargets)}`);
    await click(approve.x + approve.width / 2, approve.y + approve.height / 2);
    await waitFor('Codex input request after approval', async () => {
      const shell = await shellState();
      return shell?.activeAgentSummary?.requestMethods?.includes('item/tool/requestUserInput') ? shell : null;
    }, 15000);
    const answerControls = await waitFor('visible Codex answer controls', async () => {
      const shell = await shellState();
      const prompt = shell?.testTargets?.prompt;
      const answer = shell?.testTargets?.answer;
      return prompt?.width > 0 && answer?.width > 0 ? {shell, prompt, answer} : null;
    }, 10000);
    const answerField = answerControls.prompt;
    const answerAction = answerControls.answer;
    if (!answerField || !answerAction || answerField.width <= 0 || answerAction.width <= 0)
      throw new Error(`Codex input controls are not visible: ${JSON.stringify(answerControls.shell.testTargets)}`);
    await click(answerField.x + answerField.width / 2, answerField.y + answerField.height / 2);
    await send('Input.insertText', {text: 'choice=yes'});
    await click(answerAction.x + answerAction.width / 2, answerAction.y + answerAction.height / 2);
    const answered = await waitFor('completed Codex session', async () => {
      const shell = await shellState();
      return shell?.activeAgentSummary?.state === 'completed' ? shell : null;
    }, 15000);
    if (answered.activeAgentSummary.messageCount < 2)
      throw new Error('Browser Codex conversation did not retain the streamed assistant activity');
    console.log('PASS: browser sent a Codex prompt, approved a command, answered an input request and received streamed activity');
  }
  const rawRecord = await expression(`(async()=>{const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('exosuit-remote-devices-v1');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});const values=await new Promise((resolve,reject)=>{const r=db.transaction('devices','readonly').objectStore('devices').get(${JSON.stringify(`${invitation.machineId}:${invitation.deviceId}`)});r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});const key=await new Promise((resolve,reject)=>{const r=db.transaction('meta','readonly').objectStore('meta').get('noise-device-wrap-v1');r.onsuccess=()=>resolve(r.result?.key);r.onerror=()=>reject(r.error)});return {ciphertextBytes:values?.ciphertext?.byteLength||0,cleartextFields:!!values&&(Object.hasOwn(values,'staticPrivateKey')||Object.hasOwn(values,'deviceToken')),keyExtractable:key?.extractable}})()`);
  if (rawRecord.ciphertextBytes < 32 || rawRecord.cleartextFields || rawRecord.keyExtractable !== false)
    throw new Error(`Browser device storage did not preserve encrypted-at-rest custody: ${JSON.stringify(rawRecord)}`);
  console.log(`PASS: browser reached workspace identity at ${connected.state.workspaceRoot}`);
  console.log('PASS: IndexedDB re-opened the saved device credential; raw record is ciphertext with a non-extractable wrapping key');
  console.log(`PASS: browser received ${connected.state.grants.length} explicitly approved workspace grants`);

  // Drop the active relay WebSocket. The RpcClient must obtain a fresh ticket
  // and Noise channel without another user action.
  const oldConnectCount = await expression(`window.__exosuitTestSockets.filter(socket =>
    socket.url.includes('/connect')).length`);
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
  if (agentMode && (!automaticReconnect.grants?.includes('workspace.terminals.read')
    || !automaticReconnect.grants?.includes('workspace.terminals.catalog')
    || !automaticReconnect.grants?.includes('workspace.terminals.control')
    || !automaticReconnect.grants?.includes('workspace.agents.read')
    || !automaticReconnect.grants?.includes('workspace.agents.control')))
    throw new Error('Automatic reconnect changed the approved Workbench or Codex grants');
  const freshConnectCount = await expression(`window.__exosuitTestSockets.filter(socket =>
    socket.url.includes('/connect')).length`);
  if (freshConnectCount <= oldConnectCount)
    throw new Error(`Workspace recovered without opening a fresh ticketed relay socket (${oldConnectCount} before, ${freshConnectCount} after)`);
  const recoveredExplorer = await waitFor('remote Explorer watch after reconnect', async () => {
    const shell = await shellState();
    return shell?.explorerWatching && shell?.explorerIdentity?.includes(automaticReconnect.workspaceRoot)
      ? shell : null;
  });
  if (!recoveredExplorer.explorerWatching)
    throw new Error('Remote Explorer did not restore its workspace watch after reconnect');
  if (agentMode) {
    const resumedTerminal = await waitFor('remote terminal after reconnect', async () => {
      const shell = await shellState();
      return shell?.terminalResourceIds?.includes(remoteTerminalId) && shell?.terminal !== 'closed' ? shell : null;
    });
    if (!resumedTerminal.terminalResourceIds.includes(remoteTerminalId))
      throw new Error('Remote terminal tab lost its stable session id after reconnect');
    console.log('PASS: remote terminal tab reattached to the same session after relay reconnect');
    const resumedAgent = await waitFor('Codex session after relay reconnect', async () => {
      const shell = await shellState();
      return shell?.activeAgentSummary?.thread === remoteAgentThread
        && shell.activeAgentSummary.workspaceRoot === connected.state.workspaceRoot ? shell : null;
    });
    if (!resumedAgent.agentTabs.includes(remoteAgentId))
      throw new Error('Codex tab lost its stable workspace resource after relay reconnect');
    console.log('PASS: Codex tab reattached to the same workspace session after relay reconnect');
  }
  writePrivate(successPath, {machineId: invitation.machineId, deviceId: invitation.deviceId,
    workspaceRoot: automaticReconnect.workspaceRoot});
  console.log('PASS: relay disconnect recovered with a fresh ticket, pinned Noise handshake, workspace grants and Explorer watch');
} finally {
  socket.close();
}
