import { DurableObject } from "cloudflare:workers";

const MAX_JSON_BYTES = 4 * 1024;
const MAX_FRAME_BYTES = 64 * 1024;
const MAX_PAIRING_TTL_SECONDS = 5 * 60;
const SOCKET_TICKET_TTL_SECONDS = 60;
const MAX_PENDING_PAIRINGS = 8;
const MAX_PENDING_TICKETS_PER_PRINCIPAL = 8;
const MAX_ACTIVE_DEVICES = 128;
const MAX_CONNECTED_CLIENTS = 8;
const FRAME_HEADER_BYTES = 17;

interface Route {
  machineId: string;
  action: string;
  objectId?: string;
}

interface SocketAttachment {
  role: "machine" | "pairing" | "device";
  channelId?: string;
  deviceId?: string;
}

interface PairingRequest {
  channelId: string;
  secret: string;
  ttlSeconds: number;
}

interface DeviceRequest {
  token: string;
}

interface TicketRequest {
  ticket: string;
  expiresInSeconds: number;
}

interface DeviceRow {
  [key: string]: SqlStorageValue;
  token_hash: string | null;
  revoked_at: number | null;
}

interface PairingRow {
  [key: string]: SqlStorageValue;
  secret_hash: string;
  expires_at: number;
}

interface TicketRow {
  [key: string]: SqlStorageValue;
  role: "machine" | "device";
  device_id: string | null;
  expires_at: number;
}

interface JsonRead<T> {
  ok: true;
  value: T;
}

interface JsonReadError {
  ok: false;
  response: Response;
}

const HEX_16_BYTES = /^[0-9a-f]{32}$/;
const HEX_32_BYTES = /^[0-9a-f]{64}$/;

const worker = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const route = parseRoute(new URL(request.url).pathname);
    if (!route) return jsonResponse({ error: "not_found" }, 404);

    const origin = request.headers.get("Origin");
    const isTicketRoute = route.action === "tickets";
    if (request.method === "OPTIONS" && isTicketRoute) {
      return preflightResponse(request, env, origin);
    }

    const browserRequest = route.action === "pairing" ||
      ((route.action === "connect" || isTicketRoute) && origin !== null);
    if ((route.action === "pairing" && !origin) ||
      (browserRequest && !isAllowedOrigin(origin, env))) {
      return jsonResponse({ error: "origin_not_allowed" }, 403);
    }

    const id = env.MACHINE_RELAY.idFromName(route.machineId);
    const stub = env.MACHINE_RELAY.get(id);
    const response = await stub.fetch(request);
    if (isTicketRoute && origin) return addCorsHeaders(response, origin);
    return response;
  },
};

