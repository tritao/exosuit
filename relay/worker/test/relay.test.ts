import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it } from "vitest";
import worker from "../src/index";

const ORIGIN = "https://client.test";
const sockets: WebSocket[] = [];
let machineSequence = 0;

afterEach(() => {
  for (const socket of sockets.splice(0)) {
    try {
      socket.close(1000, "test cleanup");
    } catch {
      // Ignore sockets already closed by the test.
    }
  }
});

describe("machine enrollment and browser origin checks", () => {
  it("enrolls one machine credential and rejects a different claimant", async () => {
    const id = nextMachineId();
    const ownerToken = secret(1);
    const otherToken = secret(2);

    const first = await call(id, "register", {
      method: "POST",
      headers: bearer(ownerToken),
    });
    expect(first.status).toBe(201);

    const repeat = await call(id, "register", {
      method: "POST",
      headers: bearer(ownerToken),
    });
    expect(repeat.status).toBe(204);

    const claimant = await call(id, "register", {
      method: "POST",
      headers: bearer(otherToken),
    });
    expect(claimant.status).toBe(409);
  });

  it("requires an allowed browser origin for ticket exchange and preflight", async () => {
    const id = nextMachineId();
    const noOrigin = await call(id, "tickets", {
      method: "POST",
      headers: bearer(secret(3)),
      body: JSON.stringify({}),
    });
    expect(noOrigin.status).toBe(403);

    const wrongOrigin = await call(id, "tickets", {
      method: "POST",
      headers: { ...bearer(secret(3)), Origin: "https://other.test" },
      body: JSON.stringify({}),
    });
    expect(wrongOrigin.status).toBe(403);

    const preflight = await call(id, "tickets", {
      method: "OPTIONS",
      headers: {
        Origin: ORIGIN,
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "authorization, content-type",
      },
    });
    expect(preflight.status).toBe(204);
    expect(preflight.headers.get("Access-Control-Allow-Origin")).toBe(ORIGIN);
  });

  it("keeps browser credentials and invitations out of response caching", async () => {
    const id = nextMachineId();
    const machineToken = secret(4);
    await registerMachine(id, machineToken);
    const response = await call(id, "pairings", {
      method: "POST",
      headers: jsonHeaders(machineToken),
      body: JSON.stringify({ channelId: idFromNumber(900), secret: secret(5), ttlSeconds: 60 }),
    });
    expect(response.status).toBe(201);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
  });

  it("bounds the number of unconsumed pairing invitations", async () => {
    const id = nextMachineId();
    const machineToken = secret(20);
    await registerMachine(id, machineToken);

    for (let index = 0; index < 8; index += 1) {
      await createPairing(id, machineToken, idFromNumber(1000 + index), secret(21 + index), 60);
    }
    const overflow = await call(id, "pairings", {
      method: "POST",
      headers: jsonHeaders(machineToken),
      body: JSON.stringify({ channelId: idFromNumber(1100), secret: secret(31), ttlSeconds: 60 }),
    });
    expect(overflow.status).toBe(429);
  });
});

