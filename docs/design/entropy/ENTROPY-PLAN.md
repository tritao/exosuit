# Entropy plan: a simpler, faster Exosuit

2026-11-15. Branch `entropy-1115`, off main `a457e3dc` (haxeon `fa128931e`). Analysis and plan only: no product code
was changed. The yardstick is [INTENT.md](INTENT.md). The evidence was in the area maps under `map/` (removed after the pass; see git history);
each claim below names the map section or the file and line that carries it. Owner decisions still needed are in
[QUESTIONS.md](QUESTIONS.md) (E1 to E8); the plan marks the steps that wait on one.

How this was made: eight helpers mapped one area each from the code, read-only. The lead read the central files whole
or in large parts (`GraphicalMain`, `ExosuitApp` attachment and pump regions, `LocalWorkspaceClient`,
`WorkspaceServiceTarget`, `AgentManager`, `AgentMain`, `SuitClient`, `SuitDaemon`, `TerminalHosts`) and spot-checked
map claims against the code. Nothing was built or run: the worktree has no built compiler or app, and a clean build
only to re-measure numbers recorded three days ago was not worth its cost. Timings are therefore the recorded ones
(§4), and Step 0 adds the missing marks before anything is changed.

## 1. Summary

Exosuit is about 99,000 lines of product code (src 40,273; graphical 27,937; agent 16,572; suit 6,918; plus android,
relay, web), 43,961 lines of tests, 14,116 of scripts and 31,174 of docs. Roughly 48,000 lines of code, tests and
scripts were added in the 18 days since 2026-10-28.

The complexity has one root cause. Each new model was added beside the previous one instead of replacing it, so
today the same job is done several ways and each way has its own state, timer and test:

| Job | Ways it is done today | Ways after this plan |
|---|---|---|
| Know which workspaces exist and what is in them | 4 copies of the group tree in the editor; `machine.json`; `.exosuit-workspace` files; `managers/*.json` | suit's `machine.json` plus one catalog per workspace |
| Find a running service | `endpoint.json`, `--discover` helper, suit `machine`, `--machine` helper | ask suit over the link |
| Start a service | editor helper → launcher → manager → daemon (4 callers); suit for remote; suit for relay hosting | suit starts one process |
| Connect to a workspace | attached client, catalog watch, terminal pool (3 state machines) | one `WorkspaceLink` class |
| Learn that something changed | 14 timers in the editor pump, 50 ms file polls in the manager, 10 s full inventory in suit | pushes on open connections |
| Host a workspace for a device | service dials relay; service through suit bridge; suit machine remote | suit machine remote |
| Run without suit | `EXOSUIT_SUIT=off`, auto-off for temporary state, isolated | isolated suit home only |
| Hold an agent conversation | integrated chat (about 12,000 lines) and provider terminals (about 650) | owner decides (E1) |
| Drive the editor from outside | command files, `snapshot.json`, `pick-folder.txt`, WM_CLOSE, registry files | protocol methods on the suit link |

Approximate lines removable (production code, estimates from the maps, overlaps taken out):

| Bucket | Removed | Needs |
|---|---|---|
| Decided by INTENT and the two approved designs | about 14,000 | nothing; new code needed is about 3,500, so net about −10,500 |
| Browser client and what only it uses | about 2,400 | E2 |
| Integrated chat mode | about 12,000 (plus 1,726 in haxeon packages) | E1 |
| Tests and scripts that pin removed mechanisms or run nowhere | about 16,000 | follows the code |
| Docs that describe removed or finished things | about 14,000 of 23,078 | follows the code |

So product code falls from about 99,000 to about 88,000 lines on the decided part alone, and to about 74,000 if the
owner also retires the browser client and chat mode. Tests fall from about 44,000 to about 30,000.

## 2. Target architecture

```
                       ┌──────────────────────────────────────────────────────────┐
                       │ suit  (one per user; the only server; tray)             │
                       │  machine.json: workspaces, folders, names, order         │
                       │  EditorDirectory: one entry per linked editor window     │
                       │  ServiceTable: what it started (workspace → pid, pipe)   │
                       │  ControlRouter: suitctl / Pragtical v1 / automation      │
                       │  MachineRemote: pairing and relay for devices            │
                       └───▲───────────────▲──────────────────▲──────────────────┘
        persistent link    │   spawn, stop │                  │ relay (Noise, stream frames)
     (push: machine.changed│   (one process│                  │
      quit, control, events)   + 1 spare)  │                  │
┌──────────────────────────┴───┐   ┌───────┴───────────────┐  │   ┌─────────────────────────┐
│ editor window (one process)  │   │ workspace service     │  └───│ phone app               │
│  SuitLink                    │   │ (one process, no      │      │  same ExosuitApp, same  │
│  WorkspaceLinks: id → link   ├──▶│  manager, no launcher)│◀─────│  WorkspaceLink class    │
│  focus = ActiveContext       │   │  SQLite catalog       │ via  │  over a relay stream    │
│  Workbench tree (one rule)   │   │  files, agents        │ suit └─────────────────────────┘
│  editor shell                │   │  terminal manager     │
└──────────────────────────────┘   │  catalog-snapshot.json│
        named pipe, CATALOG watch  └───────┬───────────────┘
        and per-tab streams                │ named pipe per terminal (ATTACH, INPUT, END)
                                   ┌───────┴───────────────┐
                                   │ terminal host (one per│
                                   │ terminal; owns ConPTY;│
                                   │ outlives the service) │
                                   └───────────────────────┘
```

