# Exosuit relay Worker

This is the local prototype of the M16 relay. One SQLite-backed Durable Object
is addressed by each random machine ID. A native workspace service opens the
machine WebSocket; pairing browsers and approved devices open their own
WebSockets to the same object. The object routes only binary frames and keeps
the routing channel in a 16-byte clear header:

```text
byte 0      envelope version (currently 1)
bytes 1-16  random channel ID
bytes 17+   opaque Noise handshake or encrypted application payload
```

The machine service selects a channel for every outgoing frame. Pairing and
device sockets may send only on their attached channel. This lets the Worker
unicast frames without reading Noise or workspace RPC contents. Frames are
limited to 64 KiB, there may be eight connected browser/device channels per
machine, eight outstanding invitations, eight outstanding tickets for each
device or machine service, and 128 active devices per machine.

The service will generate 16-byte machine, device and channel IDs and 32-byte
secrets with its OS cryptographic random source, then keep reusable bearers in
NativeKit's OS credential store. The generic NativeKit credential module and
Haxeon wrapper are implemented, but Exosuit has not connected them to the
workspace service. This Worker stores only SHA-256 hashes of bearer values,
invitation capabilities and one-use WebSocket tickets. The device bearer is
delivered to the browser only inside the approved Noise channel; encrypted
browser persistence is still pending. Noise identity checks, user approval,
workspace grants and RPC authorization remain service responsibilities.

## Local development

Install the pinned project-local toolchain and run the Worker-runtime tests:

```sh
npm ci
npm run check
npm run dev -- --var ALLOWED_ORIGINS:http://localhost:5173
```

`ALLOWED_ORIGINS` is a comma-separated exact-origin allowlist. Browser ticket
exchange and WebSocket pairing/device connections fail closed if the origin is
not listed. Set it to the actual web-client origin for local testing. The test
configuration supplies `https://client.test`; it does not modify deployment
configuration. Wrangler local development and the test suite need no Cloudflare
account. Do not use `wrangler deploy` as part of local qualification.

## Current endpoint contract

All machine-scoped routes use `/v1/machines/{machineId}`. The ID is an opaque,
random 16-byte value encoded as lowercase hex.

| Operation | Request | Purpose |
| --- | --- | --- |
| Claim machine route | `POST /register`, `Authorization: Bearer {machineToken}` | First use stores the machine-token hash; repeat use is idempotent. |
| Create pairing | `POST /pairings`, machine bearer, JSON `{channelId, secret, ttlSeconds}` | Stores only the invitation-secret hash, with a maximum five-minute lifetime. |
| Pairing socket | `wss://…/pair/{channelId}?secret={secret}` | Browser presents the single-use invitation capability. Requires an allowed `Origin` and an online machine socket. |
| Register approved device | `PUT /devices/{deviceId}`, machine bearer, JSON `{token}` | Stores a hash after the service has completed Noise verification and desktop approval. |
| Revoke device | `DELETE /devices/{deviceId}`, machine bearer | Tombstones the device, deletes its pending tickets and closes its live socket. |
| Request socket ticket | `POST /tickets`, machine or device bearer | Returns a 60-second, single-use ticket. Browser requests require an allowed origin. |
| Machine socket | `wss://…/connect?ticket={ticket}` | Workspace service exchanges its machine bearer over HTTPS, then upgrades with the one-use ticket. |
| Device socket | `wss://…/connect?ticket={ticket}` | Browser exchanges its stored device bearer for a one-use ticket, then upgrades. |

Invitation capabilities and one-use socket tickets appear in WebSocket query
strings because WebSocket APIs do not provide the same Authorization-header
control as HTTPS requests. They are random, short-lived and single-use;
reusable machine and device bearers never go in URLs. All external use requires
HTTPS/WSS.

The first machine registration is a high-entropy, first-claim capability rather
than an account-backed registration flow. Provision the machine ID and bearer
locally, store the bearer in the OS credential store, and register before
displaying any invitation. Account enrollment, global abuse controls and
machine credential rotation are not implemented; this prototype is not ready
for public deployment.

## Current limits

- WebSocket hibernation is enabled with `acceptWebSocket`; each connection
  serializes its role and channel so the Durable Object can rebuild routing
  after wake. Local tests prove bidirectional, channel-bound forwarding, but
  forced eviction with live test sockets did not complete in the local Vitest
  runtime. Runtime hibernation recovery remains a qualification gate.
- The Worker has no replay queue. Frames sent while the peer is offline are
  dropped; the service/RPC layer owns reconnect, cursor recovery and snapshots.
- There is no per-IP/global admission control or measured Cloudflare quota
  policy yet. Per-machine state and frame limits are local bounds, not a claim
  of protection from public abuse or arbitrary usage costs.
- Exosuit has a NativeKit machine connector that passes a local Wrangler ticket
  exchange and WebSocket-upgrade smoke test. A separate device-forwarding smoke
  got `503 machine_offline` after that upgrade, so live Worker/native-client
  routing remains unqualified even though Worker Vitest covers bidirectional
  forwarding. The connector is not yet part of workspace-service lifecycle.
- Noise integration, device-grant lifecycle, browser persistence and
  cross-network deployment are still open.