export class MachineRelay extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS machine_credential (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), token_hash TEXT NOT NULL)",
    );
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS pairing (channel_id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, expires_at INTEGER NOT NULL)",
    );
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS device (device_id TEXT PRIMARY KEY, token_hash TEXT, revoked_at INTEGER)",
    );
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS socket_ticket (token_hash TEXT PRIMARY KEY, role TEXT NOT NULL, device_id TEXT, expires_at INTEGER NOT NULL)",
    );
  }

  async fetch(request: Request): Promise<Response> {
    const route = parseRoute(new URL(request.url).pathname);
    if (!route) return jsonResponse({ error: "not_found" }, 404);

    if (route.action === "register" && request.method === "POST") {
      return this.registerMachine(request);
    }

    if (!(await this.authorizeMachine(request))) {
      if (route.action === "connect" && request.headers.has("Authorization")) {
        return jsonResponse({ error: "unauthorized" }, 401);
      }
      if (["pairings", "devices"].includes(route.action)) {
        return jsonResponse({ error: "unauthorized" }, 401);
      }
    }

    switch (route.action) {
      case "pairings":
        if (request.method === "POST") return this.createPairing(request);
        break;
      case "devices":
        if (!route.objectId) break;
        if (request.method === "PUT") return this.registerDevice(request, route.objectId);
        if (request.method === "DELETE") return this.revokeDevice(route.objectId);
        break;
      case "tickets":
        if (request.method === "POST") return this.createSocketTicket(request);
        break;
      case "connect":
        if (request.method === "GET") return this.connectTicket(request);
        break;
      case "pairing":
        if (request.method === "GET") return this.connectPairing(request, route.objectId ?? "");
        break;
      default:
        break;
    }

    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): void {
    const attachment = readAttachment(socket);
    if (!attachment) {
      closeSocket(socket, 1008, "missing connection state");
      return;
    }

    if (typeof message === "string") {
      closeSocket(socket, 1003, "binary frames required");
      return;
    }

    const bytes = new Uint8Array(message);
    if (bytes.byteLength > MAX_FRAME_BYTES) {
      closeSocket(socket, 1009, "frame too large");
      return;
    }
    if (bytes.byteLength < FRAME_HEADER_BYTES || bytes[0] !== 1) {
      closeSocket(socket, 1002, "invalid frame envelope");
      return;
    }

    const channelId = bytesToHex(bytes.subarray(1, FRAME_HEADER_BYTES));
    if (attachment.role !== "machine" && channelId !== attachment.channelId) {
      closeSocket(socket, 1008, "channel mismatch");
      return;
    }

    const destination = this.ctx.getWebSockets().find((candidate) => {
      if (candidate === socket) return false;
      const candidateAttachment = readAttachment(candidate);
      return candidateAttachment?.channelId === channelId &&
        candidateAttachment.role !== "machine";
    });

    if (attachment.role !== "machine") {
      const machine = this.ctx.getWebSockets().find((candidate) => {
        if (candidate === socket) return false;
        return readAttachment(candidate)?.role === "machine";
      });
      if (!machine) return;
      sendFrame(machine, bytes);
      return;
    }

    if (destination) sendFrame(destination, bytes);
  }

  webSocketError(socket: WebSocket): void {
    closeSocket(socket, 1011, "relay socket error");
  }

  private async registerMachine(request: Request): Promise<Response> {
    const token = readBearer(request);
    if (!token) return jsonResponse({ error: "invalid_credential" }, 401);
    const tokenHash = await sha256Hex(token);
    const existing = this.ctx.storage.sql.exec<{ token_hash: string }>(
      "SELECT token_hash FROM machine_credential WHERE singleton = 1",
    ).toArray()[0];

    if (!existing) {
      this.ctx.storage.sql.exec(
        "INSERT INTO machine_credential (singleton, token_hash) VALUES (1, ?)",
        tokenHash,
      );
      return jsonResponse({ registered: true }, 201);
    }

    if (!constantTimeEqual(existing.token_hash, tokenHash)) {
      return jsonResponse({ error: "machine_already_registered" }, 409);
    }
    return emptyResponse(204);
  }

  private async authorizeMachine(request: Request): Promise<boolean> {
    const token = readBearer(request);
    if (!token) return false;
    const tokenHash = await sha256Hex(token);
    const row = this.ctx.storage.sql.exec<{ token_hash: string }>(
      "SELECT token_hash FROM machine_credential WHERE singleton = 1",
    ).toArray()[0];
    return !!row && constantTimeEqual(row.token_hash, tokenHash);
  }

  private async createPairing(request: Request): Promise<Response> {
    const parsed = await readJson<PairingRequest>(request);
    if (!parsed.ok) return parsed.response;
    const { channelId, secret, ttlSeconds } = parsed.value;
    if (!isHexId(channelId) || !isHexSecret(secret) || !Number.isInteger(ttlSeconds) ||
      ttlSeconds < 1 || ttlSeconds > MAX_PAIRING_TTL_SECONDS) {
      return jsonResponse({ error: "invalid_pairing" }, 400);
    }

    const secretHash = await sha256Hex(secret);
    const now = Date.now();
    this.ctx.storage.sql.exec("DELETE FROM pairing WHERE expires_at <= ?", now);
    const count = this.ctx.storage.sql.exec<{ total: number }>(
      "SELECT COUNT(*) AS total FROM pairing",
    ).toArray()[0]?.total ?? 0;
    if (count >= MAX_PENDING_PAIRINGS) {
      return jsonResponse({ error: "pairing_limit" }, 429);
    }

    const existing = this.ctx.storage.sql.exec<{ channel_id: string }>(
      "SELECT channel_id FROM pairing WHERE channel_id = ?",
      channelId,
    ).toArray()[0];
    if (existing) return jsonResponse({ error: "channel_already_exists" }, 409);
    this.ctx.storage.sql.exec(
      "INSERT INTO pairing (channel_id, secret_hash, expires_at) VALUES (?, ?, ?)",
      channelId,
      secretHash,
      now + ttlSeconds * 1000,
    );
    return jsonResponse({ expiresInSeconds: ttlSeconds }, 201);
  }

  private async registerDevice(request: Request, deviceId: string): Promise<Response> {
    if (!isHexId(deviceId)) return jsonResponse({ error: "invalid_device_id" }, 400);
    const parsed = await readJson<DeviceRequest>(request);
    if (!parsed.ok) return parsed.response;
    if (!isHexSecret(parsed.value.token)) return jsonResponse({ error: "invalid_device" }, 400);

    const tokenHash = await sha256Hex(parsed.value.token);
    const current = this.ctx.storage.sql.exec<DeviceRow>(
      "SELECT token_hash, revoked_at FROM device WHERE device_id = ?",
      deviceId,
    ).toArray()[0];
    if (current) {
      if (current.revoked_at !== null || current.token_hash === null) {
        return jsonResponse({ error: "device_revoked" }, 410);
      }
      return constantTimeEqual(current.token_hash, tokenHash)
        ? emptyResponse(204)
        : jsonResponse({ error: "device_already_registered" }, 409);
    }

    const duplicate = this.ctx.storage.sql.exec<{ device_id: string }>(
      "SELECT device_id FROM device WHERE token_hash = ? AND revoked_at IS NULL",
      tokenHash,
    ).toArray()[0];
    if (duplicate) return jsonResponse({ error: "credential_already_registered" }, 409);

    const count = this.ctx.storage.sql.exec<{ total: number }>(
      "SELECT COUNT(*) AS total FROM device WHERE revoked_at IS NULL",
    ).toArray()[0]?.total ?? 0;
    if (count >= MAX_ACTIVE_DEVICES) return jsonResponse({ error: "device_limit" }, 429);

    this.ctx.storage.sql.exec(
      "INSERT INTO device (device_id, token_hash, revoked_at) VALUES (?, ?, NULL)",
      deviceId,
      tokenHash,
    );
    return jsonResponse({ registered: true }, 201);
  }

  private revokeDevice(deviceId: string): Response {
    if (!isHexId(deviceId)) return jsonResponse({ error: "invalid_device_id" }, 400);
    const result = this.ctx.storage.sql.exec(
      "UPDATE device SET token_hash = NULL, revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL",
      Date.now(),
      deviceId,
    );
    if (result.rowsWritten === 0) return jsonResponse({ error: "device_not_found" }, 404);

    this.ctx.storage.sql.exec("DELETE FROM socket_ticket WHERE device_id = ?", deviceId);
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = readAttachment(socket);
      if (attachment?.deviceId === deviceId) closeSocket(socket, 1008, "device revoked");
    }
    return emptyResponse(204);
  }

  private async createSocketTicket(request: Request): Promise<Response> {
    const token = readBearer(request);
    if (!token) return jsonResponse({ error: "unauthorized" }, 401);
    const tokenHash = await sha256Hex(token);
    const machine = this.ctx.storage.sql.exec<{ token_hash: string }>(
      "SELECT token_hash FROM machine_credential WHERE singleton = 1",
    ).toArray()[0];
    let role: "machine" | "device";
    let deviceId: string | null = null;
    if (machine && constantTimeEqual(machine.token_hash, tokenHash)) {
      role = "machine";
    } else {
      const device = this.ctx.storage.sql.exec<{ device_id: string }>(
      "SELECT device_id FROM device WHERE token_hash = ? AND revoked_at IS NULL",
      tokenHash,
      ).toArray()[0];
      if (!device) return jsonResponse({ error: "unauthorized" }, 401);
      role = "device";
      deviceId = device.device_id;
    }

    const rawTicket = randomHex(32);
    const ticketHash = await sha256Hex(rawTicket);
    const expiresAt = Date.now() + SOCKET_TICKET_TTL_SECONDS * 1000;
    this.ctx.storage.sql.exec("DELETE FROM socket_ticket WHERE expires_at <= ?", Date.now());
    const pendingCount = role === "machine"
      ? this.ctx.storage.sql.exec<{ total: number }>(
        "SELECT COUNT(*) AS total FROM socket_ticket WHERE role = 'machine'",
      ).toArray()[0]?.total ?? 0
      : this.ctx.storage.sql.exec<{ total: number }>(
        "SELECT COUNT(*) AS total FROM socket_ticket WHERE device_id = ?",
        deviceId,
      ).toArray()[0]?.total ?? 0;
    if (pendingCount >= MAX_PENDING_TICKETS_PER_PRINCIPAL) {
      return jsonResponse({ error: "ticket_limit" }, 429);
    }
    this.ctx.storage.sql.exec(
      "INSERT INTO socket_ticket (token_hash, role, device_id, expires_at) VALUES (?, ?, ?, ?)",
      ticketHash,
      role,
      deviceId,
      expiresAt,
    );
    return jsonResponse({ ticket: rawTicket, expiresInSeconds: SOCKET_TICKET_TTL_SECONDS }, 201);
  }

  private async connectPairing(request: Request, channelId: string): Promise<Response> {
    if (!isHexId(channelId)) return jsonResponse({ error: "invalid_channel_id" }, 400);
    if (!isWebSocketUpgrade(request)) return jsonResponse({ error: "websocket_required" }, 426);

    const secret = new URL(request.url).searchParams.get("secret");
    if (!secret || !isHexSecret(secret)) return jsonResponse({ error: "invalid_invitation" }, 401);
    const secretHash = await sha256Hex(secret);
    const row = this.ctx.storage.sql.exec<PairingRow>(
      "SELECT secret_hash, expires_at FROM pairing WHERE channel_id = ?",
      channelId,
    ).toArray()[0];
    if (!row || row.expires_at <= Date.now() || !constantTimeEqual(row.secret_hash, secretHash)) {
      return jsonResponse({ error: "invalid_invitation" }, 401);
    }
    if (!this.hasMachineSocket()) return jsonResponse({ error: "machine_offline" }, 503);

    return this.acceptConnection(request, { role: "pairing", channelId }, () => {
      this.ctx.storage.sql.exec("DELETE FROM pairing WHERE channel_id = ?", channelId);
    });
  }

  private async connectTicket(request: Request): Promise<Response> {
    if (!isWebSocketUpgrade(request)) return jsonResponse({ error: "websocket_required" }, 426);
    const rawTicket = new URL(request.url).searchParams.get("ticket");
    if (!rawTicket || !isHexSecret(rawTicket)) return jsonResponse({ error: "invalid_ticket" }, 401);
    const ticketHash = await sha256Hex(rawTicket);
    const ticket = this.ctx.storage.sql.exec<TicketRow>(
      "SELECT role, device_id, expires_at FROM socket_ticket WHERE token_hash = ?",
      ticketHash,
    ).toArray()[0];
    if (!ticket || ticket.expires_at <= Date.now()) {
      if (ticket) this.ctx.storage.sql.exec("DELETE FROM socket_ticket WHERE token_hash = ?", ticketHash);
      return jsonResponse({ error: "invalid_ticket" }, 401);
    }

    if (ticket.role === "machine") {
      return this.acceptConnection(request, { role: "machine" }, () => {
        this.ctx.storage.sql.exec("DELETE FROM socket_ticket WHERE token_hash = ?", ticketHash);
      });
    }

    if (!this.hasMachineSocket()) return jsonResponse({ error: "machine_offline" }, 503);
    if (!ticket.device_id) return jsonResponse({ error: "invalid_ticket" }, 401);
    const device = this.ctx.storage.sql.exec<{ token_hash: string | null; revoked_at: number | null }>(
      "SELECT token_hash, revoked_at FROM device WHERE device_id = ?",
      ticket.device_id,
    ).toArray()[0];
    if (!device || device.revoked_at !== null || device.token_hash === null) {
      this.ctx.storage.sql.exec("DELETE FROM socket_ticket WHERE token_hash = ?", ticketHash);
      return jsonResponse({ error: "device_revoked" }, 401);
    }

    return this.acceptConnection(request, {
      role: "device",
      deviceId: ticket.device_id,
      channelId: ticket.device_id,
    }, () => {
      this.ctx.storage.sql.exec("DELETE FROM socket_ticket WHERE token_hash = ?", ticketHash);
    });
  }

  private acceptConnection(
    request: Request,
    attachment: SocketAttachment,
    beforeAccept?: () => void,
  ): Response {
    const sockets = this.ctx.getWebSockets();
    const existing = sockets.filter((socket) => {
      const current = readAttachment(socket);
      if (!current) return false;
      if (attachment.role === "machine") return current.role === "machine";
      return current.role !== "machine" && current.channelId === attachment.channelId;
    });

    if (attachment.role === "pairing" && existing.length > 0) {
      return jsonResponse({ error: "channel_already_connected" }, 409);
    }
    if (attachment.role === "machine") {
      for (const socket of existing) closeSocket(socket, 1012, "machine reconnected");
    }
    if (attachment.role === "device" && existing.length > 0) {
      for (const socket of existing) closeSocket(socket, 1012, "device reconnected");
    }

    const clientCount = sockets.filter((socket) => {
      const current = readAttachment(socket);
      return current?.role === "pairing" || current?.role === "device";
    }).length - existing.length;
    if (attachment.role !== "machine" && clientCount >= MAX_CONNECTED_CLIENTS) {
      return jsonResponse({ error: "connection_limit" }, 429);
    }

    beforeAccept?.();
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(attachment);
    return new Response(null, { status: 101, webSocket: client });
  }

  private hasMachineSocket(): boolean {
    return this.ctx.getWebSockets().some((socket) => readAttachment(socket)?.role === "machine");
  }
}

