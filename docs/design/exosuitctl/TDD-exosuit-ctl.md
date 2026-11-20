# TDD: `exosuitctl`, a local control plane served by exohost

Status: built (entropy pass, 2026-11-15 and 16). Every owner decision (Q1–Q19) is answered. exohost/README.md
("Control plane") summarises it, and docs/ARCHITECTURE.md places it in the system.

### As built: where it differs from this design

- **The phone keeps a snapshot file.** It has no exohost, so `android/haxe/src/PhoneSnapshotFile.hx` writes
  `files/automation/snapshot.json` for the phone rig; Q11 holds for desktop windows.
- **No request files from the editor.** Every call travels on the window's link.
- **Pragtical pipes work for `list` only.** NativeKit's local listener stops when a client connects and closes before
  it is accepted, which pragtical's health check does on every command (docs/haxeon-compiler-bugs.md). exohost restarts
  the listener, but pragtical connects again inside the gap. Fixing it needs NativeKit to disconnect and keep
  listening on `ERROR_NO_DATA`.
- **`AllowSetForegroundWindow` is not called** (§8.3): the window raises itself (`nk_window_restore`,
  `nk_window_activate`) when `window.focus` arrives.
- **A forwarded `path:line` that falls back to a local window opens without the line.**
- **`exosuit.terminal.read`** returns the visible rows and the cursor, not scrollback.
- **Folder open goes through the workspace model:** `editor.open` on a folder opens the workspace that holds it, or
  makes one of it and opens that, exactly as starting the editor with the folder does (`openFolderWorkspace`), also
  when the window is on another workspace.
- **Names.** The editor's link is `src/exohost/ExohostLink.hx`, its method table `graphical/src/ui/control/EditorControl.hx`
  (with `SyntheticInput` and `DrivenDialogs`), and the Pragtical codec and pipes are exohost's `PragticalCodec` and
  `PragticalPipes`.
- **Real input.** One scenario sends OS input: `m19_switch_latency.py` (RealInputGui), which measures input latency.

### Decisions so far

| Q | Decision |
|---|---|
| Q1 | **A.** exohost's main pipe keeps HMPK `{op}`. A new `control` op wraps v1 method calls. The editor link is an `editor-attach` upgrade. Raw Pragtical framing exists only on the per-editor compat pipes. |
| Q2 | **(b).** Descriptors go in `<exohost home>\runtime\instances`. pragtical-ctl reaches them through `PRAGTICAL_USERDIR=%LOCALAPPDATA%\exosuit\exohost`. |
| Q3 | **(a).** Forwarding runs early in `GraphicalMain`, with a 1 s budget and a fallback to opening locally. It is on by default for stable and dev builds, and off for `--live`, automation and `--new-window`. |
| Q4 | **(d).** `exosuit.quit {mode: prompt\|recover\|save}`. The tray defaults to `recover` (hot exit). A single-window close uses `prompt`. |
| Q5 | **(a).** If no window holds a workspace containing the path, use the MRU window, where the file opens as a loose tab. |
| Q6 | **(a).** The link replaces the editor's registry file. Services and hosts keep theirs. |
| Q7 | **(a), renamed.** Multicall by program name. **`exosuitctl`** is Pragtical's command set plus `quit`. **`exohost`** keeps its existing verbs and gains `open\|focus\|documents\|save\|project\|call`. The two invocation formats give each command its context. |
| Q8 | **(a).** Local only. Remote access comes later, behind a device grant. |
| Q9 | **(a).** The automation command files are retired. New goal G8: Exosuit can be driven completely over this protocol, with no computer use (§8.4). |
| Q10 | **(b).** Element-level input goes into the UI's own input queue as synthetic events. It is never OS input. |
| Q11 | **(a).** `snapshot.json` is retired in favour of `ui.snapshot` and `ui.changed`. |
| Q12 | **(a).** All methods are allowed on the per-editor Pragtical pipes. |
| Q13 | **(a).** Automation methods are always on. Each call is logged with the caller's pid, and the tray shows "being driven". |
| Q14 | **(a).** The CLI is named `exosuitctl`, not `exosuit-ctl`. (Decided as `exohostctl`; the owner renamed it to `exosuitctl` on 2026-11-20. `scripts/exohostctl` remains as a forwarder.) |
| Q15 | **(a).** Terminals and agent sessions are driven through an editor for now. |
| Workbench redesign (owner, decided) | exohost is always on; the exohost-off and folder-only modes are removed. A click opens a workspace in milliseconds from its catalog snapshot. Every row has its full action menu, even when idle. There is one service process per running workspace, plus a warm spare that exists only while an editor window is open (Workbench Q9). A failed start keeps typed text as an unsent draft and never auto-sends it (Workbench Q11). TDD alignment: §6.1. |
| Q16 | **(c).** Both `path:line[:col]` and explicit flags (`exosuitctl open --line N --column N`, `exosuit --goto N[:N]`). The suffix is parsed only when it is all digits and the whole string is not an existing file, and that rule is tested on drive-letter paths. |
| Q17 | **(a).** `terminal.read` returns rendered text: the visible screen rows, the cursor, and scrollback lines since a sequence number. |
| Q18 | **(a).** Events are opt-in on the main pipe: `exosuit.events.subscribe {names, instance?}`, plus `exosuitctl watch [EVENT...]`, which streams JSON lines. The Pragtical pipes keep Pragtical's push of `document.opened` and `project.changed`. |
| Q19 | **(b).** Real input always wins. Injected input is held while real input arrived in the last ~1 s; a call that waits too long answers `busy`, retryable. |

Pragtical references in §2 are to `pragtical` (branch `next`, 2c2d5bbb). **UNVERIFIED** marks an inference that was
not checked.

---

## 1. Goals and non-goals

### Goals
1. One local control plane. exohost serves it on the endpoint it already owns. No editor runs a control server of its
   own.