In words:

- **suit is always there.** The editor starts it if needed and keeps one link to it. The link carries the machine
  list as pushes, the quit request, the control and automation methods and opt-in events. suit knows editors by their
  links and services by having started them. Its inventory is those two tables; a process scan remains only behind
  "Quit everything" as the safety net that makes suit the final arbiter.
- **A workspace is a row in `machine.json` plus a state directory.** Nothing else defines one: no
  `.exosuit-workspace` file, no folder-keyed identity, no per-build manager choice.
- **A running workspace is one process.** suit starts it (or hands out the warm spare) and answers the editor's
  `workspace.open` with a pipe name. Ready means the pipe accepts a connection. The service does everything the
  manager did that is still needed (lock, pick nothing, write nothing for discovery) and stops itself after 10 minutes
  with no link and no busy agent.
- **An idle workspace is a file.** `catalog-snapshot.json`, written by the service on change and on exit, read by the
  editor to draw rows without starting anything.
- **The editor holds one `WorkspaceLink` per workspace it shows live.** A link is one connection with one catalog
  watch. The focus (`ActiveContext`) says which link the shell's Files, Search, Changes and new tabs use. There is no
  "attached" workspace and no second kind of client for the others. The phone uses the same class over a relay stream.
- **Terminals live in hosts, always.** One host per terminal owns the ConPTY and its screen. The service is a
  directory of hosts and a relay for views. A service restart, an editor restart and a polite suit quit leave them
  running; the next service adopts them.
- **"VS Code mode" is a presentation.** `exosuit <folder>` asks suit for the workspace that holds the folder, or
  creates a one-folder workspace, and opens a window focused on it with the Workbench collapsed. `exosuit <file>`
  forwards to the most recently used window. Both are `launch` calls on the control plane (suitctl TDD step 4), not
  a mode.

## 3. What is junk, and what replaces it

Lines are estimates of lines deleted. "Map" names the section with the file-and-line evidence.

### 3.1 Rejected-model code (INTENT decides; no question)

| # | What | Why it is junk | Lines | Replacement | Map |
|---|---|---|---|---|---|
| D1 | Launcher → manager → daemon chain: `AgentManager` (1,434), `AgentMachine` (127), `AgentRelayBootstrap` (57), `WorkspaceStopRequest` (31), `scripts/run-agent.py` (52), `legacy` manager kind | INTENT 5: one process per workspace. The manager polls four files every 50 ms for the service's whole life and restarts nothing on a crash | about 1,650 (about 80 move into the daemon) | suit spawns the service; ready = pipe connect | workspace-service §2, §6 |
| D2 | Editor side of the chain: discover, launch, configure-relay and update helpers in `LocalWorkspaceClient`; `WorkspaceStarter` (230); `LocalServiceDescriptor` (72); `endpoint.json` re-read every 25 ms | Same. Four ways to start and four ways to locate a service | about 1,000 | `workspace.open` on the suit link returns a pipe name | workspace-client §2, §11 |
| D3 | Attached-versus-foreign split: `WorkspaceConnections` (275), `WorkspaceCatalogWatch` (200), `LocalTerminalWorkspacePool` (127), the two tree projections, `pendingContextTarget`, eager budget, `startingWorkspaces` | INTENT 4: one link per workspace plus a focus | about 800 in the client, about 470 in the Workbench | `WorkspaceLink`, one projection | workspace-client §5; workbench-ui §5, §6 |
| D4 | suit-off: `SuitMode.Off`, auto-off for temporary state, `MachineClient.enabled` checks (9 in `ExosuitApp`), `disabledForTemporaryState`, the env passed to children | INTENT 3 | about 400 client, about 200 suit | isolated suit home in tests (`EXOSUIT_SUIT_HOME`) | suit §6; workbench-ui §6 |
| D5 | Folder identity: `EXOSUIT_WORKSPACE_IDENTITY=folder`, `select(path)` folder services, folder adoption, `openFolderAsMachineWorkspace` split paths | INTENT 3 | about 125 | a folder no workspace holds becomes a workspace | workbench-ui §6 |
| D6 | Machine view: `MachinePanel` (164), `attachMachine`, `WorkspaceManagerChoices` (77), `--machine` helper every 3 s, seed copy (`--seed-from`, `--from-state`) | Chooses a manager build per workspace: belongs to the chain | about 450 | none (suit tray lists processes) | workbench-ui §6; workspace-client §6 |
| D7 | Registry and request files: editor record + `WindowPresence`, `managers/<key>.json`, `restart-request.json`, `stop-request`, terminal end-request files, `relay-bootstrap.json` poll, `daemon.json` | INTENT 8: the link replaces the registry file; requests travel on connections | about 450 | suit link; END over the host pipe | suit §3; terminals §3 |
| D8 | Automation files: `command.txt` (checked every 50 ms), `snapshot.json`, `pick-folder.txt`, WM_CLOSE quit | INTENT 8, 9 | about 175 deleted, about 75 rewritten as `state.get` | protocol methods | workbench-ui §6 |
| D9 | Remote generation A, when the service hosts itself: `suit/src/suit/relay/*` (1,676), `src/suit/relay/*` (363), service relay dialling, `EXOSUIT_RELAY_VIA_SUIT`, per-workspace pairing status polls | INTENT 11: remote goes through suit. The phone uses only suit's machine remote | about 3,500 if E2 = drop; about 2,300 if the browser is ported | suit `MachineRemote` | remote §2, §6 |

