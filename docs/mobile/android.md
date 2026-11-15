# Android app

A native Android application that runs haxeon and the same UI the desktop uses (`graphical/` `ExosuitApp`). Status:
the app starts on the x86_64 emulator, pairs once with a machine (suit) over a relay, lists the workspaces the owner
grants it with their groups and sessions, follows new grants without pairing again, and opens a workspace in the
same Workbench the desktop shows (M19 Phase 9, `scripts/machine-acceptance.ps1`).

## Layout of `android/`

| Path | What it is |
| --- | --- |
| `app/` | The Gradle app. Kotlin host only: `ExosuitActivity` (NativeKit view, Choreographer frame loop, lifecycle, font unpacking) and `HaxeonRuntime` (JNI declarations). No Compose. |
| `nativekit/` | Gradle library `io.nativekit`. Its `src/` is a generated copy of `haxeon/vendor/nativekit/android/nativekit/src/main` (made by `build.ps1`, git-ignored). |
| `haxe/src/` | The Haxe module: `Main`, `UiBridge` (the one entry the JNI calls: start, resize, frame, close), `AndroidUiHost` (UiHostRuntime on a NativeKit surface), `AndroidExosuitFactory` (builds `ExosuitApp` with the filesystem capability, then the workbench and workspace once paired), `PhoneRemote`/`PhoneMachine`/`PhoneWorkspace`/`PhonePanel`/`PhoneCredentials`/`PhoneInvitation`/`HostBridge` (pairing and attachment). |
| `native/` | `CMakeLists.txt`: one configure per ABI building libhaxeon, NativeKit, GPU, UIKit (with TLS), noisekit, textmate_regex and terminalkit straight from `haxeon/` and `native-packages/`. `exosuit_jni.c`: loads `ui.hl`, forwards JSON commands, creates the GLES3 surface. |
| `scripts/` | `bootstrap.ps1` (toolchain check), `build.ps1`, `dev.ps1` (fast loop), `run-emulator.ps1`, `machine-acceptance.ps1`, `emulator-lib.ps1`, `env.ps1` (shared). |

The Haxe module is compiled with `haxeon build --compiler-only` on the desktop (HashLink bytecode, about 53 MB
`ui.hl`), shipped as an APK asset, and run by the JIT in `libhaxeon.so`. The app's state lives in its private files
directory (`PRAGTICAL_PORTABLE`); it never starts a local suit.

## Toolchain

Nothing is hard-coded. Set `ANDROID_HOME` (platform-tools, `platforms;android-36`, `build-tools;36.0.0`, NDK
`30.0.16248370`, emulator, `system-images;android-36;google_apis;x86_64`, cmdline-tools) and `JAVA_HOME` (JDK 21).
`GRADLE_USER_HOME`, `ANDROID_USER_HOME` and `ANDROID_AVD_HOME` are optional. `cmake` 3.24+ and `ninja` must be on
`PATH`, and haxeon must be built (`scripts/build-windows.ps1`). Versions: AGP 9.3.3, Gradle 9.5.0, minSdk 34,
targetSdk 36, native platform android-34 (haxeon needs 28 or newer).

```
pwsh -NoProfile -File android/scripts/bootstrap.ps1     # reports what is missing
```

## Build

```
pwsh -NoProfile -File android/scripts/build.ps1 [-Abi x86_64,arm64-v8a] [-SkipHaxe] [-SkipNative] [-SkipApk]
```

Output: `android/app/build/outputs/apk/debug/app-debug.apk` (both ABIs, about 141 MB debug build: uncompressed
bytecode and unstripped libraries). Logs are in `android/build/`. Run it through the crash-dialog guard (CLAUDE.md);
the script already guards each tool. A full build takes about 6 minutes, the Haxe compile 30 s, native 40 to 70 s
per ABI.

To update an app already installed on a phone, every build must carry the same signature. Debug builds use the
machine's own debug key unless `EXOSUIT_ANDROID_KEYSTORE` names a shared debug keystore (store and key password
`android`, alias `androiddebugkey`); set it before `build.ps1` to sign with that key.