function parseRoute(pathname: string): Route | null {
  const parts = pathname.split("/").filter(Boolean);
  if (parts.length < 3 || parts[0] !== "v1" || parts[1] !== "machines" || !isHexId(parts[2])) {
    return null;
  }
  if (parts.length === 4 && parts[3] === "register") {
    return { machineId: parts[2], action: "register" };
  }
  if (parts.length === 4 && parts[3] === "pairings") {
    return { machineId: parts[2], action: "pairings" };
  }
  if (parts.length === 4 && parts[3] === "tickets") {
    return { machineId: parts[2], action: "tickets" };
  }
  if (parts.length === 4 && parts[3] === "connect") {
    return { machineId: parts[2], action: "connect" };
  }
  if (parts.length === 5 && parts[3] === "pair") {
    return { machineId: parts[2], action: "pairing", objectId: parts[4] };
  }
  if (parts.length === 5 && parts[3] === "devices") {
    return { machineId: parts[2], action: "devices", objectId: parts[4] };
  }
  return null;
}

function isAllowedOrigin(origin: string | null, env: Env): boolean {
  if (!origin) return false;
  const allowed = (env.ALLOWED_ORIGINS ?? "").split(",").map((item) => item.trim()).filter(Boolean);
  return allowed.includes(origin);
}

