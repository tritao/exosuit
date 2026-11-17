# Local end to end: desktop, relay and phone on one machine

`scripts/e2e-local.ps1` brings up the whole product locally with no cloud account and nothing shared with your real
editor, exohost or relay, pairs the phone once with the machine through the real editor's Remote Access panel, grants it workspaces one at a
time, and tears it all down. It exists so that a change to pairing, the relay, the shared workspace clients or the phone app can be tried
against the real pieces, with pictures, in a few minutes.

## What runs

| Piece | How | Isolation |
| --- | --- | --- |
| Development CA and server certificate | `scripts/e2e-local-host.py` (openssl from Git for Windows). The certificate names `localhost`, `127.0.0.1` and `10.0.2.2`; both are valid for 10 years. | Keys live in `<RunDir>\host\tls`, never committed (`.local/` is git-ignored). |
| Relay Worker (`relay/worker`) | `wrangler dev --local` (workerd, no login) with the repo's pinned wrangler (`npm ci` in `relay/worker`, done by the script when missing). | Durable Object state under `<RunDir>\host\wrangler-state`. |
| TLS front | `scripts/e2e-tls-proxy.mjs`: https/wss on a loopback port, piped to the Worker's plain port. | |
| Exohost, workspace service, graphical editor | The real built apps, started by the rig (`scripts/run.py --live`) with the harness's isolated state (`PRAGTICAL_PORTABLE`, `EXOSUIT_AGENT_STATE_HOME`, `EXOSUIT_EXOHOST_HOME`) under `docs\benchmarks\perf-harness\runs\e2e-local`. Relay credentials go to a file store (`EXOSUIT_RELAY_TEST_CREDENTIALS_DIR`), not the OS credential store. | Nothing of the user's exohost, agent state or settings is read or written. |
| Fake agent | `tests/workspace-agents/fake-codex.py` as the Codex provider (`FAKE_CODEX_REPLY=1`: it answers `FAKE-REPLY: <prompt>`), one session per workspace ("Fake session" in Alpha, "Beta fake session" in Beta) created through the services. | |
| Phone | Android emulator `exosuit-mobile-e2e` (headless, `swiftshader_indirect`, console port 5556, quick-boot snapshot `rig`), the debug APK, `adb reverse` for the TLS port. | The emulator's own data. |

## Two routes to one Worker

The phone dials `https://localhost:<tls port>` / `wss://...` (through `adb reverse`) and exercises its real TLS code. The
desktop dials the Worker's plain loopback port, `http://127.0.0.1:<port>`:

- The desktop's HTTP client is WinHTTP, which trusts the Windows certificate store and has no hook for another CA
  (`NK_HTTP` `ca_bundle_path` is unsupported there). Adding the development CA to the user's store would change the
  real machine, so it is not done.
- Loopback `http` is already allowed on the desktop when `EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP=1` (the test hosts use it).
  The script sets it for the isolated apps only. Desktop default behaviour is unchanged.

Both ports reach the same Worker and Durable Object store, so a machine, pairing or device made through one is visible
through the other. The editor's invitation URL starts with the plain origin; the scenario rewrites that prefix to the
`wss` origin before it hands the URL to the phone. The relay's Origin rules are unchanged: a request with no `Origin`
header (every native client) is accepted, a page from an unlisted origin is refused.