## Run on the emulator

```
pwsh -NoProfile -File android/scripts/run-emulator.ps1 [-Tap "78,300"] [-Screenshot out.png] [-KeepRunning]
```

Creates the AVD `exosuit-x86_64` (Pixel 6 profile) on first use, starts it headless
(`-no-window -no-audio -no-boot-anim -no-snapshot-save -gpu swiftshader_indirect`), installs and launches the app,
waits 25 s, saves `android/build/screenshot.png` (and `screenshot-after-tap.png` for `-Tap`), then stops the
emulator. `swiftshader_indirect` renders GLES3 without a window and works.


## Fast loop

For Haxe-only edits (debug builds) do not run Gradle. After one full `build.ps1` and APK install:

```
pwsh -NoProfile -File android/scripts/dev.ps1 -Serial emulator-5554 [-Once] [-Screenshot out.png]
pwsh -NoProfile -File android/scripts/dev.ps1 -Stop
```

Without `-Once` it watches the Haxe roots and, on each save, recompiles, pushes and restarts the app. Stop it with
`-Stop` (or Ctrl+C); that also stops the compiler worker. With `-Once` the worker stays resident for `-IdleSeconds`
(600) so the next call is incremental; `-Stop` ends it at once.

How it works: the haxeon compiler worker stays resident (state in `android/build/dev/session`) and retypes only edited
code. `ui.hl`, `ui.hli` and `ui.entries` are pushed with `adb push` and `run-as` into the app's `files/dev`; a
debuggable build loads them from there instead of the APK assets (`HaxeonRuntime.load`; a release build passes no
folder and ignores it). The app is force-stopped and started again. Pairing lives in the app data and the Keystore, so it
survives; the relay reconnects by ticket, so a running rig (desktop, relay, host from `machine-acceptance.ps1` or
`e2e-local.ps1`) is left alone: start it once and only the phone app changes.