2. `exosuitctl` is exohost's own CLI under a second name, not a separate program. Commands: open, focus, list, status,
   documents, save, project, call, quit.
3. Launch forwarding. `exosuit <file>` opens the file in a running editor when one fits, and in a new window otherwise.
4. Multi-instance routing. By default the target is the editor whose open workspace contains the path; if none does,
   the most recently used editor. `--instance` and `--new-window` override the default.
5. Each editor keeps one persistent link to exohost. Commands from exohost reach the editor over it, so quit becomes a request
   the editor answers ("save and close", Q4=d) instead of a WM_CLOSE that exohost cannot see the outcome of.
6. Wire compatibility with Pragtical control protocol v1, so that `pragtical-ctl` can list, focus and open files in
   Exosuit editors (Q2=b). Exosuit's CLI could also drive Pragtical, since it uses the same method names and error
   codes; that direction is optional.
7. Lower entropy. Every mechanism this replaces is removed, not kept beside the new one.
8. **Full automation coverage (owner goal).** Exosuit instances can be driven entirely through this protocol, without
   computer use or OS-level input. Everything a GUI test or an agent needs is a control method:
   - open, focus and switch workspaces and contexts;
   - create sessions and terminals;
   - read the UI's state;
   - invoke commands;
   - answer dialogs.

   §8.4 lists the methods that make this complete. Only tests that measure real input latency keep using SendInput.
9. **Compatible with the coming Workbench redesign.** Any window will be able to create sessions and terminals in any
   workspace. An instance (a window) is therefore never assumed to have exactly one attached workspace: methods that act
   on workspace content take an explicit `workspace` id (§6).

### Non-goals (this milestone)
- Remote or phone control (Q8=a). The control plane is reachable by same-user processes on this machine only.
- Cross-instance tab transfer (`tab.drag.*`). Exosuit answers `unsupported`.
- Plugin-registered control methods. They can ride the same link later.
- Linux and macOS. The design keeps the Unix socket path working (ExohostPaths already has one), but only Windows is in
  scope.

---

## 2. Pragtical control protocol v1 (reference)

The reference exists at `C:\Users\corbi\projects\pragtical\pragtical`. It contains `data/core/control/*.lua`,
`data/core/instance.lua`, `data/core/instance_discovery.lua`, `src/ctl_main.c`, `src/api/local_transport.c`,
`docs/control-cli.md` and `scripts/test-control-cli.py`. "Added headless control CLI multicall path" is commit 81a18659.
- **Frame.** A 4-byte big-endian length followed by one MessagePack map. The maximum frame is 16 MiB. CODE
  `src/api/local_transport.c:33,109-121,384-396`.
- **Envelope.** Every message has `version`=1 and `kind`. CODE `data/core/control/protocol.lua:1-60`.
  - Request: `{version, kind:"request", id, method, params}`.
  - Response: `{version, kind:"response", id, result|error}`.
  - Event: `{version, kind:"event", sequence, event, data}`.
  - Unknown fields are dropped. CODE `protocol.lua:36-46`.
  - Ids are `"<client_id>:<n>"`. CODE\* `client.lua:9-12`.
- **MessagePack subset.** CODE\* `data/core/control/msgpack.lua`.
  - Integers only, up to 2^53-1; floats are rejected. CODE\* `:99-101`.
  - No bin and no ext. CODE\* `:231-319`.
  - Map keys must be strings.
  - **An empty table encodes as an empty array (0x90).** CODE `msgpack.lua:70-82`.
- **Server rules.**
  - `control.hello` must come first; otherwise the reply is `permission_denied` and the connection closes. CODE
    `server.lua:104-106`.
  - Clients send requests only.
  - Duplicate ids close the connection. CODE\* `server.lua:351-363`.
  - Frame timeout 10 s, idle timeout 300 s, request timeout 10 s, 8 MiB queued per client, 32 accepts or requests per
    poll. CODE `init.lua:100-110`.
- **Errors.** `{code, message, retryable}`. The codes are strings: `invalid_request`, `unsupported_version`,
  `invalid_argument`, `not_found`, `ambiguous_target`, `permission_denied`, `unsupported`, `busy`, `timeout`,
  `internal`. CODE `data/core/control/errors.lua:1-12`. An unknown method answers `unsupported`. CODE\*
  `registry.lua:35-37`.
- **Methods** (CODE `init.lua:116-255`):
  - `control.hello` takes params `{client_id?}` and returns `{protocol_version:1, instance_id, capabilities[]}`. **The
    client cannot name a target instance**: hello validates only `client_id`. CODE `init.lua:119-123`.
  - `control.ping` → `{ok}`.
  - `instance.status` → the descriptor.
  - `window.focus` → `{focused}`.
  - `editor.open {path}` → `{path}`, and emits `document.opened`.
  - `editor.documents` → `{documents:[{document_id,path,modified,saved}]}`.
  - `editor.save {}` or `{path|document_id}`.
  - `project.add {path}` emits `project.changed`.
  - `project.change {path}` waits for a user confirmation and then returns `status:"confirmed"`, or
    `permission_denied`.
  - `tab.drag.*`.
- **Discovery.**
  - Descriptor: `<RUNTIME>/instances/<instance_id>.msgpack`, a raw msgpack map
    `{version:1, instance_id, pid, endpoint, started_at, project_roots[], protocol_version:1}`. CODE
    `data/core/instance.lua:33-43`, `instance_discovery.lua:36-67`.
  - `instance_id` must match `^[%w][%w_.-]*$`. CODE `instance_discovery.lua:40-43`.
  - On Windows, RUNTIME is always `USERDIR/runtime`. CODE `instance_discovery.lua:10-16`. USERDIR is the first of
    `EXEDIR/user`, `PRAGTICAL_USERDIR`, `XDG_CONFIG_HOME/pragtical`, `%USERPROFILE%/.config/pragtical`. CODE
    `src/ctl_main.c:106-127`, `data/core/start.lua:37-40`.
  - The endpoint on Windows is `\\.\pipe\pragtical-<id>`, but clients connect to whatever string the descriptor holds.
    CODE `instance.lua:11-17`, `cli.lua:145`.