On the phone, `TlsTrust.kt` already exports the system roots for NativeKit's TLS (`NK_ANDROID_TLS_CA_FILE`). In a
debuggable build, if `files/dev-ca.pem` exists, its certificates are added to that PEM and to the platform's
`HttpsURLConnection` trust (which NativeKit's Android HTTP client uses for the ticket request). The script places the
file with `adb run-as`. A release build, or a debug build without the file, is unchanged.

## Commands: a rig that stays up

Pair once, then resume instantly. Nothing is thrown away between runs; only `reset` wipes.

```
pwsh -NoProfile -File scripts/e2e-local.ps1 up       # the keeper, run it once in the background: relay, editor in --live mode, emulator, app; blocks until down
pwsh -NoProfile -File scripts/e2e-local.ps1 pair     # ONCE (real mouse, 30 s): pairs the phone, then saves the emulator snapshot
pwsh -NoProfile -File scripts/e2e-local.ps1 step -Step session            # ONE step (or a list: -Step session,terminal)
pwsh -NoProfile -File scripts/e2e-local.ps1 step -Step list               # the step names
pwsh -NoProfile -File scripts/e2e-local.ps1 up -Restart                   # relaunch the app, print the time to "workspaces listed"
pwsh -NoProfile -File scripts/e2e-local.ps1 status
pwsh -NoProfile -File scripts/e2e-local.ps1 down     # stop everything, keep the data, save the emulator snapshot
pwsh -NoProfile -File scripts/e2e-local.ps1 reset    # down, and delete the rig's data (the next up and pair start over)
pwsh -NoProfile -File scripts/e2e-local.ps1 run      # the final gate: reset, up, pair, session, terminal, beta, down
```

Common options: `-Build` (build the admin tool and the APK first), `-Avd`, `-Port`, `-RunDir` (default `<repo>\.local\rig`).

- The rig lives in `<RunDir>`: `host\` (CA, certificate valid 10 years, relay state, `ports.json`: the ports are kept because
  the phone stores the relay address when it pairs), `editor\` (the editor's isolated exohost, agent state, settings and the
  fixture workspaces Alpha and Beta), `credentials\`, `paired.json`, `up.json`.
- The editor runs `scripts/run.py --live`, the same live mode as a developer's editor, so a desktop edit is a patch (about 23 s
  measured here for a one-line edit in `ExosuitApp.hx`, see below), not a rebuild (`python scripts/haxeon_cli.py` keeps one resident compiler worker for it). Leave it running between
  iterations; `up` on a running rig only checks and starts what is missing. Its exohost idles out after 24 h, not 150 s.
- `up`, `pair` and `step` do not touch what is already right: the APK is installed with `install -r` only when its SHA1
  changed (app data and the pairing survive), the development CA is pushed only when missing, the app is started only when
  not running, and `pm clear` is never used (only the first `up` after a `reset` does it once).
- `pair` skips itself when the rig is already paired and the editor lists the phone; `EXOSUIT_E2E_FORCE_PAIR=1` forces it.
- Control checks (phone must already show the Claude terminal): `takeover` (the editor opens it and presses Take control; prints the time), `hold` (a second client takes control for 15 s), `editor-state` (editor screenshot and control state after the phone pressed Take control).
- Cold start checks (same precondition): `coldstart` (the app is killed and started; the terminal view must come back by itself) and `recontrol` (the phone controls the terminal, is killed and started: when the editor took the lease meanwhile the phone must come back read only and ask "Take control back?", and Take control must make an extra key reach the fake TUI; when nobody took it the phone controls at once and the key must arrive). `recontrol` was rewritten on 2026-11-12 for the ask-first behaviour and has not been run on the rig since.
- `step -Step restart-editor` (run `terminal` first): the keeper asks the editor to quit with `exohostctl quit --mode prompt` (as closing its window does; no mouse), stops the old compiler worker and live host (a new launcher cannot reuse them; the exohost and services stay), starts the editor again, and the phone must take input in its Claude terminal without pairing again. Measured: editor closed to ready again 37 to 43 s (live-mode start). Open: the step does not yet measure the phone's own time to first key (it waits up to 20 s for an `online` log line first, and the phone logs none when it never noticed the close).
- Steps are `pair`, `session` (open Alpha on the phone, send a prompt), `terminal` (the Claude Code terminal), `beta`
  (grant Beta). Each one sets up only its own precondition (the app in front, Alpha opened) and says plainly when the rig is
  not paired. The GUI steps take the machine-wide screen lock (`Global\exosuit-perf-gui`) and move the real mouse.
- `up` is a keeper, not a launcher. It starts the relay, the editor and the emulator as ordinary child processes (hidden
  windows, inside the caller's job object: no breakaway, no WMI, nothing escapes a guard), writes `<RunDir>\state.json`
  (pids, `ready`) and then blocks until `<RunDir>\down` exists, when it stops them cleanly and saves the emulator snapshot.
  Start it once in the background, for example `wt-run.ps1 -TimeoutSeconds 14400 ...` with `run_in_background`; when its guard times
  out the rig ends without the snapshot save (the data is kept). `status`, `pair` and `step` read `state.json` and refuse with a
  plain message when no keeper is alive; `down` creates the down file and waits for the keeper to exit (cleaning up leftovers
  when there is none). Children get the keeper's environment without `CLAUDE*`/`CLAUDECODE` variables, so a real `claude` in a rig
  terminal behaves as on a user's machine.
- `run` is for the end: it is the only command that rebuilds the world, and it always ends with `down`.

Measured (emulator-5556, warm machine, this checkout):

| What | Time |
| --- | --- |
| `up` on a running rig (nothing to start; the keeper is already there) | under 1 s |
| `up -Restart`: app launch to workspaces listed | 3 to 5 s (4.0 s process start to first frame in the emulator, 0.8 s to the machine online) |
| `down`, then `up` again (relay, editor in `--live`, emulator from the snapshot; paired, app resumed from the snapshot) | 29 s: editor 17 s, emulator 7 s |
| `pair`, once | 29 s |
| `step -Step session` on the running rig | 42 s |
| First `up` ever (builds apart): relay 6 s, editor 2.5 min (first live compile of the editor) | |

Why "app launch to workspaces listed" can take 5 to 10 s: the app's own start is about 4 s in the emulator (process start 0, native
libraries and the 54 MB module 1.5 s, first frame at about 3.5 s; `Displayed +3.96 s`), and the machine is listed 0.5 to 0.8 s after
the first frame, but only once the editor has registered with the relay again. Right after an editor start (`down`, `up`) that
registration is what is waited for (9.8 s measured once, before the keeper; not measured again: the log of that run is gone), so it is
the editor's start, not the phone, that makes a resume feel slow. Starting the app only after `up` reports ready avoids it.

Prerequisites: the Android toolchain variables from `docs/mobile/android.md`, `scripts/build-windows.ps1` (agent, exohost,
graphical), `python scripts/haxeon_cli.py build --project tests/mobile-pairing/haxeon.json` (the admin tool that creates
the fake session) and `android/scripts/build.ps1 -Abi x86_64`; `-Build` runs the last two.

In a worktree, every command goes through `wt-run.ps1` as before:

```
pwsh -NoProfile -File C:\Users\corbi\projects\exosuit-wt\wt-run.ps1 -Worktree <wt> -TimeoutSeconds 900 -Exe pwsh `
  "-ArgLine:-NoProfile -File <script that sets the Android environment and runs scripts\e2e-local.ps1 up>" -Log <file>
```

### The desktop live loop

With the rig up, edit a Haxe file of the editor (`graphical/src/...`): the resident `run.py --live` watcher compiles it
and patches the running editor in place. Measured in this checkout (2026-11-04, a label in `ExosuitApp.hx`, 102 functions
retyped): 23 s from the edit to the published patch (prepare 4.5 s, compile 18.5 s of which IR assembly 11.4 s), the patch
applied in 42 ms. The 3.4 s seen on a developer's editor was not reproduced here; the IR assembly pass is the part that does not
shrink with the size of the edit (same 10 s on the Android project, `docs/haxeon-compiler-bugs.md`); the phone's rig state, the
pairing and the sessions stay. For the phone side use `android/scripts/dev.ps1 -Serial emulator-5556 -Live`
(`docs/mobile/android.md`): the same patch inside the running app. To check that a live edit landed, read the editor's
console (`<RunDir>\editor.log`) for `retyped` and the patch line rather than waiting for a change on screen.

## The pairing, step by step

`docs/benchmarks/perf-harness/gui_scenarios/e2e_pair.py` (real input for the editor, adb for the phone; the harness's
rules apply: machine-wide lock, the driver refuses input unless its window is in front). The editor has two
workspaces, Alpha (open) and Beta; its Remote Access panel is the machine's:

1. The fake sessions are created through each workspace's service (Beta's service is started by the scenario).
2. Remote Access (activity bar). The relay field is set to the local relay and "Enable remote access" pressed.
3. "Create pairing invitation". The one-time URL is read over exohost's control plane
   (`exosuit.state.get`, `state.remoteAccess.invitationUrl`), which only a process of this user reaches.
   The desktop's Copy button is not used, so the real clipboard is left alone.