### 3.2 Code with no user

| # | What | Evidence | Lines |
|---|---|---|---|
| U1 | `TransferredMessageConnector` | no caller | 40 |
| U2 | Loopback WebSocket listener, `SessionPreflight`, credential file and port pick in every service; `SessionRpcConnector` | only tests and the browser client connect to it (the browser part waits on E2) | about 230 client + about 150 service |
| U3 | RPCs called only by tests: workspace RENAME (102), OPERATION (103), terminal OUTPUT; `TerminalReplayLog.readBytes` | workspace-service §7, terminals §7 | about 120 |
| U4 | `--always-available`, `--idle-seconds`, `EXOSUIT_AGENT_ALWAYS_AVAILABLE`, `EXOSUIT_AGENT_MANAGED_UPDATES` | no production caller | about 60 |
| U5 | suit `tray-check` verb, `SuitReport.relayText`, test-only ops `test-menu`, `login-toggle`, `relay-pause` as product ops | suit §7 | about 90 |
| U6 | `WorkbenchMachineSelector` (a one-option drop-down with a no-op handler) | workbench-ui §7 | about 60 |
| U7 | `src/scm/fake/*` shipped in the product tree | used by two test suites only | 200 moved to tests |
| U8 | 34 test suites and 39 `test-*` scripts that no runner starts; five scripts with no caller at all | tests §2.2; tooling overview | see §6 |

### 3.3 Code for states that no longer occur

| # | What | Why | Lines | Waits on |
|---|---|---|---|---|
| O1 | `AgentWorkspaceMigration` (1,053) and `retireSeedGroup` (95): run a SQLite open, and sometimes a directory scan and a transaction, on every service start | the migration has run on the owner's state | about 1,300 + 835 test | E5 |
| O2 | Session-file compatibility: `T` tab lines still written on every save, `#legacy` context keys, placeholder machine re-keying; SQLite legacy branches; folder-keyed state identity | same | about 250 | E5 |
| O3 | Build identity and in-place update: `BuildFileCollector`, `--prepare-update`, `--restart`, lifecycle protocol, `WorkspaceUpdatePolicy`, "Workspace connected (another build)", update prompts | built for services that outlive editors of other builds. With terminals in hosts a service restart costs nothing visible | about 550 + editor UI about 100 | E4 |
| O4 | suit's checkout-chain and shared-worker adoption passes | serve dev runs started outside suit; with suit starting services and linking editors nothing is left to adopt | about 190 | none |

### 3.4 The file-backed workspace model (E3)

`.exosuit-workspace` files, `SavedWorkspaceController` (185), `RecentWorkspaces` (38), seven `workspace:*` commands,
welcome-page buttons and the Files-scope toggle are a second definition of "workspace" beside `machine.json`. With
it a window can be in four states (no workspace, file workspace, machine workspace, both). About 400 lines. INTENT 3
says one model; the plan removes it, but it is a visible feature, so it is asked as E3.

## 4. Merges