Measured on a warm machine (emulator-5556), without `-Live`: cold worker 70 s (first round only), one-line edit in `PhonePanel.hx` 28 s
compile (3 functions retyped; the rest is the 54 MB module's backend assembly), push 1 s, relaunch under 1 s, so about
34 s from save to the new screen, against 6 minutes for `build.ps1` plus install.

### Live patches on the phone (`-Live`)

```
pwsh -NoProfile -File android/scripts/dev.ps1 -Serial emulator-5556 -Live [-Once] [-Screenshot out.png]
```

The same kind of live patch the desktop editor takes with `scripts/run.py --live`, applied inside the running app: no
relaunch, no lost screen, no lost scroll or focus. Each round runs `haxeon build --compiler-only --live` (into
`android/build/haxe-live`, so it never touches the ordinary build). The compiler publishes the HLP patch and its
`.live.*` descriptions before it writes the 54 MB module. The script sees the new stamp, checks that the patch applies to the
revision the phone runs (`android/build/dev/live-state-<serial>.json`), pushes only the patch into `files/dev/patch.hlp` and
sends the debug intent `--ez live_patch true`. The activity calls `HaxeonRuntime.patch` (JNI,
`hl_runtime_module_apply_hlp`) between two frames, with `UiBridge.liveRelease()` before it and `UiBridge.liveRebuild()` after
it, as haxeon's `LiveHost` does for the desktop, and logs `exosuit-live: patched in N ms`. Then the full module is pushed too
(off the critical path), so a restart of the app loads the revision that is on screen.

When a patch is not possible the script falls back to the plain loop (push the module, relaunch) and says why: the first
round after a start, the app is not running, the build requires a reload (new native, changed layout, enum change, ...), its base
revision is not the phone's, or the runtime refused the patch. The debug app only; a release build has no `files/dev` and no
patch intent. `build.ps1` and a native change need the APK installed again (`dev.ps1` does it; the first `-Live` round after an
install is a reload).

Measured (emulator-5556, edit of the label in `PhonePanel.hx`, screenshots before and after looked at): the patch is applied
21 s after the compile starts (3 functions retyped; 3.5 s CLI start and request, 3.8 s preparing the session, 10 s IR assembly,
which is not incremental yet, see `docs/haxeon-compiler-bugs.md`), the app logs the patch as applied immediately and shows the new
text on the next frame; the full module is on the phone 2 s later. The reload loop it replaces took 34 s and restarted the
app. The first round of a session (cold worker) is a reload and takes about 70 s.

Not covered: native code, Kotlin, Gradle or native-package changes. `dev.ps1` notices them (`native.stamp`, written by
`build.ps1`) and runs the full build and install instead (`-NoFallback` makes that an error). Release builds.

## Native libraries come from upstream

There are no configure-time patches. Branch `mobile-upstream` supplied the changes (merged here): haxeon's Android
CMake options `HAXEON_ANDROID_NATIVEKIT` and `HAXEON_ANDROID_UIKIT` (set by `native/CMakeLists.txt`), Mbed TLS for
libwebsockets, `UiHostRuntime` without a window, the UIKit frame retry, and the sokol `GL_TEXTURE_MAX_LEVEL` fix.
See `docs/mobile/android-native-libraries.md` once that branch lands.

## Pairing with a machine

A phone pairs once with a **machine** (suit, the per-user daemon; ADR 0005 section 4) and sees every workspace the owner
grants it. The owner grants on the machine, in the Remote Access panel; the phone follows without pairing again.

The phone uses the same shared clients as the desktop and the browser build. The shared pieces are in `src/workspace`:

- `transport/StreamMultiplexer` carries the machine protocol's stream frames (`kind | stream id | payload`,
  `MachineStreamFrame`) over the device's one Noise channel and gives every stream a `MessageTransport`. It reads lazily
  (any stream's `receive` pumps), keeps frames in order when the channel is busy (a bounded outbox), closes a stream
  whose inbox overflows or whose message cannot fit a frame, and closes the channel on a malformed frame.
- `client/DeviceMachine` is the directory client: it dials the channel through a connector (`DeviceRpcConnector`), runs
  stream 0 (`exosuit-machine/1`) under an `RpcClient` (reconnect with backoff), reads `DIRECTORY` when connected, on
  `CHANGED` and every 15 s (a status change alone sends no hint), pins the machine's own id from the first answer (its `relay`
  field must be the relay id the phone paired under; a machine that sends no `relay` must answer with the relay id or
  `machine-<relay id>` as its id), and gives `workspaceConnector(id)`: a connector whose every connect
  issues `OPEN` (30 s: it starts an idle service) and hands the new stream to the ordinary `RpcClient`. A dropped channel
  ends every stream, and the clients above reconnect through `OPEN`.
