# M16 — Connected web workspaces and away-from-home access

Status: in progress. M16.1 now includes the local relay prototype, opt-in
workspace-daemon hosting, NativeKit OS credential storage for the machine
bearer, Noise-authenticated device grants, a desktop approval panel, and a
first-pairing browser client. The browser consumes a pasted one-use relay URL,
compares the Noise transcript code, stores device credentials encrypted under
a non-extractable WebCrypto key, confirms receipt to the daemon, and verifies
workspace identity over RPC. The full first-pair path now passes in headless
Chrome through a local Wrangler Worker, including code comparison, desktop
same-user pairing administration RPC, encrypted browser storage, and reload of
approved device trust from the production SQLite store. Saved-device selection
and reconnect now obtain a fresh relay ticket and verify the pinned machine key;
the Worker also resets the daemon's stale channel before admitting a replacement
device socket. Graphical desktop-panel clickthrough, remote workspace resources,
and cross-network qualification remain open. A separate local
Worker smoke test starts the real `AgentMain` twice to qualify opt-in daemon
startup, OS credential reload, and SQLite reopen; the full browser-pairing run
still uses its focused host harness. It
depends on Haxeon RPC.1/RPC.2 and the
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
overrides it with `crypto.getRandomValues` for Emscripten and fails closed if
secure browser entropy is unavailable. The native package and Haxeon boundary
are implemented; the production Wasm host builds and the web app launches in
headless Chrome. The first-pair browser-to-Worker flow now passes locally;
cross-network and deployment qualification remain open. Noise-C describes
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
approves the device. The service delivers the relay bearer inside Noise and
waits for an encrypted device receipt confirmation before admitting RPC; a
missing confirmation rolls back the local grant and revokes the relay bearer.
The service pins that device's static public key and its explicit workspace
grants; later connections perform a fresh XX handshake against the pinned
identities. The relay forwards bounded opaque handshake and ciphertext frames
and stores no private keys, workspace keys or decrypted RPC.