describe("single-use pairing and device tickets", () => {
  it("does not consume a valid pairing invitation while the machine is offline", async () => {
    const id = nextMachineId();
    const machineToken = secret(6);
    const channelId = idFromNumber(901);
    const inviteSecret = secret(7);
    await registerMachine(id, machineToken);
    await createPairing(id, machineToken, channelId, inviteSecret, 60);

    const offline = await connectPairing(id, channelId, inviteSecret);
    expect(offline.status).toBe(503);

    await openMachine(id, machineToken);
    const connected = await connectPairing(id, channelId, inviteSecret);
    expect(connected.status).toBe(101);
    socketOf(connected);

    const replay = await connectPairing(id, channelId, inviteSecret);
    expect(replay.status).toBe(401);
  });

  it("expires pairing invitations and rejects invalid lifetimes", async () => {
    const id = nextMachineId();
    const machineToken = secret(8);
    const channelId = idFromNumber(902);
    const inviteSecret = secret(9);
    await registerMachine(id, machineToken);
    await openMachine(id, machineToken);

    const invalidLifetime = await call(id, "pairings", {
      method: "POST",
      headers: jsonHeaders(machineToken),
      body: JSON.stringify({ channelId, secret: inviteSecret, ttlSeconds: 301 }),
    });
    expect(invalidLifetime.status).toBe(400);

    await createPairing(id, machineToken, channelId, inviteSecret, 1);
    await new Promise((resolve) => setTimeout(resolve, 1100));
    const expired = await connectPairing(id, channelId, inviteSecret);
    expect(expired.status).toBe(401);
  });

  it("exchanges a paired device credential for a one-use socket ticket", async () => {
    const id = nextMachineId();
    const machineToken = secret(10);
    const deviceId = idFromNumber(903);
    const deviceToken = secret(11);
    await registerMachine(id, machineToken);
    await openMachine(id, machineToken);
    await registerDevice(id, machineToken, deviceId, deviceToken);

    const ticketResponse = await call(id, "tickets", {
      method: "POST",
      headers: { ...bearer(deviceToken), Origin: ORIGIN },
    });
    expect(ticketResponse.status).toBe(201);
    expect(ticketResponse.headers.get("Access-Control-Allow-Origin")).toBe(ORIGIN);
    expect(ticketResponse.headers.get("Cache-Control")).toBe("no-store");
    const ticket = await ticketResponse.json() as { ticket: string; expiresInSeconds: number };
    expect(ticket.ticket).toMatch(/^[0-9a-f]{64}$/);
    expect(ticket.expiresInSeconds).toBe(60);

    const connected = await connectDevice(id, ticket.ticket);
    expect(connected.status).toBe(101);
    const replay = await connectDevice(id, ticket.ticket);
    expect(replay.status).toBe(401);
  });

  it("bounds unconsumed socket tickets per device", async () => {
    const id = nextMachineId();
    const machineToken = secret(32);
    const deviceId = idFromNumber(909);
    const deviceToken = secret(33);
    await registerMachine(id, machineToken);
    await registerDevice(id, machineToken, deviceId, deviceToken);

    for (let index = 0; index < 8; index += 1) {
      const response = await call(id, "tickets", {
        method: "POST",
        headers: { ...bearer(deviceToken), Origin: ORIGIN },
      });
      expect(response.status).toBe(201);
    }
    const overflow = await call(id, "tickets", {
      method: "POST",
      headers: { ...bearer(deviceToken), Origin: ORIGIN },
    });
    expect(overflow.status).toBe(429);
  });

  it("revokes a device and closes its active socket", async () => {
    const id = nextMachineId();
    const machineToken = secret(12);
    const deviceId = idFromNumber(904);
    const deviceToken = secret(13);
    await registerMachine(id, machineToken);
    await openMachine(id, machineToken);
    await registerDevice(id, machineToken, deviceId, deviceToken);
    const ticket = await issueTicket(id, deviceToken);
    const socketResponse = await connectDevice(id, ticket);
    const close = waitForClose(socketOf(socketResponse));

    const revoked = await call(id, `devices/${deviceId}`, {
      method: "DELETE",
      headers: bearer(machineToken),
    });
    expect(revoked.status).toBe(204);
    expect(await close).toBe(1008);

    const newTicket = await call(id, "tickets", {
      method: "POST",
      headers: { ...bearer(deviceToken), Origin: ORIGIN },
    });
    expect(newTicket.status).toBe(401);
  });
});

describe("bounded channel forwarding", () => {
  it("caps the number of connected browser channels", async () => {
    const id = nextMachineId();
    const machineToken = secret(34);
    await registerMachine(id, machineToken);
    await openMachine(id, machineToken);

    for (let index = 0; index < 9; index += 1) {
      const channelId = idFromNumber(1200 + index);
      const inviteSecret = secret(40 + index);
      await createPairing(id, machineToken, channelId, inviteSecret, 60);
      const response = await connectPairing(id, channelId, inviteSecret);
      if (index < 8) {
        expect(response.status).toBe(101);
        socketOf(response);
      } else {
        expect(response.status).toBe(429);
      }
    }
  });

  it("routes opaque binary frames in both directions within their channel", async () => {
    const id = nextMachineId();
    const machineToken = secret(14);
    const deviceId = idFromNumber(905);
    const deviceToken = secret(15);
    await registerMachine(id, machineToken);
    const machine = await openMachine(id, machineToken);
    await registerDevice(id, machineToken, deviceId, deviceToken);
    const ticket = await issueTicket(id, deviceToken);
    const device = socketOf(await connectDevice(id, ticket));

    const machineMessage = waitForMessage(machine);
    device.send(frame(deviceId, [0xde, 0xad, 0xbe, 0xef]).buffer);
    expect([...new Uint8Array(await machineMessage)]).toEqual([...frame(deviceId, [0xde, 0xad, 0xbe, 0xef])]);

    const deviceMessage = waitForMessage(device);
    machine.send(frame(deviceId, [0x91, 0x92, 0x93]).buffer);
    expect([...new Uint8Array(await deviceMessage)]).toEqual([...frame(deviceId, [0x91, 0x92, 0x93])]);
  });

  it("closes a device that tries to send into another device channel", async () => {
    const id = nextMachineId();
    const machineToken = secret(16);
    const deviceId = idFromNumber(906);
    const otherChannel = idFromNumber(907);
    const deviceToken = secret(17);
    await registerMachine(id, machineToken);
    await openMachine(id, machineToken);
    await registerDevice(id, machineToken, deviceId, deviceToken);
    const device = socketOf(await connectDevice(id, await issueTicket(id, deviceToken)));
    const close = waitForClose(device);

    device.send(frame(otherChannel, [0x01]).buffer);
    expect(await close).toBe(1008);
  });

  it("closes oversized frames before forwarding", async () => {
    const id = nextMachineId();
    const machineToken = secret(18);
    const deviceId = idFromNumber(908);
    const deviceToken = secret(19);
    await registerMachine(id, machineToken);
    const machine = await openMachine(id, machineToken);
    await registerDevice(id, machineToken, deviceId, deviceToken);
    const device = socketOf(await connectDevice(id, await issueTicket(id, deviceToken)));
    const close = waitForClose(device);
    const oversized = new Uint8Array(64 * 1024 + 1);
    oversized.set(frame(deviceId, []));

    device.send(oversized.buffer);
    expect(await close).toBe(1009);
  });
});