| # | Today | Becomes | Saves |
|---|---|---|---|
| M1 | Three connection state machines (`LocalWorkspaceClient`, `WorkspaceCatalogWatch`, reset logic in `RpcWorkspaceWorkbenchClient`); 52 one-line delegations; 7 casts of the attachment to `LocalWorkspaceClient` in `ExosuitApp` | `WorkspaceLink`: connect, IDENTITY, CATALOG watch, typed sub-clients as fields | counted in D2, D3 |
| M2 | Four copies of the group tree (replica WATCH/QUERY the UI never reads; terminal LIST 1 s; agent LIST 1 s; catalog watch) | the catalog watch; `WorkspaceReplica` and the two LIST polls go | about 350 |
| M3 | Two tree projections with different orphan and cycle rules | one: orphans go to the root, with a cycle guard (the safer of the two rules) | about 450 with the menu merge |
| M4 | 15 duplicated Workbench jobs: six open-workspace entry points, five folder pickers, five scratch requests, three folder-to-workspace match rules, three create menus | one function each, in a `WorkbenchActions` class | about 250 |
| M5 | Three pipe clients for suit (`SuitControl`, `MachineClient`, Python), three answers to "is the service running", a second inventory and stop job in the CLI | `SuitLink` in the editor; the CLI asks the running suit | about 270 |
| M6 | Stream-frame protocol twice (`StreamMultiplexer`, `MachineDeviceSession`); pairing client twice (phone about 220, browser about 460); two device stores | one of each (the browser copies vanish with E2 = drop) | about 300 to 700 |
| M7 | Three JSONL transports, three `Conversation` classes, two transcript readers across Claude, Codex and Pi | a common base for provider processes | about 850 |
| M8 | Terminal output stored seven times (host emulator, service emulator, 2 MiB replay log, SQLite history, `final.bin`, snapshot pages, view emulator) | host emulator is the source; service keeps only `final.bin` for ended terminals; views keep their own | about 250 |
| M9 | `ExosuitApp` (6,703 lines): 2,560 lines belong elsewhere (source control 1,047, agent tab glue 580, Workbench row actions 386, terminals 267, remote files 228) | `ScmPanelController`, `AgentTabs`, `WorkbenchActions`, `TerminalTabs`, `RemoteFileTabs`; `ExosuitApp` about 3,000 | 0 (moves), but the largest readability gain |
| M10 | Three test runners with two hand-kept suite lists; four Python harness layers; three scripts importing `test-suit-relay.py` as a library | one suite list (a data file both runners read); one harness module; one relay rig | about 500 scripts |

## 5. Speed

No fresh capture was taken (see the top). Recorded numbers, `docs/roadmap/NEXT-PHASE.md` 2026-11-12:

| Path | Recorded | Where the time goes | What removes it |
|---|---|---|---|
| Open a running workspace → connected | 79–128 ms | drop connection and replica, helper-free reconnect, IDENTITY, replica WATCH/QUERY restore | keep the link (Step 7): a switch is a focus change, about one frame |
| Open an idle workspace → connected | 791–1010 ms | two process starts (launcher, manager) then the daemon; `endpoint.json` polled every 25 ms; manager polls READY every 50 ms; migration check; four providers built; Codex `--version` and app-server start | one process from suit, or the warm spare (Steps 5, 6); providers built on first use (Step 10) |
| Launcher run → endpoint | 1.08 s | same chain | same |
| Editor start → first frame | 483 ms | not broken down | Step 0 marks |
| Start with last workspace, cold → connected | 1,613 ms | chain plus restore | snapshot draws rows at first frame (Step 6) |
| suit `machine` reply | 440–490 ms | suit runs a full inventory (every process, environments of 22 executable kinds) before answering | answer from memory; push changes (Step 4) |
| Click a workspace in another window state → frame; New Agent Session → can type | not measured | | Step 0 adds marks; Steps 2, 6, 7 |

Work done while nothing changes (measured by reading the timers, not by profiling):

| Where | Timer | Fix |
|---|---|---|
| Editor pump | `command.txt` exists-check every 50 ms | Step 9 |
| Editor | agent LIST every 1 s with a JSON-stringify compare; terminal LIST every 1 s; one agent read every 0.2 s round-robin | Step 3: the catalog CHANGED push already covers these |
| Editor | suit `machine` every 5 s (1.5 s when eager); Machine view helper process every 3 s | Step 4 push; D6 |
| Editor | pairing and relay STATUS per workspace every 1 s, replies discarded when suit hosts | Step 8 |
| Editor | `retainRoots` rebuilt every loop turn (`GraphicalMain`) | Step 11: rebuild on change |
| Service | main loop `events.wait(0.01)`; `relay-bootstrap.json` every 500 ms | Step 5: wait on events with a long timeout; file gone |
| Manager | stop signal, restart-request, stop-request, DB identity every 50 ms | D1 |
| Service | terminal history saved to SQLite every 2 s while output flows, up to 16 MiB, with a manual GC call around it | M8 |
| suit | full inventory every 10 s and on `status`, `refresh`, twice on `quit`; loop wakes every 0.1 s with a device connected | Step 4: tables kept by events; scan only for Quit everything |
| Node helper | Claude titles polled every 5 s | Step 10: read on the provider's own events |

