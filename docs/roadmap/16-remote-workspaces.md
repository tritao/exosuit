# M16 — Connected web workspaces and away-from-home access

Status: in progress. M16.1 has a local relay prototype, a NativeKit machine
ticket/WebSocket connector, and a selected/tested secure-channel design. The
workspace-service lifecycle, browser client and cross-network qualification
remain unimplemented. It depends on Haxeon RPC.1/RPC.2 and the
M14 workspace service; terminal and provider features depend on their M12/M14
acceptance. Use the existing M15 web build as the first remote client. Android
uses the same responsive web application; a native Android app is not required
for initial delivery. Away-from-home access is part of initial remote delivery,
not a later LAN-only enhancement.

## Architecture and ownership

Desktop local sockets and connected web clients call the same typed workspace
service through Haxeon RPC adapters. The service owns files/watchers, persistent
terminal processes and agent connections. Web clients own presentation state.
Do not remotely mirror the desktop window or move keystroke editing round trips
into the local desktop text model.

The web build has explicit standalone and connected modes. Standalone mode
retains its sandboxed sample filesystem and M15 gates. Connected mode selects
a machine/workspace and uses negotiated service capabilities. Remote process,
terminal and agent availability must not be confused with browser-native OS
capabilities. No local PTY, provider credential or native IPC is required in the
browser. Clearly identify saved files versus any later desktop draft feature.

## Relay deployment decision — Cloudflare Workers

Cloudflare Workers plus SQLite-backed Durable Objects is the planned initial
relay implementation. Start on Workers Free; do not enable paid billing or
change account plans without user approval. Keep transport configurable so a
self-hosted relay or direct authenticated endpoint remains possible. Cloudflare
Tunnel/Access is an optional deployment alternative, not a prerequisite.

A thin Worker routes registration/pairing/connection requests to one Durable
Object per opaque registered machine identity. Both the machine and browsers
initiate secure WebSocket connections into the object. Use the Hibernation
WebSocket API (`acceptWebSocket`), reconstruct routing from connection
attachments after wake, and use automatic keepalive responses where suitable.
Avoid outbound object connections, background timers and periodic storage
writes that prevent idle hibernation. No connected viewers means no forwarding
of routine terminal/agent output; history stays on the development machine.

The relay authenticates connection roles and destination grants, forwards
bounded encrypted payloads and records only minimal registration/revocation
metadata. Never place provider secrets, file contents, terminal history or
workspace encryption keys in relay storage/logs. Workspace service validates
device permissions independently. Define opaque machine ids and authenticated
routing; possession of an id alone must not grant access.

The local Worker prototype lives in [`relay/worker/`](../../relay/worker/README.md).
It uses one-use invitation capabilities and machine/device socket tickets, hashed
credentials, a 16-byte per-channel routing prefix and bounded binary forwarding.
The Exosuit desktop now has a ticketed machine connector and bounded HMPK channel
multiplexer. It does not inspect Noise or RPC payloads. Machine/device credential
creation and storage in the service, global abuse control, measured quotas and
remote deployment remain open. Browser routes require an exact configured origin
allowlist.

Free-tier daily limits can interrupt operations, so report quota exhaustion
explicitly and back off reconnect attempts. Measure request counts, active
GB-seconds, stored rows and representative output workloads before choosing
paid deployment. Application admission/rate/size limits bound abuse; do not
claim that billing alerts impose a hard spend cap. Worker request/CPU usage
also counts independently of Durable Object usage.