4. The phone starts pairing from the URL (test-rig intent extra `pairing_url`, taken only with `files/automation.on`). Both sides must show the same 6-digit code.
5. In the editor: "I checked both codes", "Access to Alpha" = All permissions (Beta stays No access), Approve. On the
   phone: a tap on "The code matches" (no intent extra can confirm a code).
6. The phone lists Alpha with its session and not Beta; the editor lists the phone as connected.
7. The phone taps Alpha's row in the Remote list (no debug intent), taps its session, sends the prompt and shows
   `FAKE-REPLY: <prompt>`.
8. A Claude Code terminal (the fake TUI, `tests/workspace-terminals/fake-claude-tui.py`, key log in
   `<RunDir>\fake-claude.log`) is created in Alpha. The phone taps it open from the Workbench, types with the soft
   keyboard, presses Enter, Up, Shift+Tab and Esc on the extra-keys row (each asserted in the fake's log), and the
   editor opens the same terminal (window screenshot `editor-7b-claude-terminal`).
9. In the editor: "Edit workspaces", "Access to Beta" = Read only, "Save workspaces". The phone (Remote panel) lists
   Beta with its session without pairing again: its log holds no second pairing code.

Every step saves a screenshot: `editor-*.png` is the editor window through `PrintWindow` (`Gui.shot_window`), `phone-*.png`
is `adb exec-out screencap`. They are copied to `<RunDir>\screens`.

## Status

Verified (`e2e-local.ps1 run` under `wt-run.ps1`, about 2 minutes, 67 s of it the editor scenario; screenshots looked
at): steps 1 to 7 above. Step 8 (the Claude terminal) is written from the acceptance script's verified taps; see the
bottom of this section for whether it has run. The editor's Workbench shows the session as completed in the earlier per-workspace run; in
this flow the phone's view of the reply is the check.

Seams: the panel's automation snapshot reports the machine view (relay, invitation, pending requests,
devices with their workspaces, the machine's workspace list). The scenario drives the two drop-downs with real input
(`choose`). The phone taps use screen-relative positions. If another window is under the pointer the driver stops the
run; run again. The scenario runs up to 150 s (`-DriveSeconds`).

## Custom relay URL and a real relay

The scenario does not type the relay into the editor. It writes `remote/access/relay_url` to the isolated
`settings.json` while the editor runs, waits until the Remote Access panel shows that URL by itself (the automation
state has `relayUrl`), then presses "Enable remote access". So the run proves that the setting, not the built-in
default, decides the relay.

`e2e-local.ps1 run -RelayUrl https://exosuit-relay.<you>.workers.dev` runs the same flow against a deployed Worker:
no local Worker, CA, TLS front or `adb reverse`; both sides use the public certificate. Set
`$env:EXOSUIT_EMU_GPU = 'host'` for a lighter emulator (the emulator also runs with 2 cores and 3 GB).
See `docs/mobile/own-relay.md`.