Investigation on 2026-10-06 verified Noise-C's core unit suite and all 1392
upstream vectors at `cfe2541` on Linux. The same source compiled to Wasm with the
pinned Emscripten 6.0.9 toolchain; its unit suite passed in Node and headless
Chrome, and all 1392 vectors passed in Node. That earlier prototype used an
Emscripten `/dev/urandom` shim; the production package now uses the browser
Crypto API directly. Headless Chrome validates WebCrypto credential storage
and the live browser-to-Worker first-pair path. The
complete upstream `make check` could not run because this environment lacks
`yacc`. See the
[Noise specification](https://noiseprotocol.org/noise.html) and the
[Web Crypto specification](https://www.w3.org/TR/WebCryptoAPI/) for the
protocol and browser key-storage contracts.

- [ ] Add saved-machine selection and reconnection to the existing web entry
  point. First-pairing UI now shows connection state and approved permissions;
  it consumes the pasted one-use URL and verifies the workspace identity.
- [ ] Desktop/service Remote Access creates a short-lived single-use pairing
  invitation; scanning its QR code or opening its URL enters the same web UI.
  The desktop panel now creates short-lived invitations, compares the
  transcript code, selects grants, and lists or revokes devices. The copied
  one-time relay URL is not yet a web-app deep link; QR sharing remains open.
  The browser consumes the pasted URL and stores reusable credentials only in
  its encrypted origin-scoped store, never in the URL.
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
- [x] Integrate opt-in machine hosting with the workspace-daemon lifecycle.
  `EXOSUIT_RELAY_ORIGIN` enables it; the managed launcher creates a stable
  per-workspace machine identity and a private one-shot bootstrap, and the
  daemon stores the bearer with NativeKit credentials, enrolls and reconnects
  with backoff. Explicit relay hosting keeps the daemon alive. Inbound channels
  now require Noise XX, a pinned device key and saved workspace grants before
  the RPC server accepts the peer. A same-user local RPC surface now creates
  one-use invitations, lists pending transcript codes, and approves, rejects
  or revokes devices. The graphical Remote Access panel exposes those
  controls, shows matching codes and grants, and revokes saved devices.
- [x] Smoke-test real `AgentMain` relay startup and restart against the local
  Worker. The test sets `EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP=1`, which only
  permits the loopback HTTP origin already enforced by `RelayMachineEndpoint`.
  A second launch supplies a different one-shot bootstrap token and still
  enrolls with the original OS-stored bearer; the production SQLite catalog
  reopens after both launches. This is daemon startup qualification, not the
  browser pairing E2E or a cross-network test.
- [ ] Qualify browser access across networks. Local first pairing and saved-
  device reconnection pass through headless Chrome and Wrangler. Cross-network
  use remains open; keep direct/local transport optional under the same client
  interface.
- [x] Select and prototype-test the browser-compatible Noise XX suite and
  NativeKit/WebCrypto key-custody design documented above. Do not invent
  cryptography or treat relay TLS as end-to-end encryption.
- [x] Vendor the pinned Noise-C source as a submodule and add a fixed-suite
  NativeKit/Haxeon package. Native and Wasm ABI generation, the native Haxe
  binding, machine OS-key storage, workspace-scoped device records, Noise
  framing and per-device RPC grant negotiation are implemented. Tests cover
  XX, pinned machine/device identities, route binding, encrypted traffic,
  nonce-safe backpressure, grant enforcement, schema migration and revocation.
- [x] Add the daemon-side first-pairing gate. New Noise identities remain
  pending until a local administrator compares the transcript code and approves
  an explicit grant subset. Approval registers a relay bearer, persists the
  device key/grants and delivers the bearer only inside Noise. RPC waits for an
  encrypted device receipt confirmation; a missing confirmation rolls back
  local state and revokes the relay registration. Tests cover unsupported
  grants, relay registration failure, rejection, invitation/pending/receipt
  expiry, one-use admission, revocation and local-only RPC access. The local
  methods are exposed in the graphical Remote Access panel.
- [x] Add the browser credential-storage primitive. It stores the Noise static
  key and relay bearer as AES-GCM ciphertext in origin-scoped IndexedDB, with a
  non-extractable WebCrypto wrapping key. A headless-Chrome test checks the
  round trip, non-extractability, tamper rejection and record removal. The
  first-pairing client now saves credentials through this store.
- [x] Add first-pairing browser UI and key-custody integration. The web client
  consumes an invitation, persists the Noise identity and bearer through the
  browser store, displays the transcript code, and confirms it with the machine
  owner before admitting workspace RPC. The current workspace call verifies
  remote identity; file, terminal and agent views remain in M16.2.
- [x] Run browser first pairing against the production SQLite device store and
  reopen the database after approval. The test verifies the pinned device
  remains active with exactly the approved capabilities. The initial test used
  a focused host harness; the real-daemon browser flow is qualified below.
- [x] Create invitations, read pending transcript codes, and approve grants via
  the daemon's same-user local RPC methods in the browser pairing harness. This
  covers the API used by `LocalWorkspaceClient`. The browser flow now also runs
  against real `AgentMain`; graphical desktop-panel clickthrough remains a
  separate acceptance check.
- [x] Run browser first pairing and saved-device reconnection through real
  `AgentMain`, using its local admin RPC, NativeKit credential service, relay
  host and production SQLite catalog. Verify the browser's transcript code,
  approved grants, pinned machine identity, authenticated reconnect and saved
  device row after daemon shutdown. The run caught and fixed an RPC method-ID
  collision by assigning pairing administration IDs 130–134. This is local
  qualification; graphical desktop approval and cross-network access remain
  open.
- [x] Keep the web build compiling the shared network and Noise interfaces.
  The build generates the wasm32 NativeKit network ABI, compiles the Haxeon
  guest and Emscripten host, and verifies all guest imports.
- [x] Integrate the selected Noise channel into NativeKit/Haxeon and the web
  host. The first-pair flow binds machine/device IDs in the Noise prologue,
  checks the matching code, stores credentials, waits for the encrypted receipt,
  and starts workspace RPC. `tests/workspace-browser-pairing/run.py` now checks
  the actual browser-to-Worker first-pair path, matching code, approved grants,
  workspace identity and encrypted IndexedDB record. The Wasm build and local
  Worker qualification pass. Cross-network access and remote deployment remain
  gates. Serve client assets over HTTPS. Relay handles
  routing/discovery, not workspace history or provider credentials. Document
  relay trust/metadata and web-client delivery trust. Keep relay deployment
  self-hostable.
- [x] Qualify fresh-browser first pairing against a local Wrangler Worker. The
  test drives the browser Remote Access panel, matches the Noise code against
  the real host pairing manager, and verifies its approval, workspace identity
  over RPC, and AES-GCM-protected IndexedDB record. Approved device trust is
  persisted and reloaded through production `WorkspaceSqliteStore`. Invitation,
  pending-code listing and approval now travel through a same-user local RPC
  client. The focused-host test remains available for faster isolation, and
  `--agent` exercises the same flow through the production daemon. The initial
  test also caught the Emscripten empty WebSocket subprotocol bug, fixed by
  passing `nullptr` when negotiation is omitted. Run with a built site using
  `python3 tests/workspace-browser-pairing/run.py <site-directory>`; add
  `--agent` to include AgentMain, SQLite and the OS credential service.
- [x] Add saved-device selection and reconnect in the browser panel. The browser
  keeps the relay origin beside its encrypted credential, requests a fresh
  ticket with the saved device bearer, and pins the machine Noise key before
  starting workspace RPC. Haxeon now decodes NativeKit HTTP completion events
  on WASM, and the Worker sends a bounded route-reset envelope before accepting
  a device reconnect so the daemon discards the previous channel. The local
  browser/Worker E2E pairs, disconnects, and reconnects with the same workspace
  identity and grants.
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