One conflict with INTENT 5 found: the service's idle rule counts every running terminal, including hosted ones, so
one open shell keeps a service up for ever. With hosts always on, a terminal does not need the service to stay alive.
Step 1 changes the rule to "no link and no busy agent turn".

## 6. Test triage

Rule from INTENT: keep what exercises a real feature path; delete what pins a removed mechanism, tests a double, or
runs nowhere. The per-suite table with reasons was in `map/tests.md` §2 (removed after the pass); this is the verdict by group.
Verification of a step is always a targeted check, never the full run.

**Keep (46 entries, about 23,400 lines).** Real processes, real git, real SQLite, real sockets, or pure logic:
`workspace-terminals` (4,934), `scm-git`, `scm-watch`, `document-test`, `haxeon-rpc`, `workspace-agents`,
`claude-agents`, `pi-agents`, `codex-history`, `native-session-names`, `workspace-catalog`, `workspace-persistence`,
`workspace-transport`, `workspace-scm` (if the SCM RPC stays, E2), `workbench-drag`, `workbench-tree`,
`session-chat-ui` and `agent-snapshot-client` (if chat stays, E1), the terminal UI unit suites, the small unit suites
(`path-key`, `problems`, `command-clipboard`, `layout-controls`, `narrow-tabs`, `quick-picker`, `sidebar-layout`,
`status-bar`, `tab-tooltip`, `session-links`, `session-diff-regression`, `project-scan-yield`, `plugin-host`), the
language suites with `fake_lsp.py`, `process-test`, `directory-scan`, the native C contract suites, and the relay
Worker's vitest files.

**Delete (about 7,300 lines in `tests/`, about 5,000 in scripts).**

- In no runner and not worth wiring: `agent-image-staging`, `build-task-smoke`, `button-theme`,
  `codex-markdown-layout`, `editor-geometry`, `image-preview`, `settings-ui`, `session-projection` (cannot build),
  `session-chat-preview`, `workspace-directories`, `experiments`, `terminal-polling-smoke`.
- Benchmarks nobody runs: `memory-workload`, `project-index-benchmark`, `release-benchmark`,
  `session-switch-benchmark`, `terminal-render-benchmark`, and their scripts.
- Linux Xvfb window drivers with no caller: `context-menu-ui-smoke`, `manage-menu-ui-smoke`,
  `notifications-ui-smoke`, `narrow-titlebar`, and `test-idle-ui.sh`, `test-terminal-workbench-click-ui.py`. The
  other Xvfb drivers wait on E7.
- Pins of removed mechanisms: `workspace-migration` (702) and `rehearse-workspace-migration.py` (with O1),
  `context-switching` (461), `machine-device` (695, a fake of a fake; `test-machine-remote.py` covers the real path),
  `workspace-lifecycle` (with O3), `test-workspace-identity.py`, `test-workspace-manager-choice.py`,
  `test-agent-manager.py`, `test-service-updates` (with O3), the generation A relay tests (about 2,500, with D9),
  gui scenarios `m19_phase6`, `m19_foreign_tabs`, `m19_probe`.

**Rewrite (about 6,500 lines).**

- `workspace-attachment` (598): becomes "editor asks suit, suit starts one process, link connects", against an
  isolated suit home.
- `workspace-catalog-pool` (908): becomes the `WorkspaceLink` suite (connect, watch, drop, reconnect, snapshot).
- `suit` driver and `SuitUnitTests` (556): ownership rules move from "scan and classify" to "what suit started and
  what is linked"; the classification tests shrink with the inventory.
- The 16 suites on `ModelWorkbenchHost`: `tests/support` (2,257 lines) is a second implementation of the UI host
  kept in step by hand. Move the suites onto the real `UiWorkbenchHost` run headless (as `context-snapshots`
  already does), a few at a time, and delete the double at the end. Until then they stay as they are.
- 20 private doubles of `WorkspaceRpcEndpoint`: one shared in-memory endpoint in `tests/support`.
- 11 `m19_*` gui scenarios: re-expressed over suitctl automation (Step 9); only `m19_switch_latency` keeps real OS
  input.
- All runners: tests run with an isolated suit home instead of `EXOSUIT_SUIT=off` (Step 4).

**Wait on a question.** `agentkit-provider`, `agentkit-transport` (E6); `workspace-browser`,
`workspace-browser-pairing`, `browser-pairing-url`, `web/test.sh` (E2); `decoration-ui-smoke`, `workspace-ui-smoke`,
`real-language-ui-smoke`, `terminal-cursor-ui-smoke`, `devtools` (E7).