- **Health and selection.**
  - The health check is connect-then-close, with no hello. A descriptor that fails it is **deleted**. CODE
    `instance_discovery.lua:116-142`.
  - Selection order: `--instance` exact match; a single exact root match; a single root containing the path (two or
    more give `ambiguous_target`); otherwise the oldest instance, unless `require_project` is set. CODE
    `instance_discovery.lua:156-199`.
  - The CLI passes a target path only for `open` and `project`, so `status`, `focus`, `documents` and `save` always go
    to the oldest instance. CODE `cli.lua:221-265`. This contradicts DOC `docs/control-cli.md:29-31`.
- **Settled fact: one endpoint per instance.** Because hello carries no target and requests have no instance field, a
  server cannot tell which instance a client meant. Several descriptors pointing at one endpoint would all reach the
  same instance. So **for Pragtical clients, exohost must hold one pipe per editor** (§5.4). This settles the brief's
  open point.
- **Launch forwarding.** CODE `data/core/control/launch.lua`, `init.lua:242-275,621-646`.
  - By default the launcher forwards only when the first path lies in exactly one instance's roots
    (`require_project`).
  - The flags are `--reuse-instance` (fall back to the oldest), `--new-instance`, `--instance ID`, `--add-project` and
    `--change-project`.
  - It sends `editor.open` per file, `window.focus` per directory, then a final `window.focus`, and exits 0.
  - If only some paths were accepted, the rest open locally.
- **CLI.** CODE `cli.lua:7-74,177-265`.
  - Multicall: `pragtical-ctl` or `pragtical --ctl`. DOC `docs/control-cli.md:3-13`.
  - Exit codes: 2 usage, 3 discovery or selection, 4 connection or timeout, 5 remote, 6 protocol, 7 internal.
  - JSON errors are `{"error":{code,message,retryable}}`.
  - The default timeout is 5 s.
- **Pragtical's Windows weaknesses** (this matters when pragtical-ctl talks to exohost):
  - Connect calls `WaitNamedPipeA(NMPWAIT_WAIT_FOREVER)`, which can block forever if every pipe instance is busy.
    CODE `local_transport.c:1216`.
  - Its own server recreates its pipe on every idle poll. CODE `local_transport.c:1179-1199`. That affects only
    Pragtical as a server.
  - Its pipes have no `PIPE_REJECT_REMOTE_CLIENTS`, and it does not check server identity. CODE
    `local_transport.c:672-712`.
  - `scripts/test-control-cli.py` uses AF_UNIX only and cannot run against a Windows pipe. CODE\*
    `test-control-cli.py:136,214`.

---

## 3. Design tree (decisions and what hangs off them)

```
D0 exohost is the only control server                               [settled]
├─ D1 main pipe wire: HMPK {op} + control op + editor-attach      [Q1=A]
│   └─ D1.1 link payload: JSON v1 envelopes                       [settled, follows Q1]
├─ D2 Pragtical compat: own runtime dir, PRAGTICAL_USERDIR        [Q2=b]
│   ├─ D2.1 one pipe per editor (forced by Pragtical's hello)      [settled fact §2]
│   ├─ D2.2 raw-byte listener + hub limits in NativeRpcHub         [design §5.4]
│   └─ D2.3 which methods compat pipes allow                       [Q12=a: all]
├─ D3 instance = editor process = one window (windowId)            [settled]
│   ├─ D3.1 workspace is a separate id; roots = all open workspaces [design §6, G9]
│   └─ D3.2 MRU = last focus report                               [§6]
├─ D4 editor link lifecycle                                        [design §7]
│   └─ D4.1 link replaces the editor's registry file              [Q6=a]
├─ D5 quit over the link: modes prompt|recover|save               [Q4=d]
├─ D6 no containing window → MRU, loose tab                       [Q5=a]
├─ D7 launch forwarding: GraphicalMain, 1 s, opt-outs              [Q3=a]
│   └─ D7.1 file:line syntax: suffix + flags                       [Q16=c]
├─ D8 CLI: exosuitctl (Pragtical set + quit) / exohost (verbs + control) [Q7=a, renamed]
├─ D9 remote/phone: local only                                     [Q8=a]
├─ D10 automation files retired                                    [Q9=a]
└─ D11 full automation coverage (G8)                               [owner goal]
    ├─ D11.1 how input is driven: element input in UI queue     [Q10=b]
    ├─ D11.2 snapshot.json → ui.snapshot; file retired           [Q11=a]
    ├─ D11.3 always on, logged, tray "being driven"     [Q13=a]
    └─ D11.4 terminals/sessions: through an editor            [Q15=a]
```

---

## 4. Architecture

```
 pragtical-ctl ──raw v1 frames──▶ \\.\pipe\exosuit-exohostctl-<user>-<instance_id>  (one per editor, Q2) ─┐
 exosuitctl / exohost CLI ─┐                                                                    │
 launcher (GraphicalMain)├─HMPK {op:"control",...}──▶ \\.\pipe\exosuit-exohost-<user> ──────────┤
 MachineClient (editor) ─┘                                                                    ▼
                                                                                  exohost: ControlRouter
                                                                                  ├─ EditorDirectory (links, roots, MRU)
                                                                                  ├─ local methods (hello, ping, status, list)
                                                                                  └─ forwards v1 requests ─┐
 editor process  ◀──────────── one persistent link (HMPK frames, v1 envelopes) ────────────────────────────┘
   └─ EditorControl: open / focus / documents / save / project / quit
```