- `client/WorkspaceConnections` (the desktop's catalog pool) takes an endpoint check and a limit, so the phone keys it by
  workspace id.

The Android files are in `android/haxe/src/`:

- `PhoneInvitation` parses the one-time URL (`wss://relay/v1/machines/<m>/pair/<d>?secret=...#mk=<fingerprint>`;
  plain `ws` only for loopback; the shared parser is `src/workspace/client/PairingLink`). The phone connects without the
  `#mk=` fragment. After the Noise handshake it checks the machine key it reached against the fingerprint: a mismatch
  ends the pairing ("The machine that answered is not the one that made this invitation"), a match shows "The machine's
  key matches the invitation." An invitation from an older desktop has no fingerprint; the phone still pairs and shows
  "This invitation carries no machine key (it comes from an older desktop), so comparing the code is the only check."
  `PhoneRemote` runs the Noise pairing, shows the 6-digit code, and after approval and the user's
  confirmation stores the credentials and connects. Pairing grants only `machine.directory`. Pairing a machine does not
  disturb the machines already connected; pairing the same machine again replaces the older pairing.
- `PhoneCredentials` is the list of paired machines (relay origin, machine id, device id, device key, device token,
  pinned machine key, machine name). Version 2; version 1 (one pairing per workspace service) is not read, so a phone
  paired the old way pairs again.
- `PhoneMachine` is one paired machine: the relay route, the `DeviceMachine`, and a `WorkspaceConnections` pool with a
  catalog watch for each running granted workspace except the open one (at most 14: a device holds 16 streams, one is
  the machine's and one the open workspace's).
- `PhoneWorkspace` is the open workspace: its own stream and full client grants, a catalog watch on that connection,
  the file and terminal helpers. `PhoneRemote` presents it to `ExosuitApp` as the attachment (the Workbench client,
  files, terminals) exactly as the local workspace is presented; the delivery-uncertainty guard in
  `RpcWorkspaceWorkbenchClient` is keyed by the workspace id (`workspaceIdentity`), so a prompt whose delivery is
  unknown stays flagged across reconnects and across switching workspaces. One workspace is open at a time.
- The Remote sidebar panel (`PhonePanel`) lists the paired machines (online, offline, or needs attention with the
  reason), under each its granted workspaces (running or idle, with the session count), under each the groups and
  sessions from its catalog, and Forget. A machine granted nothing says "Waiting for the owner to grant workspaces."
  Tapping a workspace opens it (idle ones start). Below the list: pair another machine (URL, then the code to compare).
- Credentials live in an AES-GCM blob (`credentials.bin`) under a key in the Android Keystore
  (`CredentialVault.kt`). The vault is confined to the main thread; Haxe hands save requests to the host through
  `HostBridge` and `takeRequest()`, and every byte array is wiped after use. The Haxe side receives the decrypted
  document in the start command only. A file that does not open, or opens but is not a document this version reads, is never replaced: the next save moves it to `credentials.unreadable-<time>.bin` first. On a later start with no current file (or an empty one), the newest such file that opens again is moved back and used.
- `TlsTrust.kt` exports the system CA roots to `files/native-tls/android-roots.pem` and calls
  `setenv NK_ANDROID_TLS_CA_FILE` before the first connection. This is implemented but NOT yet exercised against a
  real `wss` relay: the acceptance run uses plain `ws`/`http` to a loopback relay (through `adb reverse`), which
  debug builds allow (`app/src/debug`, a network security config for 127.0.0.1 and localhost). Release builds keep
  Android's default (HTTPS only).
- Test-rig intent extras (debug builds with `files/automation.on`, which only `adb run-as` can create; the launcher
  activity is exported, so any app can send it extras): `--es pairing_url <url>` starts pairing, `--es clipboard_text <text>` sets the
  clipboard. A `pairing_url` that is not a pairing link is logged (`exosuit-rig: ... refused and ignored`) and shown as the
  usual pairing error; the app keeps running. There is no extra that opens a workspace: the scripts tap its row in the Remote list by label. No extra confirms a pairing code:
  scripts tap "The code matches" from the automation snapshot.

### Tests, desktop test host and acceptance run

`tests/machine-device` is the headless test: the multiplexer and `DeviceMachine` against a fake machine (frame
vectors, ordering, a busy channel, floods, malformed frames, the 16-stream limit; the directory following grants over
one channel with `CHANGED` and the periodic read; two and then three workspaces' catalogs over streams; revoke; a cut
channel reconnecting every stream; refusals and a machine answering for another id).

```
haxeon run --project tests/machine-device/haxeon.json          (through wt-run.ps1 in a worktree)
```

`scripts/mobile-machine-host.py start --out DIR` runs, all isolated: the wrangler relay on a free loopback port, an
isolated suit with remote access enabled for it, two workspaces ("Alpha" with one fake Codex session, "Beta" with two;
their services are started first so the sessions exist, and suit finds them by their state folders), and a loop that
approves the pending device with no workspaces once `approve` is requested. `grant --out DIR Alpha:all Beta:read` and
`revoke-grant --out DIR Beta` send the same control requests the desktop panel sends. `DIR/ready.json` has the
invitation URL and ids; `DIR/pairing.json` the machine's pending code; `stop --out DIR` ends everything.

```
python scripts/build.py --only agent
python scripts/haxeon_cli.py build --project suit/haxeon.json
python scripts/haxeon_cli.py build --project tests/mobile-pairing/haxeon.json      (the admin tool that makes the sessions)
pwsh -NoProfile -File android/scripts/machine-acceptance.ps1 [-Avd exosuit-x86_64] [-Port 5554] [-OutDir dir] [-SkipBuild]
```

The script builds, starts the host and the emulator, pairs once (checking the phone's code equals the machine's before
approving), shows the machine granted nothing, grants Alpha, then Beta (the pairing code must not be asked for again),
opens each by tapping its row in the Remote list (there is no intent for it), works the Claude Code terminal (below), restarts
the app (it reconnects from the Keystore), and revokes Beta. Screenshots `1-pairing-code.png` to `14-new-claude.png`
are in the output directory; look at them. Every tap is by label from the phone's automation snapshot (no pixel positions).
Pairing works in either order: the phone shows "Code confirmed. Waiting for the machine's owner to approve." and keeps
the connection until the owner approves (checked with a 45 s gap), and an approval that arrives first waits for the
confirmation. `machine-acceptance.ps1 -PairOrder confirm-first|approve-first` and, for the local rig,
`EXOSUIT_E2E_PAIR_ORDER=confirm-first|approve-first` (and `EXOSUIT_E2E_ORDER_GAP=<seconds>`) with
`EXOSUIT_E2E_FORCE_PAIR=1 e2e-local.ps1 step -Step pair` choose the order. In a worktree run it through `wt-run.ps1` with the
Android environment from this document.

Decisions: the relay Worker accepts a pairing, connect or ticket request with no `Origin` header (native clients cannot
send one) and still refuses a page from an unlisted origin; this must be deployed to the Worker in use. The relay is
the owner's own Worker (`docs/mobile/own-relay.md`): the editor takes its URL from the setting `remote/access/relay_url`
and the phone learns it from the pairing invitation, so the phone has no relay setting. A new
worktree has no `relay/worker/node_modules`: copy it from another worktree.

### Claude Code terminals on the phone

The Workbench lists a workspace's terminals. A terminal whose agent is Claude is named "Claude Code · Terminal" as on
the desktop; tapping it opens `TerminalPane.openRemote` (the same pane and `RpcTerminalBackend` the editor uses).
`AndroidExosuitFactory` passes the `openTerminal` closure and sets `touchKeys = true`; nothing changes on the desktop.

- **Size.** The phone's pane is about 51 columns at the default 11 pt mono font (`terminal/fonts/font_size`), minus
  the 40 dp extra-keys row, so a Claude Code screen is laid out for that grid.
- **Input.** Soft-keyboard text and Enter go through the text-input path (`sendTyped`). The extra-keys row sits above
  the keyboard and does not take focus (`TouchKeyButton`), so the keyboard stays up: Esc, Tab, S-Tab (the terminfo
  back-tab `ESC [ Z`), a sticky Ctrl (applies to the next typed letter), the four arrows, Paste and Enter. Paste reads
  the Android clipboard and sends it as a bracketed paste when the program asked for that. For tests the test-rig extra
  `--es clipboard_text <text>` sets the clipboard (needs `files/automation.on`).
- **Scrolling.** A finger drag scrolls the scrollback (a mouse-reporting program gets wheel events instead). Touch
  pointer ids are negative, which an earlier `>= 0` check missed. A tap focuses the pane and shows the keyboard.
- **History.** Opening a terminal brings the screen and the most recent 256 KiB of its history (a few thousand rows),
  not the whole history (up to 16 MiB) the desktop takes; a re-attach to the same service (return to the app, network
  change) continues by replay and fetches no snapshot. Older history is not on the phone (see
  `docs/design/terminal-host-status.md`, "History on the phone").
- **Who sets the size (decision).** The controller does, as on the desktop. The phone claims control by itself when
  nobody controls the terminal, and then resizes the PTY to its own grid. When another client (the desktop) controls,
  the phone is an observer: the pane shows "Read only · another client controls..." with a "Take control" button and
  the controller's grid (a 120 column screen is clipped on the phone). Take control makes the phone the controller
  and refits the PTY to the phone; the desktop then is the observer. Releasing, or the controller disconnecting, lets
  the other side claim again. The phone is usable either way: as observer it reads and scrolls, as controller it
  types. `mobile-machine-host.py hold-control WORKSPACE TERMINAL` starts a second controlling viewer for tests.
- **Control after a cold start (decision, 2026-11-12).** A phone whose app was killed reopens its last view
  (`PhoneLastView`, `files/last-view.json`), and the terminal with it. It does not take control from another client by
  itself. If the phone held control when it was killed and another client (usually the editor, which claims the freed
  lease) holds it now, the strip asks "Take control back?" with "Take control" and "Not now". Take control is the
  usual takeover. Not now leaves the plain read-only strip; the phone then stays an observer until its person presses
  Take control, also when the other client lets go. A phone that was an observer comes back as one, with no question.
  When nobody else holds the lease the reopened terminal is controlled at once, as any terminal the phone opens: the
  service gives a free lease to the view that opens it, and nothing is taken from anyone. The question is kept across
  another kill until it is answered. Headless check: `tests/phone-last-view`.
- **Create.** The Workbench menu (chevron) has "New Agent Session...": Claude there creates a Claude Code terminal
  (agent sessions are terminals by default). It needs a control grant; the "+" button makes a terminal of the
  default provider (Codex here, whose fake script is not a terminal program, so it ends at once).
- **Tests.** `tests/workspace-terminals/fake-claude-tui.py` is a deterministic Claude look-alike (alt screen, boxed
  prompt, header with the grid, Shift+Tab modes, history, bracketed paste) that logs every key, paste and grid size to
  `$FAKE_CLAUDE_LOG`; the host script wires it in as Alpha's Claude binary. `mobile-machine-host.py start --real-claude
  PATH` runs the real CLI in Beta's Claude terminal on a throwaway config (`CLAUDE_CONFIG_DIR`, HOME, USERPROFILE and
  APPDATA under `DIR/claude-home`, `ANTHROPIC_*`/`CLAUDE_*` variables removed); it renders on the phone (first-run
  theme picker, then the login screen) and answers arrows and Enter. It was not logged in.
- **Open.** In the automated acceptance flow the phone did not repaint its Read only strip after the other viewer took
  control (the host log shows the takeover and the terminal redrawn at 120x30), while manual runs showed it within 8 s;
  the cause is not found. The acceptance script warns instead of failing. Terminal snapshots and replays were not
  tested beyond the screens above; a burst larger than 65487 bytes must be split by the service.

## Phase 9: what is left

- `wss` against a real Worker (CA export), arm64 on a device, Release build.
- One workspace is open at a time; opening several at once would need more `PhoneWorkspace` objects and an attachment
  switcher in `ExosuitApp` (it attaches one workbench).
- A message on a stream is at most 65487 bytes (`MachineStreamFrame.MAX_PAYLOAD`): a larger file read or terminal
  burst has to be split by the service (as it already must for a relay message).
- The `workspace` alias still names the one workspace on a stream; the id-addressed methods are unchanged.

## Touch and phone behaviour

- **Wide windows.** The right panel needs room for its own minimum beside a usable content area
  (`MINIMUM_CONTENT_WIDTH` plus the split's divider and minimum extent), after the sidebar took its share. Where it
  does not fit it is hidden instead of running off the screen: at 757 dp (landscape) it is hidden, at 900 dp it
  shows, at 600 dp the phone layout applies. Nothing overflows at 600, 757, 900 dp or on the unfolded 1812x2176.
- **Fonts.** The host registers the two bundled IBM Plex faces and calls `addSystemFallbacks`. On Android that offers
  the system's Noto Sans Symbols subsets, Roboto and Droid Sans Mono from `/system/fonts` (the text engine checks
  each font's cmap), so the chevron in "Permissions · Workspace access ▾" and other symbols draw. Color emoji (CBDT)
  and CJK collections are not usable by the rasterizer and are not offered.
- **Taps with the keyboard up.** Touching a button takes focus off the text field, which hides the keyboard at once
  and changes the safe area. `AndroidUiHost` holds a safe-area change that arrives while a finger is down until the
  release (at most a second), so the tap acts on what was under the finger at touch-down. One tap on Send now sends.
- **Enter.** The composer's keyboard action key is Send (`TextField.imeAction`): the keyboard shows a Send key and
  pressing it reaches the app as Enter, which sends. Decision: on a phone the soft keyboard has no newline key in
  that field; a line break is Shift+Enter on a hardware keyboard. Enter and Tab are reported as keys only, never as
  text as well (NativeKit's Android `emitKey`), so Enter no longer types a line break.

## Hardening notes (mobile-harden)

- Emulator: `-gpu host -no-window` is not the default; `swiftshader_indirect` stays (default in `emulator-lib.ps1`, `-Gpu host` is accepted by the acceptance script and renders the app correctly). The emulator now starts with `-cores 2 -memory 3072`.
- Back at the app's root moves the task to the background; Home, relaunch, and screen off/on resume the drawn UI (the splash hang was an endless loop in `mobile_host_destroy`, fixed in NativeKit).
- Debug builds with `files/automation.on` write `files/automation/snapshot.json` (labelled elements, app state). `android/scripts/phone-ui.ps1` taps by label from it. The rigs remove `automation.on` when they end (`machine-acceptance.ps1` in its `finally`, `e2e-local.ps1` when the rig stops), so a device is not left accepting test-rig extras; a rig that was killed outright can leave it behind until its next `up` and `down`.
- Pairing race: the phone's `resetPairing` closed the relay channel that the machine connection reuses, and the desktop judged "closed" before reading the phone's confirmation. The phone now lets go of the channel; the desktop reads the confirmation before treating the close as a failure.
- Large terminal frames: replay records are cut at 24 KB, batches at 48 KB, and `SNAPSHOT` is paged (`offset`/`total`), all under the 65487-byte relay frame.
- Control strip (re-checked 2026-11-04 on the persistent rig, swiftshader_indirect): not reproduced. With the phone controlling the Claude terminal, the editor's Take control (rig step `takeover`) and a second client (rig step `hold`, the admin tool's `--hold-control`) each made the phone show "Read only · another client controls this terminal" and Take control within 0.1 to 2 s (screenshot and snapshot), and the phone's Take control made the editor read only (step `editor-state`), three cycles, also after a tab switch. The earlier miss was most likely the acceptance script reading a stale automation snapshot (fixed in 83fa94de) or the host-GPU headless emulator not presenting frames; if it comes back, run those rig steps first.

## Resume checks (mobile-resume)

`android/scripts/machine-acceptance.ps1 -Step resume-home,resume-back,resume-screen,resume-kill,resume-network,resume-desktop` (or `resume-all`) pairs once, opens Alpha's Claude terminal, then does each thing and waits until the UI snapshot shows the machine online, its workspaces listed, the open workspace connected and the terminal drawn. Each step saves a screenshot and a line in `<OutDir>esume	imes.log`. `-Reuse` runs against a host and emulator that are already up.

- Back closes the terminal view first, so `resume-back` ends at the Workbench, not the terminal.
- A cold start (`resume-kill`) reconnects the machine from the stored pairing in about 2.5 s; the workspace is not reopened by itself.
- Network loss is simulated by wifi and data off, removing the `adb reverse` rule and `adb reconnect` (the relay is reached through the reverse tunnel, so toggling wifi alone changes nothing).
- Desktop restart is suit stopping and starting on the host's home. The relay keeps a device's socket when the machine behind it restarts and tells the device nothing; the old Noise session is dead. `DeviceMachine` now ends the connection when its directory read times out (at most 15 s refresh + 8 s timeout), and the client dials again.