function nextMachineId(): string {
  machineSequence += 1;
  return idFromNumber(machineSequence);
}

function idFromNumber(value: number): string {
  return value.toString(16).padStart(32, "0");
}

function secret(value: number): string {
  return value.toString(16).padStart(2, "0").repeat(32);
}

function bearer(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}` };
}

function jsonHeaders(token: string): Record<string, string> {
  return { ...bearer(token), "Content-Type": "application/json" };
}

function machinePath(id: string, endpoint: string): string {
  return `https://relay.test/v1/machines/${id}/${endpoint}`;
}

function call(id: string, endpoint: string, init: RequestInit = {}): Promise<Response> {
  return worker.fetch(new Request(machinePath(id, endpoint), init), env);
}

async function registerMachine(id: string, machineToken: string): Promise<void> {
  const response = await call(id, "register", { method: "POST", headers: bearer(machineToken) });
  expect([201, 204]).toContain(response.status);
}

async function createPairing(
  id: string,
  machineToken: string,
  channelId: string,
  inviteSecret: string,
  ttlSeconds: number,
): Promise<void> {
  const response = await call(id, "pairings", {
    method: "POST",
    headers: jsonHeaders(machineToken),
    body: JSON.stringify({ channelId, secret: inviteSecret, ttlSeconds }),
  });
  expect(response.status).toBe(201);
}

async function openMachine(id: string, machineToken: string): Promise<WebSocket> {
  const response = await call(id, "connect", {
    headers: websocketHeaders(machineToken),
  });
  expect(response.status).toBe(101);
  return socketOf(response);
}

async function connectPairing(id: string, channelId: string, inviteSecret: string): Promise<Response> {
  return worker.fetch(new Request(
    `${machinePath(id, `pair/${channelId}`)}?secret=${inviteSecret}`,
    { headers: websocketHeaders(undefined, ORIGIN) },
  ), env);
}

async function registerDevice(
  id: string,
  machineToken: string,
  deviceId: string,
  deviceToken: string,
): Promise<void> {
  const response = await call(id, `devices/${deviceId}`, {
    method: "PUT",
    headers: jsonHeaders(machineToken),
    body: JSON.stringify({ token: deviceToken }),
  });
  expect([201, 204]).toContain(response.status);
}

async function issueTicket(id: string, deviceToken: string): Promise<string> {
  const response = await call(id, "tickets", {
    method: "POST",
    headers: { ...bearer(deviceToken), Origin: ORIGIN },
  });
  expect(response.status).toBe(201);
  return (await response.json() as { ticket: string }).ticket;
}

function connectDevice(id: string, ticket: string): Promise<Response> {
  return worker.fetch(new Request(
    `${machinePath(id, "connect")}?ticket=${ticket}`,
    { headers: websocketHeaders(undefined, ORIGIN) },
  ), env);
}

function websocketHeaders(token?: string, origin?: string): Record<string, string> {
  return {
    Upgrade: "websocket",
    Connection: "Upgrade",
    ...(token ? bearer(token) : {}),
    ...(origin ? { Origin: origin } : {}),
  };
}

function socketOf(response: Response): WebSocket {
  const socket = (response as Response & { webSocket?: WebSocket }).webSocket;
  if (!socket) throw new Error("Worker returned no WebSocket endpoint");
  socket.accept();
  socket.binaryType = "arraybuffer";
  sockets.push(socket);
  return socket;
}

function frame(channelId: string, payload: number[]): Uint8Array {
  const bytes = new Uint8Array(17 + payload.length);
  bytes[0] = 1;
  for (let index = 0; index < 16; index += 1) {
    bytes[index + 1] = Number.parseInt(channelId.slice(index * 2, index * 2 + 2), 16);
  }
  bytes.set(payload, 17);
  return bytes;
}

function waitForMessage(socket: WebSocket): Promise<ArrayBuffer> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("timed out waiting for routed frame")), 1000);
    socket.addEventListener("message", (event) => {
      clearTimeout(timeout);
      const data = event.data;
      if (data instanceof ArrayBuffer) resolve(data);
      else if (ArrayBuffer.isView(data)) resolve(data.buffer as ArrayBuffer);
      else if (data instanceof Blob) void data.arrayBuffer().then(resolve, reject);
      else reject(new Error(`relay delivered unexpected data (${Object.prototype.toString.call(data)})`));
    }, { once: true });
  });
}

function waitForClose(socket: WebSocket): Promise<number> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("timed out waiting for WebSocket close")), 1000);
    socket.addEventListener("close", (event) => {
      clearTimeout(timeout);
      resolve(event.code);
    }, { once: true });
  });
}