New modules:
- **exohost `ControlRouter`.** It holds all routing, validation, limits and Pragtical translation. It is a deep module
  with a small surface: `handle(request, origin) -> response`.
- **exohost `EditorDirectory`.** It replaces the editor half of the registry. It holds one entry per attached link:
  `instance_id, pid, started, roots[], context, focusedAt, launch{executable, program, live}`.
- **editor `ExohostLink`** (`src/exohost/ExohostLink.hx`). It owns connect, attach, reconnect and dispatch, and keeps the
  protocol out of `ExosuitApp`.
- **editor `EditorControl`** (`graphical/src/ui/control/`). It is the method table, implemented on `Application`,
  `FileController` and the window.
- **exohost `PragticalCodec`.** Pragtical frame and msgpack-subset encode and decode, plus JSON↔msgpack mapping.

---

## 5. Protocol and framing

### 5.1 Two framings, never mixed on one pipe
- **exohost's main pipe stays HMPK + JSON `{op}`** (Q1=A). Everything that uses it today keeps
  working: the CLI (`ExohostControl`), editor links, service reports (`ExohostServiceLink`).
- **Compat pipes speak Pragtical v1 byte for byte**: 4-byte BE length + msgpack.
- Q1 chose A, so the sniff below is recorded only as a fact for a possible later move to option C.
- **An unambiguous sniff exists.** A Pragtical frame starting with the byte 0x48 (`H`) would declare a
  length ≥ 0x48000000, about 1.2 GB. That is far above the 16 MiB limit and so invalid. The first four bytes `HMPK`
  therefore never begin a valid Pragtical frame, and one pipe could accept both framings safely.

### 5.2 The `control` op (main pipe)
```
request  {op:"control", version:1, client_id, method, params,
          target?:{instance_id?, path?, new_window?:bool, require_match?:bool}}
response {ok:true, instance_id, result}  |  {ok:false, error:{code,message,retryable}}
```
- The method names, params, results and error codes are Pragtical's (§2). Exosuit extensions use an `exosuit.`
  prefix: `exosuit.quit`, `exosuit.instances`.
- Routing is in the envelope, not in params, so params stay byte-compatible with Pragtical's.
- exohost answers some methods locally: `control.ping`, `instance.status` (from the directory), and `exosuit.instances`
  (the list). It forwards the rest to the routed editor.
- Over JSON, an empty `[]` coming from Pragtical's encoder is accepted wherever a map is expected (§2). Integers
  stay integers; no floats are sent to Pragtical clients. `started_at` is in seconds. `focusedAt` is an integer number
  of milliseconds and appears only in Exosuit extensions.

### 5.3 The editor link (main pipe, upgraded by `editor-attach`)
```
editor → exohost  {op:"editor-attach", version:1, instance_id, pid, started, roots[], context, focusedAt,
                launch:{executable, program, live?}, capabilities[]}
exohost   → editor {ok:true, exohost:{pid, startedAt}}
then, both ways, one JSON v1 envelope per HMPK frame:
  exohost → editor:  request  {version:1, kind:"request", id, method, params}
  editor → exohost:  response {version:1, kind:"response", id, result|error}
                  event    {version:1, kind:"event", sequence, event, data}
                  e.g. event "exosuit.state" {roots, context, focusedAt, dirtyCount}
```
- exohost forwards a request with a fresh id, maps the response back to the original id, and fans events out to
  subscribers. Because the envelope is the same on both sides, exohost routes; it does not translate.