New tests the plan adds are few and real: terminal survival across a service kill and a suit polite quit; open an
idle workspace through suit; a session created by suitctl appears in a second window; quit over the link.

## 7. Docs triage

The per-file table was in `map/docs.md` (removed after the pass). Rules:

- A doc that describes a mechanism this plan removes is deleted in the step that removes the mechanism.
- Status notes, handoff files, dated reports and roadmap boxes for finished work are deleted now (Step 0); git keeps
  them.
- One doc per living subject: `docs/design/workbench/WORKBENCH-DESIGN.md`, `docs/design/suitctl/TDD-exosuit-ctl.md`,
  this plan until it is done, `docs/haxeon-compiler-bugs.md`, `docs/mobile/android.md`, the perf-harness README, and
  one architecture page written at the end from §2 above.

Known stale docs to delete or rewrite (each is named in an area map §9): `docs/design/terminal-host.md`,
`terminal-host-status.md`, `session-resume-status.md`, `agent/AGENT-SESSIONS.md`, `agent/README.md`,
`docs/roadmap/19-machine-workspaces.md` (Phase 9 text), `16-remote-workspaces.md`, `docs/mobile/android.md:130`,
`docs/design/ui-gallery.html` (7.2 MB, generated), `docs/benchmarks/selection-drag.md` and `real-display/` (Linux
records whose result files no longer exist), `docs/roadmap/STATUS.md` (a running log of 6,810 lines, 29% of all document lines), `suit/README.md` (16 mentions
of `EXOSUIT_SUIT`), the root `README.md` (points at the "overnight handoff").

Counts from the docs map: 105 documents, 23,078 lines. Current 29 files (4,187 lines); stale 40 (14,293);
superseded 15 (1,188); contradicted by the code 5 (1,375: `terminal-host.md` "nothing built",
`WORKSPACE-PROTOCOL.md` "remain planned", ADR 0004 "proposed", milestones M11 and M18 with every box open); unsure
16 (2,062). The target is about 25 documents and 9,000 lines (tree in `map/docs.md` §4, removed after the pass): the roadmap
folder (52% of all document lines) becomes one `docs/ROADMAP.md` of open items; benchmark write-ups that cite
scripts and result paths that no longer exist go; the workspace protocol docs become one with true statuses.

Corrections to the two approved designs (they stay the designs; these lines are wrong in them):

| Design text | What the code shows | Effect on the plan |
|---|---|---|
| Workbench §5 lists the `machine == null` group-tree paths as suit-off deletions | the phone and the web client run `ExosuitApp` without a machine client; those paths are what they draw | they are replaced in Step 8 (phone gets links), not deleted in Step 4 |
| Workbench §6: a switch re-runs `attachWorkspace` | it runs once; a switch re-targets inside `pollWorkspaceAttachment` | none for the target; the step is smaller than drawn |
| Workbench assumes the manager restarts a crashed service | no crash restart exists | suit restarts on the next `workspace.open`; no supervisor is added |
| Workbench: reconnect waits for the manager | `RpcClient` retries, then a launch helper after 3 s | same as above |
| TDD: suit never reads the peer process | `SuitRelayHosting.hx:82` does | reuse it for the editor link |
| TDD: the editor writes several request files | it writes only `restart-request.json` | less to remove |
| TDD step 3 drops the editor record | without the link in place editors vanish from Quit | Steps 1–3 of the TDD land as one step here |
| TDD: `command.txt` is read on demand | checked every 50 ms; `pick-folder.txt` read at three places | all three go in Step 9 |

## 8. Steps

Each step lands on its own, leaves the editor usable, and names a check the owner or a script can make in under two
minutes. LOC is production code; tests and docs move with their step. The Workbench steps (WB 1–8) and the suitctl
steps (TDD 1–10) are folded in; "Changed" says where the order or content differs from the designs and why.

**Step 0. Marks, and delete what has no user.** (−1,000 code, −9,000 tests, scripts and docs)
- Add timeline marks for: click on a workspace row → first frame of its rows; New Agent Session → tab accepts input;
  editor start → first frame, broken into its phases; suit `machine` request → reply. Record one baseline with
  `measure.ps1`.
- Delete U1, U3–U8, the tests and scripts in §6 "Delete" that are in no runner, and the finished status docs.
- Done: baseline numbers are in this folder; `git grep` finds no reference to a deleted name; the editor builds.
- Verify: one editor build and start; the four suites touching the removed RPCs (`haxeon-rpc`,
  `workspace-terminals` RPC phase, `workspace-catalog`, `suit` unit tests).

**Step 1. Terminals survive.** (−350, +120)
- Hosts are always on: `TerminalHosts.enabled()` and the silent fallback to an in-service PTY go. Today a
  stable-channel editor (`scripts/stable.py` sets `PRAGTICAL_PORTABLE`) runs terminals inside the service, where
  they die with it (`TerminalHosts.hx:290-300`, checked).