function preflightResponse(request: Request, env: Env, origin: string | null): Response {
  if (!isAllowedOrigin(origin, env)) return jsonResponse({ error: "origin_not_allowed" }, 403);
  const method = request.headers.get("Access-Control-Request-Method");
  const headers = request.headers.get("Access-Control-Request-Headers")?.toLowerCase() ?? "";
  if (method !== "POST" || headers.split(/\s*,\s*/).some((header) =>
    header !== "authorization" && header !== "content-type")) {
    return jsonResponse({ error: "preflight_not_allowed" }, 403);
  }
  return new Response(null, {
    status: 204,
    headers: corsHeaders(origin!),
  });
}

function addCorsHeaders(response: Response, origin: string): Response {
  const headers = new Headers(response.headers);
  corsHeaders(origin).forEach((value, name) => headers.set(name, value));
  headers.set("Cache-Control", "no-store");
  return new Response(response.body, { status: response.status, headers });
}

function corsHeaders(origin: string): Headers {
  return new Headers({
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
    "Access-Control-Max-Age": "300",
    "Vary": "Origin",
  });
}

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function emptyResponse(status: number): Response {
  return new Response(null, { status, headers: { "Cache-Control": "no-store" } });
}

function readBearer(request: Request): string | null {
  const value = request.headers.get("Authorization");
  const match = value?.match(/^Bearer ([0-9a-f]{64})$/i);
  return match?.[1].toLowerCase() ?? null;
}

