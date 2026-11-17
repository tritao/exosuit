# What exohost knows about, and what its full Quit ends

The user's rule (2026-11-12): exohost is the final arbiter. It lists everything an Exosuit instance starts, on the PC or
from a phone, and can end all of it; `exohost quit --keep-terminals` is the polite quit that leaves terminals running.
Below is every place the code starts a process or holds a long-lived connection, and how exohost treats it.

How exohost learns of a process:

- **registered**: the process writes `registry/<pid>.json` in exohost's home itself.
- **found** (shown as "found by scanning, not registered", `source: "adopted"` in JSON): exohost scans the command
  lines of `ExohostInventory.SCANNED_NAMES` and `ExohostClassifier` recognises the kind; it is exosuit's when its environment
  registers with this exohost and its parent chain reaches a registered process through exosuit kinds only
  (`ExohostLineage`), or, for a terminal host, when its folder's `host.json` names its pid. This is also how processes
  started before exohost was running, or by a build that predates registration, are found.
- **found by checkout** (also `source: "adopted"`): the source-tree chain (`ExohostInventory.adoptCheckoutChains`). A
  checkout is an Exosuit one when a linked editor runs from it (`<ROOT>/graphical/build/host/main.hl` or `live.hl`)
  or when `python scripts/run.py` started a run session of its `graphical/haxeon.json`. Then, among processes whose
  environment registers with this exohost, its run session (`hl haxeon-cli.hl run --project <ROOT>/graphical/haxeon.json`,
  live or not), the `scripts/run.py` that started it (kind `launcher`) and a live host of `<ROOT>/graphical/build/` are
  exosuit's, whatever their parent chain (python, `cmd /C`, `cmd /c start` break it). A compiler worker running
  `<ROOT>/haxeon/...hl.exe` is exosuit's only while a run session of that checkout runs and only when it started after
  that session (an editor alone starts none), and this adoption is never written to the registry: once the session
  exits the worker is "not started by exosuit" again, so the orphan sweep never takes it.