- A bad terminal record is skipped and logged, not a failed service start. No 16-host cap. Adoption runs on demand,
  not only in the constructor. A host that is slow to answer is retried, and Restart never kills a host that is
  still alive without asking.
- END travels over the host pipe; end-request files go.
- The idle rule ignores hosted terminals (§5).
- Service emulator, replay log and periodic SQLite save go for hosted terminals (M8).
- Done: start a shell, kill the service process, reopen the workspace: the same shell with its screen and history.
  Same after "Quit Exosuit, keep terminals" in suit.
- Verify: the daemon phase of `workspace-terminals`; one `term_survive.py` scenario.
- Changed: not in either design. It is first because "terminals die" is the owner's first complaint and the fix does
  not depend on any other step.

**Step 2. Click, menus, default provider (WB 1).** (−500, +150)
- One tree projection (M3), full menus on every row, single click opens, empty states, "Default agent provider"
  setting beside `agentSessionMode` (`Settings.hx:25`); the three places hard-wired to "codex"
  (`WorkbenchPanel.hx:1073-1075,1090-1092`, `ExosuitApp.hx:2517`) read it.
- A failed start keeps the tab and text with the cause and Retry.
- `WorkbenchActions` takes the 15 duplicated jobs (M4).
- Done: WB §8 step 1 checks by eye.
- Verify: `workbench-tree`, `workbench-drag`.

**Step 3. Push, not poll, inside a workspace (WB 3).** (−450, +40)
- The desktop sets `agentsStale` from the catalog CHANGED push (today only the phone does). Agent LIST, terminal
  LIST, the 0.2 s round-robin read and `WorkspaceReplica` go (M2).
- Done: an idle window shows no RPC in the connect log for 30 s; a session created from a second window appears at
  once.
- Verify: the connect log; `workspace-agents`.
- Changed: moved before the suit work. It needs nothing from suit and removes the timers that would otherwise be
  carried into `WorkspaceLink`.

**Step 4. The suit link; suit always on (TDD 1–3, WB 8).** (−900, +600)
- Editor ↔ suit persistent link with `EditorDirectory`; `machine.changed` pushed over it (TDD 7 brought forward),
  so the 5 s poll and the 20 s "provisional service" in `MachineClient` go. Quit is a request on the link. The
  editor record and `WindowPresence` go.
- suit answers `machine` from memory. Services report to suit by connecting once, not by suit scanning.
- `EXOSUIT_SUIT=off`, the temporary-state auto-off and every `enabled` check go. `test.sh`, `ci.sh`,
  `test-windows.ps1`, `run-guarded.ps1`, `wt-run.ps1` and about ten harnesses use an isolated suit home. The phone's
  `EXOSUIT_SUIT=off` line (`AndroidExosuitFactory.hx:60`) becomes "no local suit on this platform", a build fact, not
  a mode.
- Folder identity and folder adoption go (D5): opening a folder asks suit for its workspace or creates one.
- Done: `EXOSUIT_SUIT` appears nowhere; Quit in the tray closes two editor windows which each save first; opening a
  loose folder creates a workspace named after it.
- Verify: `suit` driver against an isolated home; one two-window quit run.
- Changed: TDD steps 1, 2 (basic `control` op) and 3 land together, because removing the record without the link
  drops editors from Quit. WB 8 moves from last to here: every later step is then written once, not twice.

**Step 5. suit starts one process (WB 4).** (−3,200, +400)
- `workspace.open` on the link: suit spawns the service (the code it already has for remote, `MachineRemote.spawn`)
  and returns the pipe name. The daemon takes the lock and the few manager duties that remain. D1, D2, D6, O4 go.
  O3 goes if E4 says so; O1 and O2 if E5 says so.
- The service waits on events instead of waking 100 times a second; providers are built on first use.
- Done: suit's tray shows one process per running workspace; New Terminal on an idle workspace echoes typing in under
  half a second; `endpoint.json` and `manager.log` are not written.
- Verify: the rewritten `workspace-attachment`; the Step 0 mark for idle → connected.

**Step 6. Snapshot and warm spare (WB 2, WB 5).** (+350)
- The service writes `catalog-snapshot.json` on change and exit; idle rows draw from it. suit holds one spare while
  an editor is linked.
- Done: WB §8 steps 2 and 5 by eye; the mark for idle → connected is under 100 ms with a spare.
- Changed: the snapshot moved after one-process start so it is written by the daemon once, not by manager and daemon.

