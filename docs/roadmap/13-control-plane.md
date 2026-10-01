# M13 — Local control plane and `exosuit-ctl`

Depends on M11.2. The reference is Pragtical `data/core/control/*`,
`src/ctl_main.c` and `docs/control-cli.md`. Stay wire-compatible with
Pragtical control protocol v1, so its fake-server tests
(`scripts/test-control-cli.py`) and either CLI can drive either editor. Note
that Haxeon's `MessagePackFrame` uses an "HMPK" header and is therefore not
this framing.

## M13.1 — Protocol and server

- [ ] Framing: a 4-byte big-endian length followed by a MessagePack map. Kinds:
  request `{id, method, params}`, response `{id, result|error}`, and event
  `{sequence, event, data}`. Errors are `{code, message, retryable}` with
  Pragtical's code set.
- [ ] Limits: 16 MiB payload, depth 32, 8 MiB queued per client, 32
  accepts/requests/messages per poll, 10 s frame and request timeouts, 300 s
  idle. `control.hello` must come first.
- [ ] Add a method registry with validation and structured errors. Plugins
  register methods through the stable editor API (M5.2).
- [ ] Instance discovery: MessagePack descriptors under
  `$XDG_RUNTIME_DIR/exosuit/instances/` (falling back to the user dir) and
  sockets under `.../sockets/`. Handshake-validate descriptors; never trust
  stale files.

## M13.2 — Methods

- [ ] Implement `control.hello`, `control.ping`, `instance.status`,
  `window.focus`, `editor.open`, `editor.documents`, `editor.save`,
  `project.add` and `project.change`. `project.change` waits for user
  confirmation through `ConfirmationService`. Emit the events
  `document.opened` and `project.changed`.
- [ ] Launch forwarding: a second `exosuit <file>` opens the file in the
  running instance and exits.
- [ ] Cross-instance tab transfer (`tab.drag.*`, saved and unmodified documents
  only). This comes last and is optional for the milestone.

## M13.3 — CLI

- [ ] Add a headless `exosuit-ctl` entry with its own manifest, so it does not
  link UIKit. Commands: list, status, focus, open, documents, save, `project
  add|change`, and `call METHOD JSON`. Options: `--instance`, `--project`,
  `--timeout`, `--output text|json`. Exit codes: 2 usage, 3 discovery,
  4 connection/timeout, 5 remote error, 6 protocol, 7 internal.

Acceptance: protocol tests cover round-trips, integer bounds, trailing data,
oversized and deep payloads, and split frames. CLI tests run against a fake
server and a real headless instance. Launch forwarding works end to end.
Pragtical's `pragtical-ctl` can list and open files in exosuit.
