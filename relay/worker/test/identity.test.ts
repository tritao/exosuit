import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker, { registrationProof, relayIdOf, x25519 } from "../src/index";

// Proven registration (docs/mobile/relay-identity.md): a machine whose relay id is derived from its Noise key takes the
// id back from whoever registered it first. The vectors are the ones tests/machine-device checks in MachineKeys.hx.

describe("machine key vectors", () => {
  it("derives the relay id and the proof as suit does", async () => {
    const key = Uint8Array.from({ length: 32 }, (_, index) => index);
    expect(await relayIdOf(key)).toBe("5ff11fa2bc5136b8ccf63b6c679d6f8d");
    const shared = new Uint8Array(32).fill(0x11);
    const challenge = Uint8Array.from({ length: 32 }, (_, index) => 32 + index);
    expect(await registrationProof(shared, "5ff11fa2bc5136b8ccf63b6c679d6f8d", challenge, "ab".repeat(32)))
      .toBe("bd14af04eba3b85dbfb2bca787b9a64bcf63070ec15a5e2de9170096057b1598");
  });
});

describe("proven machine registration", () => {
  it("takes back a relay id someone else registered first, and ends what they set up", async () => {
    const machine = await machineKey();
    const ownToken = "c1".repeat(32), squatterToken = "c2".repeat(32);
    expect((await register(machine.id, squatterToken)).status).toBe(201);
    const pairing = await call(machine.id, "pairings", {
      method: "POST",
      headers: { Authorization: `Bearer ${squatterToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ channelId: "ab".repeat(16), secret: "cd".repeat(32), ttlSeconds: 60 }),
    });
    expect(pairing.status).toBe(201);
    // The owner's plain registration meets the squatter, as with the Worker before proofs.
    expect((await register(machine.id, ownToken, "{}")).status).toBe(409);

    const reclaimed = await register(machine.id, ownToken, await provenBody(machine, ownToken));
    expect(reclaimed.status).toBe(201);
    expect(await reclaimed.json()).toEqual({ registered: true, reclaimed: true });
    // The id answers to the owner now; the squatter's bearer is worth nothing, and their invitation is gone.
    expect((await register(machine.id, ownToken, "{}")).status).toBe(204);
    expect((await register(machine.id, squatterToken)).status).toBe(409);
    expect((await call(machine.id, "tickets", { method: "POST", headers: { Authorization: `Bearer ${squatterToken}` } })).status)
      .toBe(401);
    const pairingAgain = await call(machine.id, "pairings", {
      method: "POST",
      headers: { Authorization: `Bearer ${ownToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ channelId: "ab".repeat(16), secret: "cd".repeat(32), ttlSeconds: 60 }),
    });
    expect(pairingAgain.status).toBe(201);
    // Proving again with the same bearer changes nothing.
    expect((await register(machine.id, ownToken, await provenBody(machine, ownToken))).status).toBe(204);
  });

  it("registers a free id with a proof", async () => {
    const machine = await machineKey();
    const token = "c3".repeat(32);
    expect((await register(machine.id, token, await provenBody(machine, token))).status).toBe(201);
    expect((await register(machine.id, token)).status).toBe(204);
  });

  it("refuses a proof for an id not derived from the key, a reused or unknown challenge, and a wrong proof", async () => {
    const machine = await machineKey();
    const other = await machineKey();
    const token = "c4".repeat(32);
    expect((await register(other.id, token, await provenBody(machine, token, other.id))).status).toBe(400);

    const challenge = await newChallenge(machine.id);
    const body = await provenBody(machine, token, machine.id, challenge);
    expect((await register(machine.id, token, body)).status).toBe(201);
    expect((await register(machine.id, token, body)).status).toBe(401);

    const unknown = JSON.parse(await provenBody(machine, token)) as Record<string, string>;
    unknown.challenge = "00".repeat(32);
    expect((await register(machine.id, token, JSON.stringify(unknown))).status).toBe(401);

    const wrong = JSON.parse(await provenBody(machine, token)) as Record<string, string>;
    wrong.proof = "00".repeat(32);
    expect((await register(machine.id, token, JSON.stringify(wrong))).status).toBe(401);

    // A proof made for another bearer does not register this one.
    const stolen = await provenBody(machine, "c5".repeat(32));
    expect((await register(machine.id, "c6".repeat(32), stolen)).status).toBe(401);
  });

  it("bounds outstanding challenges", async () => {
    const machine = await machineKey();
    for (let index = 0; index < 8; index += 1) await newChallenge(machine.id);
    expect((await call(machine.id, "register/challenge", { method: "POST" })).status).toBe(429);
  });
});

interface MachineKey {
  id: string;
  publicKey: Uint8Array<ArrayBuffer>;
  privateKey: Uint8Array<ArrayBuffer>;
}

async function machineKey(): Promise<MachineKey> {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]) as CryptoKeyPair;
  const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey) as ArrayBuffer);
  const privateKey = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey) as ArrayBuffer);
  return { id: await relayIdOf(publicKey), publicKey, privateKey };
}

async function newChallenge(id: string): Promise<string> {
  // suit sends "{}" as the body, as on every relay POST.
  const response = await call(id, "register/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  });
  expect(response.status).toBe(201);
  return (await response.json() as { challenge: string }).challenge;
}

/** What suit sends (RelayRegistrationProver.body), made here with WebCrypto. */
async function provenBody(machine: MachineKey, token: string, id = machine.id, challenge?: string): Promise<string> {
  const challengeHex = challenge ?? await newChallenge(id);
  const shared = await x25519(machine.privateKey, hexToBytes(challengeHex));
  const proof = await registrationProof(shared, id, hexToBytes(challengeHex), token);
  return JSON.stringify({ publicKey: toHex(machine.publicKey), challenge: challengeHex, proof });
}

async function register(id: string, token: string, body?: string): Promise<Response> {
  const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const response = await call(id, "register", { method: "POST", headers, body });
  return response;
}

function call(id: string, endpoint: string, init: RequestInit = {}): Promise<Response> {
  return worker.fetch(new Request(`https://relay.test/v1/machines/${id}/${endpoint}`, init), env);
}

function hexToBytes(value: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from({ length: value.length / 2 }, (_, index) => Number.parseInt(value.slice(index * 2, index * 2 + 2), 16));
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