Reference documentation checked 2026-10-05:
[WebSocket hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/),
[Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/),
[Wrangler commands](https://developers.cloudflare.com/workers/wrangler/commands/).

### Implementation and deployment inputs

Local implementation needs no user account access. The project-local Worker,
pinned Wrangler toolchain and runtime tests now live in `relay/worker/`; use
them to build the reviewable service/client slice before requesting publication
approval. Local development and tests do not authenticate or deploy.

For live cross-network qualification, the user supplies a Cloudflare account
with Workers enabled and authenticates Wrangler locally (interactive login,
or a narrowly scoped credential installed outside repository/chat). Select the
account if more than one is available. Start with a workers.dev endpoint;
custom domain/DNS is optional. Keep native identity/encryption verification
working with that endpoint. Check actual account free-tier eligibility before
deployment. Never request raw tokens in chat or commit credentials.

Remote deployment remains a final approval step under EXECUTION.md. Report the
exact Worker/namespace/assets being published, endpoint, expected cost tier
and verification plan for review. Real Android qualification also needs an
available phone/browser, which can wait until the connected slice is ready.
No account setup is required merely to proceed with local implementation.

## M16.1 — Browser connection, pairing and relay

### Secure channel and device-key decision

Use the Noise Protocol Framework `XX` handshake with the fixed suite
`Noise_XX_25519_ChaChaPoly_SHA256`. XX fits first pairing because neither side
knows the other's static key in advance; after the handshake each side has
authenticated possession of the key it received, while the first-pairing UI
still has to establish whether that key belongs to the intended person/device.
The desktop and browser compare a short authentication string derived from the
Noise handshake hash before the desktop owner approves the device. The Noise
prologue binds a versioned, canonical encoding of machine ID, device ID and
initiator/responder roles. It contains no secret material.

Use the same pinned C Noise implementation in the NativeKit native module and
the Emscripten web host. The initial candidate is
[Noise-C](https://github.com/rweather/noise-c), pinned at `cfe2541` for the
prototype. It is MIT-licensed and its upstream core unit and Noise vector suites
pass on Linux. Do not use the archived `noise-c.wasm` wrapper. Noise-C's default
random source only handles Linux/macOS and Windows; the NativeKit integration
must select the Emscripten `/dev/urandom` bridge explicitly and fail closed if
entropy is unavailable. A prototype using that bridge passes in headless
Chrome; the production module still needs its own browser test before the
channel can be accepted. Noise-C describes
itself as a reference implementation, and this choice is not a claim of an
independent security audit. Reassess the pinned implementation if portability,
maintenance or review raises a material concern.

The workspace service creates a persistent static key once and stores its
private bytes in the NativeKit OS credential store. The database stores its
public identity, device public keys, revocation state and workspace-scoped
grants. A browser keeps its static private key encrypted at rest in
origin-scoped IndexedDB: a non-extractable WebCrypto AES-GCM wrapping key is
stored there as a `CryptoKey`, with the Noise private key stored only as
ciphertext. The browser holds the decrypted Noise key only while establishing
the channel. This protects copied browser storage at rest; same-origin script
execution remains inside the web-client trust boundary.

The QR/deep link carries only a short-lived, single-use pairing capability and
opaque routing ID; it never carries a reusable device credential or workspace
key. Consuming the invitation only admits a pending handshake. No workspace
method is enabled until the user compares the authentication string and
approves the device. The service then pins that device's static public key and
its explicit workspace grants; later connections perform a fresh XX handshake
against the pinned identities. The relay forwards bounded opaque handshake and
ciphertext frames and stores no private keys, workspace keys or decrypted RPC.

Investigation on 2026-10-06 verified Noise-C's core unit suite and all 1392
upstream vectors at `cfe2541` on Linux. The same source compiled to Wasm with the
pinned Emscripten 6.0.9 toolchain; its unit suite passed in Node and headless
Chrome, and all 1392 vectors passed in Node. This proves the prototype's
Emscripten `/dev/urandom` path uses a working browser entropy source. The
complete upstream `make check` could not run because this environment lacks
`yacc`. NativeKit/Haxeon channel integration, explicit Emscripten entropy
selection, the browser key store and the full Web host handshake remain
acceptance gates. See the
[Noise specification](https://noiseprotocol.org/noise.html) and the
[Web Crypto specification](https://www.w3.org/TR/WebCryptoAPI/) for the
protocol and browser key-storage contracts.

- [ ] Add Connect to machine and paired-machine selection to the existing web
  entry point. Show connection state, machine availability and permissions.
- [ ] Desktop/service Remote Access creates a short-lived single-use pairing
  invitation; scanning its QR code or opening its URL enters the same web UI.
  Require explicit desktop pairing confirmation. Persist revocable device
  identity and workspace-scoped grants, not reusable credentials in URLs.
- [ ] Finish Worker/router and SQLite Durable Object qualification for
  hibernation recovery, forwarding limits, quota behavior and fault injection.
- [x] Create an account-free local Worker/SQLite prototype with machine claim,
  device registration/revocation, expiring single-use pairing, one-use socket
  tickets, origin checks, bounded binary frames and channel-scoped unicast.
  Local tests cover replay, expiry, revocation, offline pairing, overload caps,
  frame limits and bidirectional delivery. Forced Durable Object eviction with
  live sockets still needs qualification; quota behavior and global admission
  controls are not implemented.
- [x] Add the NativeKit machine connector: exchange the reusable machine bearer
  over HTTP Authorization, then connect with the one-use socket ticket. The
  local Wrangler test verifies ticket exchange and machine WebSocket upgrade.
- [x] Verify bidirectional NativeKit machine/device data routing through the
  local Wrangler Worker. Keep the machine socket alive while the test device
  obtains its ticket and connects; the test covers bounded channel framing in
  both directions.
- [ ] Integrate the connector with workspace-service lifecycle and the browser
  client, then qualify across networks. The browser must connect over secure
  WebSocket through the relay so remote use needs no inbound public port,
  manual port forwarding or VPN. Keep direct/local transport optional under the
  same client interface.
- [x] Select and prototype-test the browser-compatible Noise XX suite and
  NativeKit/WebCrypto key-custody design documented above. Do not invent
  cryptography or treat relay TLS as end-to-end encryption.
- [ ] Integrate the selected Noise channel into NativeKit/Haxeon and the web
  host, validate pairing identity binding and browser key storage, and test the
  complete handshake. Serve client assets over HTTPS. Relay handles
  routing/discovery, not workspace history or provider credentials. Document
  relay trust/metadata and web-client delivery trust. Keep relay deployment
  self-hostable.
- [ ] Use RPC reconnect with fresh authenticated handshakes and Exosuit-owned
  resource/cursor recovery. Machine sleep/offline and revoked devices produce
  clear states rather than stale connected indicators.

Acceptance: load the normal web build on a separate network, pair with a
running development machine and reconnect without inbound port forwarding.
Verify hibernation/wake routing, bounded overload and free-tier usage evidence,
invitation expiry/reuse rejection, device revocation, workspace grants,
relay restart, machine offline and network changes. This slice includes an
actual outbound-relay/browser path, not a mocked LAN-only demonstration.
Deployment/publication requires separate authorization under EXECUTION.md.

## M16.2 — Files, agents and terminals in the web build

- [ ] Deliver [filesystem protocol F1–F5](WORKSPACE-FILES.md): typed root-relative
  addressing, coherent revision-checked reads, paginated directories, recoverable
  watches and cancellable file/content search through the shared service.
- [ ] Browse allowed project roots and view saved files with bounded reads,
  paginated listings, syntax display and change notifications. Handle path
  traversal/symlinks under the service's workspace access policy.
- [ ] View Claude/Codex sessions, conversation/activity and pending requests.
  Add prompt, interruption and approval actions under explicit device grants.
  Resolve competing-client approvals exactly once at the service boundary.
- [ ] Attach terminal history/output using offsets and checkpoints, then
  explicit input/resize control. Multiple viewers do not resize a shared PTY;
  controller ownership transfers visibly and recovers after disconnect.
- [ ] Resume event streams or fetch fresh snapshots after replay expiry.
  Bound history, queues and polling; bulk output must not starve control events.

Acceptance: same workspace resources appear on desktop and web. Closing the
editor leaves the service and persistent sessions available. Browser reload
and disconnect recover history without duplicate prompts or terminals. Both
Wasm builds retain standalone M15 smoke and pass connected-browser tests.

## M16.3 — Android qualification

- [ ] Adapt existing web views for touch/narrow screens and provide optional
  installable web-app support. Keep shared client/protocol models; platform
  shell integration is a later decision.
- [ ] Test a real Android browser for file browsing, agent prompts/approvals,
  terminal touch/keyboard input, app suspension and Wi-Fi/mobile transitions.

Acceptance: remote access works away from home from the existing web build
and Android browser. Record device/browser and network evidence. Native Android
packaging and remote file editing are outside initial M16 scope. Remote editing
requires revision-checked saves/conflict UX in a separately accepted slice.