- **shared with your builds** (a compiler worker of exosuit's, `shared: true` in JSON): Haxeon compiler workers are per
  compiler and project, so a build exosuit did not start (`hl haxeon-cli.hl ...` on the same hl.exe, run from a terminal,
  an agent or a build task) may use the worker exosuit's session started. While any such Haxeon client of that
  toolchain (the hl.exe's folder) runs, the worker is listed "shared with your builds", is never orphaned, and is left
  out of every bulk stop (full and polite quit, "Terminate all background processes", `kill --all`, `kill --orphans`);
  `exohost kill <pid>` still ends it. Once no such build runs, the full quit ends it again.
- **scanned only**: recognised but not tied to this exosuit; listed under "Not started by exosuit", never stopped in
  bulk (`exohost kill <pid>` still ends one).

"Full quit" is `exohost quit` / tray "Quit Exosuit and end everything". Descendants of exosuit kinds are also swept when
their parent is stopped (`ExohostKinds.spawnedByExosuit`).

| Kind | Who starts it | How exohost learns of it | Ended by full quit | Gap |
| --- | --- | --- | --- | --- |
| Editor (`graphical/build/host/main.hl`, `tools/exosuit.hl`, `exosuit.exe`) | user, `scripts/run.py`, haxeon-cli | its exohost link (`EditorDirectory`); classifier `editor` | asked to close; one kept open over unsaved work stays, listed, and the daemon waits for it | never force-killed (by design) |
| Extra editor window (`--context=KEY`; live form runs `live-host.hl`) | editor (`src/workspace/NewWindow.hx`), detached | its exohost link; classifier (live form is classed `live-host`) | yes | the live form is labelled live-host, not editor |
| Workspace service (agent main.hl `--workspace ID --folder F...`) | exohost, on `workspace.open` or for a paired device | reports itself over its link; registers; classifier `workspace-host` | yes (`stop` over its link, then kill) | none known |
| Terminal host (`--terminal-host DIR`) | workspace daemon, detached | registers; else found by `host.json` pid | yes (killed, then its program's tree swept); kept by the polite quit | none known |
| PTY shell and what the user runs in it | terminal host | not listed (the user's programs): a process below a terminal host (`ExohostLineage.belowTerminalHost`) is never classified or adopted by its kind, even an SDK-mode claude or a codex app-server the terminal runs, and a host owns nothing it runs | yes, through its terminal host's end | none known |
| Source-tree launcher (`python scripts/run.py [--live]`) | the user | found by checkout: the parent of its checkout's run session; kind `launcher` | yes, after every editor has exited (see below); polite quit too | listed only once its run session runs (not while run.py still builds the agent) |
| Run / live session (`haxeon-cli.hl run --project <ROOT>/graphical/haxeon.json [--watch --live]`) | `scripts/run.py` | found by checkout (or by its chain); kind `live-session` | yes, after every editor has exited; polite quit too | a session of another project is scanned only |
| Compiler worker (`/haxeon/compiler/*.hl`) | haxeon-cli, haxeon-lsp (`cmd /c start /b`) | scan; found when the chain ties it, or by checkout when its hl.exe is `<ROOT>/haxeon/...` and it started after a running run session of that checkout (not persisted) | yes when found, unless shared: while a Haxeon client exosuit did not start runs on the same hl.exe the worker is "shared with your builds" and no bulk stop or orphan sweep ends it | a worker started after the session by a build of another project that has already finished is taken for the session's (haxeon's worker state file names no project), so the full quit ends it; it is idle and restarts on demand. A worker of another toolchain started through `cmd /c start` stays not started by exosuit |
| Live host (`live-host.hl`; under `run.py --live` it runs the editor itself, which registers as `editor`) | live session through `cmd /C` | links as the editor; else found by checkout (`<ROOT>/graphical/build/`) or by chain | the editor is asked to close, never swept | `cmd` wrapper not scanned (it is a pass-through; it ends with the host) |
| Agent provider: claude (`--permission-prompt-tool stdio` + `stream-json`) | workspace daemon (`ClaudeProvider.hx`) | scan (`claude`, `node`); found under its daemon | **yes**, also swept with its daemon | none known |
| Agent provider: codex proxy bridge (`run-codex-proxy.py`) and `codex ... app-server proxy` | workspace daemon (`CodexProvider.hx`) | scan (`python`, `codex`); found | **yes** | none known |
| codex shared app-server daemon (`codex app-server daemon start`) | codex itself, detached from the starter | scan recognises it, but its starter has exited, so it is "not started by exosuit" | **no** | codex owns it and it outlives exosuit; ending it would also end other codex users. Left listed, end it by pid |
| Agent provider: pi (`--mode rpc` + `pi-permissions-`) | workspace daemon (`PiProvider.hx`) | scan; found | **yes** | none known |
| Claude name bridge (`node <helper> ROOT --exosuit-helper=claude-name-bridge`) | workspace daemon (`ClaudeNameBridge.hx`) | scan: the `--exosuit-helper=` marker (`ExohostKinds.HELPER_MARKER`), classed `helper`; found under its daemon | **yes** | none known |
| Haxeon language server (`haxeon-lsp.hl`, bundled `tools/haxeon-lsp`) | editor (`LanguageServiceClient.hx`) | scan; found under its editor | **yes** | none known |
| DevTools panel (`scripts/devtools.py`) | editor (`GraphicalMain.hx`) | scan (`python`); found | **yes** | none known |
| Profiler bridge (`$HAXEON_DEVTOOLS_RUNTIME $HAXEON_DEVTOOLS_BRIDGE --exosuit-helper=profiler-bridge`) | editor (`ProfilerProcess.hx`) | scan: the `--exosuit-helper=` marker, classed `helper`; found under its editor | **yes** | none known (dev-only) |
| Build tasks, plugin `startProcess` | editor (`BuildController.hx`, `EditorApi.hx`) | not listed (the user's own commands) | no | by design; they end with their editor's process group |
| exohost daemon | editor (`ExohostClient.hx`), detached | daemon.json; `exohost list --all` shows it | exits when nothing is left | none |
| exohost viewer console (`cmd /c start ... exohost watch`) | exohost tray | not listed (read-only console) | no | harmless; it only reads |
| exohost at logon (`conhost --headless cmd /c ...exohost-login\*.cmd`) | Windows Run key (opt-in) | not listed (it starts the daemon and exits) | n/a | none |
| Short helpers (git, reg.exe) | editor, agent, exohost | not listed | waited on by their caller | none |
| File and workspace watchers | in-process (`dir_watch.c`) | n/a: no process | end with their process | none |
| Remote device sessions, the machine's relay connection | exohost daemon (`exohost/src/exohost/remote`) | in-process; `exohost remote`, `exohost list --all`, tray "Paired devices" | **yes**: cut off at once by the full quit; remote access stays configured | none |
| A phone's app | the user | its pairing and session in `exohost remote` | cannot be quit; it is cut off (session and relay connection end, or the pairing is revoked) | inherent |

Editors before what hosts them: under `run.py --live` the editor is the live host, a child (through `cmd /C`) of the
live session, which ends when the editor exits. So a stop never kills a launcher or live session
(`ExohostKinds.hostsEditors`) while an editor running under it (`ExohostInventory.hostedEditors`, through any process;
`cmd.exe` is scanned for this parent link only, never classified) is still running: the editors are asked to close
first, then the session gets the 3 s service grace to end by itself and is killed after it. An editor kept open over
unsaved work (or one the stop did not choose, as with `kill --all`) keeps its session and launcher running too ("left
running: an editor it hosts is still open"); this also holds for `exohost kill <pid>` of one of them. A sweep never kills
a linked editor, even one classed live host under a session being stopped. A terminal host is such a kind too
(`run.py` typed into an Exosuit terminal runs the editor below the host): it is killed only once the editors below it
have exited, and the daemon ends a host the full Quit left running for an editor once no editor runs
in it, also after the quit's rounds.

The quit's edges: a terminal host still starting (not registered, no `host.json` yet) whose parent is an owned
workspace service is owned. A compiler worker spared as shared is ended in a later round once no outside build may use
it (that build ran in a terminal the quit ended); a Haxeon client run by bare `hl` (toolchain unknown) makes every
worker shared, and the sweep never kills a shared worker. A full Quit cancelled by a new editor brings remote access
back. A polite quit exits the daemon when nothing owned is left only if nothing else keeps it up (login start, remote
access on, a hosted workspace). The CLI's `kill --all`, `terminals end` and daemonless `quit` end the terminal host
they run in last, after printing the rest.

Remaining gaps, in order of weight: the codex shared app-server daemon (by design left alone); compiler workers of a
toolchain outside any known checkout whose parent chain is broken (`cmd /c start`) or whose ancestor exited before exohost
saw them: they are listed as "not started by exosuit" and ended only by pid; `scripts/run.py` while it is still
building, before it starts its run session.

Proof: `exohost list --all` counts every kind (zero included), the daemon, remote access and paired devices;
`scripts/test-exohost.py` "full quit ends every kind" and "polite quit leaves only terminals" start a stand-in of each
kind under an isolated exohost and check what is left; "full quit ends the run.py chain" and "polite quit ends the run.py
chain" start stand-ins of run.py, its run session, a live host and a compiler worker with no exosuit parent, plus a run
session of another checkout, and check `list --all` counts the four as exosuit's, the stranger not, and that the quit
ends the four once the stranger (a client on the same hl.exe, so the worker is shared while it runs) is gone;
"a terminal build shares the worker" checks that a worker a stand-in terminal build uses is listed as shared, survives
the polite quit and is never orphaned once the session is gone; "a terminal's program is not adopted" checks that a
stand-in SDK-mode claude a registered terminal host runs is neither listed nor in `kill --all`.