- The link payload stays JSON (D1.1). Pragtical's msgpack is produced only at the compat-pipe edge.
- **Request timeout.** exohost gives the editor 10 s (Pragtical's default, CODE `init.lua:108`) and then answers
  `timeout` with retryable=true.
  - `project.change` and `exosuit.quit` can take longer while the user decides, so they use a 300 s deferred timeout,
    the value Pragtical's launcher uses (CODE `launch.lua` request for project.change).
  - **The editor must never block its UI thread on the link.** It polls the link once per frame through its existing
    event pump (`ExohostLink.poll`).

### 5.4 Compat pipes (Pragtical clients)
- exohost listens on `\\.\pipe\exosuit-exohostctl-<user>-<instance_id>` for each attached editor, and closes it when the link closes.
- On that pipe exohost answers `control.hello` itself with `{protocol_version:1, instance_id, capabilities}`. It forwards
  the other methods as in §5.2, with the target fixed to that editor.
- It tolerates the connect-then-close health probe.
- It enforces Pragtical's limits (§2) and its rules: hello first, requests only, a duplicate id closes the
  connection.
- **Changes NativeRpcHub needs** (D2.2):
  - `listenBytes`: an accepted stream that is not wrapped in `NativeRpcTransport`.
  - Raise or split the 4-listener cap and the 32-stream cap. N editors already use N streams for links and N
    listeners for compat pipes, on top of relay attaches and CLI calls.
  - Option: a second hub owned by ControlRouter with its own caps (e.g. 64 listeners, 128 streams).
- **Security is the same as the main pipe**, since the same nativekit listener creates these pipes: user-only DACL,
  remote clients rejected, first-instance flag.

---

## 6. Identity, workspaces and routing

- **Instance** = one editor process = one OS window. `instance_id` = the existing `windowId` `w<pid>-<secs>`.
  It already matches Pragtical's id pattern, is unique per process, and is already what `--context` windows and exohost
  records use.
- **The instance and the workspace are separate identities** (G9). A window has one active context, a
  `machine/workspace/group` key (`ContextKey`), and it may hold sessions, terminals and tabs in other workspaces.
  - The attach and state messages therefore carry `workspaces: [{id, roots[], active:bool}]`, not one set of roots.
  - Any method that acts on workspace content takes an optional `workspace` id, which defaults to the active context.
  - No method assumes that one window is attached to exactly one workspace.
- **Roots** = the union of the roots of every workspace the window has open, sent on attach and on every change.
  Pragtical's descriptor `project_roots` gets the same union. A folderless workspace contributes no roots, so a window
  that has only folderless workspaces is reachable only through MRU or `--instance`.
  - The routing preference among windows (step 3 below) prefers a window whose **active** workspace contains the path
    over one where that workspace is merely open.
- **Containment** uses `PathKey.within`: segment by segment, case-insensitive on Windows. It is not the case-sensitive
  `LanguageController.projectFor`.
- **MRU** = the largest `focusedAt` (each window reports focus in `exosuit.state`).
- **Routing algorithm** in ControlRouter, used by exosuitctl and launch forwarding:
  1. `--instance ID`: that editor, or `not_found` (exit 3).
  2. `--new-window`: ask the MRU editor to spawn a sibling (it already knows how, through `NewWindow.open`), wait for
     the new link, then send to it. With no editor running, `not_found` (exit 3), or the launcher opens locally.
  3. A path: editors whose roots contain it. The deepest root wins; then a window whose active workspace contains it;
     then the MRU of those editors. This is deliberately not Pragtical's `ambiguous_target`.
  4. No editor contains it (Q5=a): the MRU editor. The file opens there as a loose tab and the window's workspace does
     not change.
  5. For commands without a path (focus, documents, save, status): the MRU editor. Pragtical picks the oldest.
- **pragtical-ctl routes on the client side** by reading descriptors, so it keeps its own rules: the oldest instance,
  and `ambiguous_target`. That is acceptable for a compatibility client.

### 6.1 Alignment with the Workbench redesign (decided by the owner)
- **exohost is always on.** There is no exohost-off mode. Consequences:
  - Every editor links.
  - exohost not answering is a fault, not a configuration. The editor and the CLI start it (`ensureDaemon`).
  - Launch forwarding never needs a "exohost is off" branch.
  - Tests still isolate through `EXOSUIT_EXOHOST_HOME`, which gives a separate pipe and home.
- **Folder-only mode is removed.** Every folder belongs to a workspace, so routing always has workspace ids and roots,
  and editors never publish a bare folder root without a workspace.
  - `project.add {path}` adds the folder to the window's active workspace.
  - `project.change {path}` opens the workspace that holds the folder, creating one if none does
    (`openFolderWorkspace`).
- **One workspace-service process per running workspace, plus one warm spare** (Workbench Q4, decided).
  - exohost holds one pre-started spare service process, but only while at least one editor window is open (Workbench
    Q9, decided). With no editor open, a start requested by exosuitctl or by the phone is a normal one-process start,
    without the spare.
  - Editor windows remain the only control-plane instances. Service processes, the spare included, never link as
    instances and are never routing targets. There is no spare editor.
- **The full action menu on idle rows** means T4 methods must work against an idle workspace. `terminal.create
  {workspace}` on an idle workspace starts its service (from the warm spare when one exists) and then creates the
  terminal. The method answers after the terminal exists, under the 10 s request timeout.
- **Start failures are errors, never queues (Workbench Q11).** If a session or terminal failed to start,
  `terminal.send`, `agent.send` and every other input method aimed at it fail at once with `internal`, carrying the
  start error as the message and retryable=false. Nothing is queued.
  - In the UI, text the user typed stays as an unsent draft beside the cause and a Retry action, and is never sent
    automatically.
  - Automation clients call `terminal.restart` (or the session's retry) explicitly, then send again.
- **Opening from the catalog snapshot.** `exosuit.workspace.open` and `exosuit.context.switch` answer once the window
  shows the workspace from its catalog snapshot (the service's on-disk file), not when its service is ready.
  `state.get` exposes `serviceReady` so tests can wait for the live state.
  - The catalog snapshot is unrelated to `ui.snapshot`, which lists UI elements. The names are kept distinct
    everywhere.

---

## 7. Editor ↔ exohost link lifecycle

| Situation | Behaviour |
|---|---|
| Editor starts, exohost running | `ExohostLink` connects and attaches as the window starts (`GraphicalMain`). |
| Editor starts, exohost not running | `ensureDaemon()`. Retry the connect every 0.5 s for 10 s, then every 5 s forever. A failed pipe connect is cheap. |
| Isolated exohost (tests) | Every editor links. Tests link to an isolated exohost (`EXOSUIT_EXOHOST_HOME` hashes the pipe name, `ExohostPaths.endpoint`). |
| exohost restarts or crashes | The link drops. The editor reconnects with backoff and re-attaches with its current state. At start exohost deletes every compat descriptor it owns and republishes each one on attach, so no stale descriptor lives longer than an exohost restart. |
| Editor exits normally | The link closes. exohost drops the entry, closes the compat pipe and deletes the descriptor. |
| Editor crashes | The pipe breaks, same as a normal exit. The 10 s inventory rescan catches anything missed. |
| Editor hangs (UI thread stuck) | The link stays open. Requests answer `timeout` (retryable). Quit reports "not responding" instead of "still open". |
| exohost idle exit | A linked editor prevents an idle exit (`ExohostDaemon`). |
| Two exohosts (isolated test + real) | Each has its own pipe name and home, so their links never cross. |

Pragtical's own launcher and transfer code would connect to every descriptor it finds (CODE `launch.lua`,
`init.lua:468-471`). That only matters if descriptors are written into Pragtical's own folder, which Q2=b rules out.

---

## 8. Methods, events, CLI

### 8.1 Methods (editor side)

| Method | Exosuit implementation | Notes |
|---|---|---|
| `control.hello`, `control.ping`, `instance.status` | exohost, local | status = the descriptor plus Exosuit fields (context, focusedAt) |
| `window.focus` | native raise: restore if minimised, then activate (`nk_window_restore`, `nk_window_activate`) | Windows grants the foreground only to the foreground process or one it allowed, so a raise may only flash the taskbar (UNVERIFIED in practice). |
| `editor.open {path, line?, column?}` | the window's `openArgument`, then the cursor for line/column | `line`/`column` are an Exosuit extension that Pragtical ignores. Emits `document.opened`. |
| `editor.documents` | `DocumentManager.documents` with `.dirty` | `document_id` = `document:<n>`, stable per process |
| `editor.save {}` / `{path\|document_id}` | `FileController` | |
| `project.add {path}` | attach the folder to the window's workspace | Emits `project.changed` |
| `project.change {path}` | `openFolderWorkspace` / `switchToContext` | **It needs no confirmation.** A context switch keeps dirty buffers, carets and scroll position per context. It answers `{path, status:"confirmed"}` at once, so Pragtical clients see what they expect. |
| `exosuit.quit {mode: prompt\|recover\|save}` | prompt: `FileController.requestQuit`; recover: flush the recovery store and close without asking; save: `saveAll`, then recover untitled documents, then close | Answers `{closing:true}` once the editor has committed to closing, or `permission_denied` when the user cancelled in `prompt`. exohost takes link closure as proof of exit. Defaults: tray Quit `recover`; a quit of one window `prompt` (Q4=d). |
| `tab.drag.*` | not implemented | `unsupported` |

Events: `document.opened`, `project.changed` (Pragtical), and `exosuit.state` (link only).

### 8.2 CLI
- **Commands.** It accepts Pragtical's command set exactly: `list | status | focus | open PATH... | documents | save |
  project add|change PATH | call METHOD [JSON]`. Exosuit adds `quit [--instance]`.
- **Options.** `--instance`, `--project`, `--timeout` (seconds, or with an `ms`/`s` suffix; default 5 s), `--output
  text|json`. Exosuit adds `--new-window`.
- **Exit codes** are Pragtical's: 0 ok, 2 usage, 3 discovery or selection, 4 connection or timeout, 5 remote error, 6
  protocol, 7 internal. Text errors go to stderr as `exosuitctl: <code>: <message>`. JSON errors go to stdout as
  `{"error":{...}}`.
- **Two invocation formats (Q7=a).** `list` and `status` exist on `exohost` with other meanings (`ExohostMain`), so the
  program name supplies the context:
  - `exosuitctl <command>` is exactly Pragtical's command set plus `quit`. Its `list` lists instances; its `status` is
    `instance.status`.
  - `exohost <verb>` keeps every existing verb (`list` lists processes, `status` is the daemon's status) and gains `open`,
    `focus`, `documents`, `save`, `project` and `call`, which have the same semantics as in exosuitctl.
  - ExohostMain picks the command table from the basename of argv[0], or from a first argument `--ctl` (Pragtical's
    portable spelling, DOC `docs/control-cli.md:7-13`).
  - There is no Windows exe, so `exosuitctl` is a shim that runs exohost with `--ctl` (`scripts/exosuitctl.cmd`,
    `scripts/exosuitctl`).
- **Startup cost.** Every `exosuitctl` call starts `hl` with exohost's bytecode. That cost has not been measured
  (UNVERIFIED); it matters for a `GIT_ASKPASS` through exosuitctl.

### 8.3 Launch forwarding (Q3=a)
- Early in `GraphicalMain` (`LaunchForwarding`), before the window is made: when there are open paths, and no
  `--new-window`, send `{op:"control", method:"editor.open", target:{path}}` for each path, then `window.focus`.
- The budget is 1 s in total. Any connection failure, timeout or `not_found` means the process starts its own window.
  Accepted paths are removed from the list; the rest open locally, as in Pragtical (CODE `init.lua:635-646`).
- The forwarding process must call `AllowSetForegroundWindow(editor pid)` before it exits, because it is the foreground
  process.
- In live mode (`run.py --live`), for a capture or benchmark, and for a window started for a context
  (`--context=`), forwarding stays off: those always want their own window.

### 8.4 Full automation coverage (G8)

**Principle.** Every user-visible action already has a code path: commands in `CommandRegistry`, controller
methods, and the Workbench's row actions (`WorkbenchActions`). Control methods call those same paths, so a test drives
the product's logic rather than a test-only copy.

**Method plan.** All names are under `exosuit.`. Every method that acts on workspace content takes an optional
`workspace` id.

| Tier | Methods | Backed by |
|---|---|---|
| T0 basics (§8.1) | `editor.open`, `window.focus`, `editor.documents`, `editor.save`, `project.*`, `exosuit.quit` | §8.1 |
| T1 read state | `ui.snapshot` → elements, focus, viewport and state; event `ui.changed {seq}`; `state.get {path?}` → `automationState` | `devtools.UiSnapshot`, the window's `automationState` |
| T2 commands | `commands.list {available?}`, `command.run {name, args?}` | `CommandRegistry.available/perform` |
| T3 workspaces, contexts, windows | `workspaces.list` (exohost, local, from `machine`), `context.switch {context}`, `workspace.open {id}`, `window.new {context?}`, `folder.add {path, workspace?}` | `switchToContext`, the Workbench's open, `NewWindow.open`, attach folder |
| T4 sessions and terminals | `terminals.list`, `terminal.create {workspace, group?, program?}`, `terminal.open/rename/stop/restart/close {id}`, `terminal.send {id, text}`, `terminal.read {id, since?}` → `{rows[], cursor{row,col}, scrollback[], sequence}` (Q17=a, rendered text); `agents.list`, `agent.create {workspace, kind}`, `agent.send`, `agent.read` | the editor's workspace clients (RpcTerminalBackend, WorkspaceAgentClient), the same paths as the Workbench actions |
| T5 dialogs | `dialogs.list` → open prompts and pickers; `dialog.answer {id, choice\|paths}` | `DrivenDialogs`: the confirmation and file-dialog callbacks behind one seam |
| T6 element input | `ui.activate {element_id}`, `ui.focus {element_id}`, `ui.type {text}`, `ui.key {chord}`, `ui.scroll {element_id, notches}`, `ui.drag {from, to}` delivered as synthetic events in the UI's input queue, not OS input | the uikit input path (Q10=b: synthetic events in the UI's own queue; never OS input; never raises the window). Q19=b: real input always wins; an injected event is held while real input arrived in the last ~1 s, and the call answers `busy` (retryable) after waiting 5 s |

**When it is complete.** Every scenario under `docs/benchmarks/perf-harness/gui_scenarios/` can be expressed in T1–T6
without SendInput, except those that measure real input latency. The proof is to port each scenario: a scenario that
cannot be ported names the missing method.

**Consequences.**
- GUI tests no longer move the real mouse, so they can run in parallel and unattended. The one-at-a-time rule then
  applies only to real-input latency captures.
- `ui.snapshot` can be large: up to `UiSnapshot.ELEMENT_LIMIT` (4000) elements, at roughly 100 bytes of JSON each
  about 400 KB. The editor link and exohost's pipe therefore allow 8 MiB per message (`ExohostLink.MAX_MESSAGE_BYTES`).
  Pragtical's 16 MiB frame limit is not an issue.
- A wedged UI thread blocks every automation method. The link's `timeout` makes that visible instead of hanging a
  test.

---

## 9. What stays outside the control plane

- **SendInput** stays only in the real-input latency tooling (the input-latency work and `measure.ps1` captures).
- **Workspace service pipes.** They belong to the workspace RPC plane; exohost hands them out with `workspace.open`.
- **The devtools pipe.** It carries a different, binary inspection protocol.
- **The registry for services and hosts.** exohost only stops those processes; a file drop works while exohost is down.

---

## 10. Security

- **Who may connect.** Only the current user's SID (DACL), and no remote clients. A squatter cannot share a name exohost
  created first. All of this is NativeKit's local listener. The compat pipes inherit it.
  - It is stricter than Pragtical's own pipes, which do not reject remote clients.
- **What they may send.** Any same-user process can already tell exohost to `quit` or `kill` today. The control plane
  adds open, save and focus, and quit for a single editor. Both sit at the same trust boundary: the user's own
  processes.
  - No token is used. Pragtical has none, and a token would break pragtical-ctl compatibility.
  - exohost logs the peer pid (`peerProcess()`) for each mutating request.
- **Automation methods raise the stakes, not the boundary.** `terminal.send`, `command.run` and `ui.type` let any
  same-user process type into terminals and run commands. Any agent running in an Exosuit terminal could then drive
  the user's daily editor.
  - This is no new privilege: a same-user process can already SendInput into the window, write files, or run the same
    programs.
  - It does make misuse easy. Q13=a: the methods are always on, with no flag and no prompt; visibility is the safeguard.
  - exohost logs every T4–T6 call with the peer pid and its process name, and the tray shows that an instance "is
    being driven".
- **Same SID in another logon session** (RDP, `runas` as the same user). The DACL admits it. The pipe name is
  per-user, not per-session. UNVERIFIED whether that matters to the owner; it is listed in failure modes.
- **Integrity levels.** If exohost ever runs elevated, the pipe's default mandatory label would block medium-integrity
  clients. UNVERIFIED. exohost is started unelevated by the editor today.
- **Squatting on compat pipe names.** A same-user process could pre-create `exosuit-exohostctl-<user>-<id>` for a future id. Ids are
  pid plus seconds, so they are guessable. The first-instance flag then makes exohost's listen fail.
  - Mitigation: on a listen failure exohost drops the descriptor and logs it.
  - pragtical-ctl does not verify the server, but a squatter would have to be the same user anyway.
- **Descriptors.** They are written atomically (tmp + rename, as Pragtical does) into a folder that
  `ExohostPaths.prepare()` makes private.
- **Path arguments.** `editor.open` opens any path the user can read. The same user could open it directly, so this is
  no escalation.
- **Phone and remote.** Not exposed (Q8=a). If it is added later:
  - a capability next to `machine.directory` in the device handshake (`MachineDeviceSession`);
  - a grant in `MachineGrants`;
  - remote requests would carry the device id, and exohost would allow only an explicitly granted method list (open,
    focus, documents, and never quit or save).

---

## 11. Compatibility with Pragtical

| Direction | Works | Caveats |
|---|---|---|
| pragtical-ctl → Exosuit | list, status, focus, open, documents, save, project add/change, call | Its routing is the oldest instance and `ambiguous_target`. Focus may only flash (§8.1). It needs `PRAGTICAL_USERDIR=%LOCALAPPDATA%\exosuit\exohost` (Q2=b). With an isolated exohost, set it to that `EXOSUIT_EXOHOST_HOME`. It hangs forever if a pipe has no free instance (Pragtical bug, `local_transport.c:1216`). Nativekit uses unlimited instances, so this should not happen (UNVERIFIED). |
| exosuitctl → Pragtical | optional | It would need Pragtical's descriptor reader and the raw v1 client. Out of scope unless the owner wants it. |
| Pragtical's own editor ↔ Exosuit descriptors | only if descriptors are in Pragtical's folder | Pragtical's `pragtical <file>` would forward into an Exosuit editor whose roots contain the file. Its tab drag would probe Exosuit pipes and get `unsupported`. |
| Fake-server tests | port the cases | `test-control-cli.py` is AF_UNIX only. Port its cases to a haxeon test that runs against a Windows pipe. |
| Pragtical's own server on Windows | n/a | Its pipe recreation is Pragtical's bug and does not affect exohost. |

Msgpack subset rules Exosuit must follow at the compat edge:
- integers only, within ±2^53;
- no floats, no bin, no ext;
- string keys only;
- accept `[]` where a map is expected;
- reject trailing bytes;
- depth ≤ 32.

---

## 12. Failure modes

| Failure | Effect | Handling |
|---|---|---|
| exohost not running when the CLI runs (crash, or before first use) | exit 4 (connection) | exohost is always on by design, so this is a fault. The CLI starts exohost (`ensureDaemon`), retries for 2 s, then exits 4. The launcher starts its own window. |
| exohost down, editor running | no link | The editor retries. Forwarding falls back to a new window. |
| Editor UI thread hung | requests time out after 10 s | retryable `timeout`; quit reports "not responding" |
| Editor dies mid-request | the link breaks | exohost answers `internal` "editor exited" (retryable=false) |
| Stale descriptor (exohost crashed) | pragtical-ctl's health probe fails | pragtical-ctl deletes it (its own code). exohost also deletes all its descriptors at start. |
| Two editors with the same root | routing tie | the MRU editor wins (exosuitctl); `ambiguous_target` (pragtical-ctl) |
| Forwarding target closes between routing and open | `internal` or `not_found` | The launcher opens locally within its 1 s budget |
| Hub caps reached | accept is closed | exohost's hub allows 256 connections; count links in `exohost status`. |
| Quit while a save dialog is up | `exosuit.quit` deferred | 300 s deferred timeout. The tray shows "waiting for <window>". |
| Live-mode patch reloads EditorControl | the link must survive the code swap | `ExohostLink` lives in a static (`ExohostLink.instance`), so a live patch keeps the connection. |

---

## 13. Test plan

All runs go through `docs/benchmarks/perf-harness/run-guarded.ps1` with timeouts of 2–4× the expected time. State is
isolated with `EXOSUIT_EXOHOST_HOME=<temp>` and `PRAGTICAL_PORTABLE=temp`. Native tests are built in Release.

| Part | Proof |
|---|---|
| PragticalCodec | Unit tests: round trips; integer bounds (±2^53, rejection beyond); trailing bytes; an oversized frame (>16 MiB); depth 33; a frame split at every byte offset; an empty `[]` used as params; the HMPK/Pragtical sniff, if Q1 picks B. These are the M13 acceptance list. |
| ControlRouter | Table tests without pipes: routing over the instance flag, nested roots, ties (MRU), case-insensitive Windows paths, folderless editors and the Q5 fallback. Errors map to the right code and exit code. |
| Editor link | A headless exohost plus a fake editor link (a haxeon test program): attach; state updates; a request round trip; timeouts; the link closing mid-request. |
| exohost restart | Start an editor, kill exohost, start exohost: the editor re-attaches within 2 s and the descriptor is republished. An editor started before exohost attaches after `ensureDaemon`. |
| Quit | A real editor with a dirty document under each Q4 mode. exohost reports closed, cancelled or not responding. |
| CLI | Every command against the fake editor and against one real editor; exit codes 2–7 forced one by one; `--output json` shape. |
| Launch forwarding | Two launches: the second exits 0 within the 1 s budget and the file is open in the first. Roots in two windows route to MRU. `--new-window` gives a new window. With exohost not running, the second launch opens its own window. |
| Pragtical compat | `pragtical-ctl.exe` from `pragtical/build-msvc` (if built; UNVERIFIED) against isolated exohost: list, status, open, documents, save; the health probe; the descriptor schema accepted by `instance_discovery.read`. |
| Security | A connection from another user (or a test ACL) is refused. A remote client is refused (the flag). The peer pid is logged. |
| Live mode | Edit EditorControl under `run.py --live`; the link survives (`python scripts/live-status.py`). |
| Automation coverage (G8) | Each `gui_scenarios/` scenario runs on control calls, two at once, with the real mouse untouched; a scenario that cannot names the method it lacks. T4: create, send to, read and close a terminal in a workspace other than the window's active one (G9). |

---

## 14. Settled details
- **Line and column (Q16=c).** `path:line[:col]` is recognised only when the suffix is all digits and the full string
  is not an existing file. `C:\a.txt` is a path and `C:\a.txt:12` is line 12. Flags are `exosuitctl open --line --column`
  and `exosuit --goto N[:N]`. Launch forwarding sends `line` and `column` in `editor.open`.
- **Events (Q18=a).**
  - On the main pipe, `exosuit.events.subscribe {names[], instance?}` must come first. The connection then stays open,
    and exohost pushes only the subscribed events.
  - `exosuitctl watch [EVENT...] [--instance]` prints one JSON object per line until interrupted. Its exit codes follow
    §8.2.
  - Event names: `document.opened`, `project.changed`, `exosuit.state`, `exosuit.ui.changed {seq, at, frame}`,
    `exosuit.terminal.output {id, sequence}`, `exosuit.machine.changed`, `exosuit.instance.attached` and
    `exosuit.instance.detached`.
  - The Pragtical pipes push only `document.opened` and `project.changed`, as Pragtical does.
- **Terminal reads (Q17=a).** Rendered text comes from the editor's terminal model. `since` is the scrollback sequence
  number, so a client can tail a terminal with `terminal.read` plus `exosuit.terminal.output` events.
- **Real input wins (Q19=b).** The editor timestamps the last real input event. Injected events wait while it is
  under ~1 s old, and give up after 5 s with `busy`, retryable=true. The tray's "being driven" indicator shows while
  injected input flows (Q13=a).
- **`command.run` and prompting commands.** `command.run {name, args?}` performs the command. If the command opens a
  prompt or picker, the call answers at once with `{prompted: dialog_id}`. The client finishes the interaction with
  `dialog.answer` (T5), so no command needs a special automation path.
- **Earlier settlements.** `project.change` needs no confirmation. exosuitctl keeps MRU routing; exact parity with
  Pragtical's oldest-instance rule is not pursued.
