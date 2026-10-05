# M16 — Connected web workspaces and away-from-home access

Status: planned, not implemented. Depends on Haxeon RPC.1/RPC.2 and the M14
workspace service; terminal and provider features depend on their M12/M14
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

## M16.1 — Browser connection, pairing and relay

- [ ] Add Connect to machine and paired-machine selection to the existing web
  entry point. Show connection state, machine availability and permissions.
- [ ] Desktop/service Remote Access creates a short-lived single-use pairing
  invitation; scanning its QR code or opening its URL enters the same web UI.
  Require explicit desktop pairing confirmation. Persist revocable device
  identity and workspace-scoped grants, not reusable credentials in URLs.
- [ ] Provide an outbound connection from the workspace service to a relay.
  The browser connects over secure WebSocket through that relay so remote use
  does not require an inbound public port, manual port forwarding or a VPN.
  Keep direct/local transport optional under the same client interface.
- [ ] Keep workspace traffic end-to-end encrypted between paired browser and
  service. Select an established browser-compatible protocol/library before
  implementation, validate pairing identity binding and browser key storage,
  and test it; do not invent cryptography or treat relay TLS as end-to-end
  encryption. Serve client assets over HTTPS. Relay handles routing/discovery,
  not workspace history or provider credentials. Document relay trust/metadata
  and web-client delivery trust. Keep relay deployment self-hostable.
- [ ] Use RPC reconnect with fresh authenticated handshakes and Exosuit-owned
  resource/cursor recovery. Machine sleep/offline and revoked devices produce
  clear states rather than stale connected indicators.

Acceptance: load the normal web build on a separate network, pair with a
running development machine and reconnect without inbound port forwarding.
Verify invitation expiry/reuse rejection, device revocation, workspace grants,
relay restart, machine offline and network changes. This slice includes an
actual outbound-relay/browser path, not a mocked LAN-only demonstration.
Deployment/publication requires separate authorization under EXECUTION.md.

## M16.2 — Files, agents and terminals in the web build

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
