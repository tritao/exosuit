/** Pure session metadata only: no query(), CLI process, prompt, model, or transcript rewriting. */
import {createInterface} from 'node:readline';
import {realpath} from 'node:fs/promises';
import path from 'node:path';
import {getSessionInfo, renameSession} from '@anthropic-ai/claude-agent-sdk';

const root = await realpath(process.argv[2]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const problem = (code, message) => Object.assign(new Error(message), {code});
async function inspect(params) {
  if (!uuid.test(params.sessionId) || typeof params.cwd !== 'string') throw problem('invalid_request', 'Invalid native session identity');
  const directory = await realpath(params.cwd);
  const relative = path.relative(root, directory);
  if (relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative)) throw problem('invalid_scope', 'Session directory is outside this workspace');
  const info = await getSessionInfo(params.sessionId, {dir: directory});
  if (!info || info.sessionId !== params.sessionId || !info.cwd || await realpath(info.cwd) !== directory) {
    throw problem('unknown_session', 'This native Claude session has not been saved in this workspace yet');
  }
  const name = info.customTitle ?? null;
  if (name !== null && (typeof name !== 'string' || name.length > 2048)) throw problem('invalid_response', 'Native session name exceeds the supported bound');
  return {name, directory};
}
for await (const line of createInterface({input: process.stdin, crlfDelay: Infinity})) {
  let request;
  try {
    if (Buffer.byteLength(line) > 16384) throw problem('invalid_request', 'Metadata request exceeds the limit');
    request = JSON.parse(line);
    if (!Number.isSafeInteger(request.id) || !request.params) throw problem('invalid_request', 'Invalid metadata request');
    const before = await inspect(request.params);
    if (request.method === 'session/name/set') {
      const name = request.params.name;
      if (typeof name !== 'string' || !name.trim() || name !== name.trim() || name.length > 256 || /[\x00-\x1f\x7f]/.test(name)) throw problem('invalid_name', 'Invalid session name');
      if (before.name !== request.params.expected) throw problem('conflict', 'The Claude Code name changed before the rename');
      await renameSession(request.params.sessionId, name, {dir: before.directory});
      const after = await inspect(request.params);
      if (after.name !== name) throw problem('conflict', 'Claude Code changed the name before it could be confirmed');
      process.stdout.write(JSON.stringify({id: request.id, result: {name: after.name}}) + '\n');
    } else if (request.method === 'session/name/read') {
      process.stdout.write(JSON.stringify({id: request.id, result: {name: before.name}}) + '\n');
    } else throw problem('unsupported', 'Unsupported session metadata operation');
  } catch (error) {
    process.stdout.write(JSON.stringify({id: request?.id ?? null, error: {code: -32000, message: (error.code ?? 'metadata_error') + ': ' + error.message}}) + '\n');
  }
}