function isHexId(value: string): boolean {
  return HEX_16_BYTES.test(value);
}

function isHexSecret(value: string): boolean {
  return HEX_32_BYTES.test(value);
}

function isWebSocketUpgrade(request: Request): boolean {
  return request.headers.get("Upgrade")?.toLowerCase() === "websocket";
}

async function readJson<T>(request: Request): Promise<JsonRead<T> | JsonReadError> {
  const mediaType = (request.headers.get("Content-Type") ?? "").split(";", 1)[0].trim().toLowerCase();
  if (mediaType !== "application/json") {
    return { ok: false, response: jsonResponse({ error: "json_required" }, 415) };
  }
  if (!request.body) return { ok: false, response: jsonResponse({ error: "invalid_json" }, 400) };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > MAX_JSON_BYTES) {
        await reader.cancel();
        return { ok: false, response: jsonResponse({ error: "body_too_large" }, 413) };
      }
      chunks.push(value);
    }
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_json" }, 400) };
  }

  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      return { ok: false, response: jsonResponse({ error: "json_object_required" }, 400) };
    }
    return { ok: true, value: value as T };
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_json" }, 400) };
  }
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return bytesToHex(new Uint8Array(digest));
}

function constantTimeEqual(left: string, right: string): boolean {
  const maxLength = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < maxLength; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

function randomHex(bytes: number): string {
  const random = new Uint8Array(bytes);
  crypto.getRandomValues(random);
  return bytesToHex(random);
}

function bytesToHex(bytes: Uint8Array): string {
  let result = "";
  for (const byte of bytes) result += byte.toString(16).padStart(2, "0");
  return result;
}

function readAttachment(socket: WebSocket): SocketAttachment | null {
  try {
    const value = socket.deserializeAttachment() as SocketAttachment | null;
    if (!value || !["machine", "pairing", "device"].includes(value.role)) return null;
    return value;
  } catch {
    return null;
  }
}

function closeSocket(socket: WebSocket, code: number, reason: string): void {
  try {
    socket.close(code, reason);
  } catch {
    // The peer may have disconnected between enumeration and close.
  }
}

function sendFrame(socket: WebSocket, bytes: Uint8Array): void {
  try {
    socket.send(bytes);
  } catch {
    closeSocket(socket, 1011, "relay delivery failed");
  }
}

export default worker;