**Step 7. `WorkspaceLink` (WB 6, WB 7).** (−1,500, +500)
- One class replaces the attached client, the catalog watch and the terminal pool (D3, M1). `ExosuitApp` holds
  `links` and a focus; the 7 casts and 52 delegations go. Linger 30 s after a row collapses; service stops after
  600 s unused.
- Done: switching between two running workspaces never shows "connecting"; a collapsed idle workspace holds no
  connection; an unused workspace leaves the tray after 10 minutes.
- Verify: the `WorkspaceLink` suite; the click → frame mark.

**Step 8. Remote only through suit; the phone on links.** (−2,300 to −5,900, +300; E2)
- Generation A goes (D9). The phone uses `WorkspaceLink` over relay streams and gets its tree from suit's machine
  list, replacing the `machine == null` paths. One stream-frame implementation, one pairing client, one device store
  (M6). The per-workspace STATUS polls go.
- If E2 = drop: `web/` remote client, Worker CORS, service SCM RPC and loopback WebSocket go too.
- Done: pair the emulator phone with an isolated suit, open a workspace, type in a terminal; no service dials the
  relay.
- Verify: `test-machine-remote.py`; `android/scripts/machine-acceptance.ps1` on the emulator.

**Step 9. Control plane and automation (TDD 4–10).** (−450, +1,500)
- Launch forwarding (`exosuit <folder|file>`), `suitctl` as a second name of suit, Pragtical v1 pipes,
  `project.add/change`, events, automation tiers, then command files, `snapshot.json`, `pick-folder.txt` and WM_CLOSE
  go. `gui_driver.py` reads `ui.snapshot` over the protocol. The 11 kept scenarios are ported.
- Done: `suitctl open <folder>` opens it; a scenario creates a session and types into it without touching the mouse.
- Changed: none in content; it runs after Step 7 so `state.get` reports links, not the attachment state machine.

**Step 10. Agents: one provider base, resume that works.** (−1,150, +200; E1, E6, E8)
- Common transport, conversation and transcript reader (M7). Snapshot RPC path for small views goes.
- Resume: the conversation id is recorded when the provider reports it (Claude's SessionStart hook, Codex's thread
  id from its own output) instead of guessed from rollout files by time. A bad AgentKit record no longer stops the
  service.
- If E1 = retire or lazy, and E6 = remove: the chat mode and AgentKit provider changes land here.
- Done: restart a Claude, a Codex and a Pi terminal: each continues its conversation.
- Verify: `claude-agents`, `pi-agents`, `workspace-agents` with the fake CLIs; one real run of each provider.

**Step 11. Split `ExosuitApp`; finish tests and docs.** (0 net; about 2,500 lines move)
- M9, the `ModelWorkbenchHost` move, M10, one architecture page, delete this plan's maps.
- Done: `ExosuitApp` is about 3,000 lines; one suite list; `docs/` has no file describing a removed mechanism.

Order in one line: marks and dead code → terminals survive → click and menus → push inside a workspace → suit link
and suit always on → suit starts one process → snapshot and spare → one link class → remote through suit → control
plane → agents → split and tidy.

Steps 1, 2 and 3 are independent of each other and of suit, and can be built in parallel. Steps 4 to 7 are a chain.
Steps 8, 9 and 10 depend on 7, 7 and 5 and can run in parallel.

## 9. haxeon notes

haxeon is out of scope. `docs/haxeon-compiler-bugs.md` already records the bugs the maps met (`Std.parseInt("09")`
octal; no `File.read` or seek; no `Date` fields; long paths). No new verified compiler bug was found in this pass, so
that file is unchanged. Things that add code in Exosuit because of haxeon, for the haxeon pass:

| Gap | Cost in Exosuit |
|---|---|
| No partial file read or seek | whole-file reads of up to 64 MiB to get a first line (`AgentTerminalResume`), `sessions.log` re-read whole every 2 s, `LiveBuildFeed` tail by size |
| `Std.parseInt` reads a leading 0 as octal | `decimal()` helper; other callers unchecked |
| No `Date` calendar fields, no `DateTools` | hand-written calendar arithmetic in resume and migration code |
| No blocking wait on several pipes with a reason code visible to the app | 10 ms and 50 ms polling loops in service and manager (whether `events.wait` already blocks was not checked) |
| Manual GC call around terminal history saves | a workaround whose cause was not recorded; goes with M8, but the cause should be found |
| Detached child and job objects | memory notes a fix (haxeon `b5d151928`); the terminals map could not confirm from `child_processes.c:322-336,428-434` that a host always leaves the service's kill-on-close job. Step 1's kill test answers it |
| Single-implementation interfaces used as test seams | haxeon has no cheap way to substitute a class in a test, so each seam is an interface plus a fake; about 15 such interfaces |
| Struct-typed JSON (deliberate) | hand-written codecs for every file format; the snapshot file should reuse the `@:wire` catalog types |
