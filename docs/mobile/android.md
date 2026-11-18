# Android app

A native Android application that runs haxeon and the same UI the desktop uses (`graphical/` `ExosuitApp`). Status:
the app starts on the x86_64 emulator, pairs once with a machine (exohost) over a relay, lists the workspaces the owner
grants it with their groups and sessions, follows new grants without pairing again, and opens a workspace in the
same Workbench the desktop shows (`scripts/machine-acceptance.ps1`).

## Layout of `android/`

| Path | What it is |
| --- | --- |
| `app/` | The Gradle app. Kotlin host only: `ExosuitActivity` (NativeKit view, Choreographer frame loop, lifecycle, font unpacking) and `HaxeonRuntime` (JNI declarations). No Compose. |
| `nativekit/` | Gradle library `io.nativekit`. Its `src/` is a generated copy of `haxeon/vendor/nativekit/android/nativekit/src/main` (made by `build.ps1`, git-ignored). |
| `haxe/src/` | The Haxe module: `Main`, `UiBridge` (the one entry the JNI calls: start, resize, frame, close), `AndroidUiHost` (UiHostRuntime on a NativeKit surface), `AndroidExosuitFactory` (builds `ExosuitApp` with the filesystem capability, then the workbench and workspace once paired), `PhoneCredentials`/`PhoneLastView`/`HostBridge` (pairing and attachment). |
| `native/` | `CMakeLists.txt`: one configure per ABI building libhaxeon, NativeKit, GPU, UIKit (with TLS), noisekit, textmate_regex and terminalkit straight from `haxeon/` and `native-packages/`. `exosuit_jni.c`: loads `ui.hl`, forwards JSON commands, creates the GLES3 surface. |
| `scripts/` | `setup.ps1`/`setup.sh` (install the toolchain), `toolchain.json` is beside them in `android/`; `bootstrap.ps1` (toolchain check), `build.ps1`, `dev.ps1` (fast loop), `run-emulator.ps1`, `machine-acceptance.ps1`, `emulator-lib.ps1`, `env.ps1` (shared). |

The Haxe module is compiled with `haxeon build --compiler-only` on the desktop (HashLink bytecode, about 53 MB
`ui.hl`), shipped as an APK asset, and run by the JIT in `libhaxeon.so`. The app's state lives in its private files
directory (`PRAGTICAL_PORTABLE`); it never starts a local exohost.

## Toolchain

One command installs everything, from nothing, into a per-user folder outside any checkout. `android/toolchain.json` pins every
version, download URL and checksum.

| OS | Folder (`EXOSUIT_ANDROID_HOME` overrides it) |
| --- | --- |
| Windows | `%LOCALAPPDATA%\exosuit-android` |
| macOS | `~/Library/Application Support/exosuit-android` |
| Linux | `~/.local/share/exosuit-android` |

```
pwsh -NoProfile -File android/scripts/setup.ps1 [-Check] [-Force] [-SkipAvd]     Windows
android/scripts/setup.sh [--check] [--force] [--skip-avd]                         macOS and Linux
```

It installs, in order: cmdline-tools (SHA-1 checked), Temurin JDK 21.0.13+9 (SHA-256 checked), then through `sdkmanager`
`platform-tools`, `emulator`, `platforms;android-36`, `build-tools;36.0.0`, NDK `30.0.16248370`, `cmake;3.31.6` (which carries
the `ninja` the build uses) and `system-images;android-36;google_apis;x86_64` (arm64-v8a on Apple silicon and arm64 Linux), and
creates the AVD `exosuit-s8` (Pixel 6 profile, 1080x2400). Layout: `sdk/`, `jdk/`, `gradle-home/`, `avd/`, `user-home/`,
`downloads/` (kept, re-verified), `logs/`. It accepts Google's SDK licenses on the owner's behalf. It is idempotent and resumable (a
finished item is skipped, a download continues, a half-extracted folder is redone), so running it again repairs a toolchain
that was partly or wholly deleted. `-Check` / `--check` installs nothing, prints `ok` or `MISSING` per item and exits 1 when
anything is missing; `bootstrap.ps1` also checks that haxeon is built. About 9 GB, about 5 minutes on a fast line.
Gradle 9.5.0 (the wrapper) is downloaded into `gradle-home/` by the first build; AGP is 9.3.3.

No environment setup is needed. `env.ps1` (and `env.sh`) default `ANDROID_HOME`, `JAVA_HOME`, `GRADLE_USER_HOME`,
`ANDROID_AVD_HOME` and `ANDROID_USER_HOME` to that folder when they are unset (or name a folder that does not exist) and put the
SDK's cmake and ninja first on `PATH`; set the variables yourself to use another toolchain. Every script works from a plain shell.
haxeon must be built first (`scripts/build-windows.ps1`). Versions: minSdk 34, targetSdk 36, native platform android-34 (haxeon
needs 28 or newer). The macOS and Linux scripts are written but have not been run; building the APK is Windows only today.

Measured on 2026-11-18 from an empty toolchain (nothing but the repo and a built haxeon): `setup.ps1` took about 5 minutes and left 8.9 GB; `build.ps1` then produced `android/app/build/outputs/apk/debug/app-debug.apk` (143.9 MB) in one run, about 6 minutes; `machine-acceptance.ps1 -Avd exosuit-s8 -Port 5584` passed headless in 2.5 minutes with 16 screenshots (the rig needs `npm ci` in `relay/worker` once).

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

Uses the AVD `exosuit-s8` (setup creates it; the script creates it when missing), starts it headless
(`-no-window -no-audio -no-boot-anim -no-snapshot-save -gpu swiftshader_indirect`), installs and launches the app,
waits 25 s, saves `android/build/screenshot.png` (and `screenshot-after-tap.png` for `-Tap`), then stops the
emulator. `swiftshader_indirect` renders GLES3 without a window and works.


## Morning command: the emulator on the owner's real Exosuit

```
pwsh -NoProfile -File android/scripts/connect-real.ps1 -DryRun     # reads remote-status only, prints the plan, starts nothing
pwsh -NoProfile -File android/scripts/connect-real.ps1             # the real thing
```

Prerequisites: `setup.ps1` done, the APK built (`build.ps1`), the editor running (it started exohost). The owner then has one
decision to make. In order, the script:

1. Finds exohost's control pipe the way the editor does (`\\.\pipe\exosuit-exohost-<user>`; `EXOSUIT_EXOHOST_HOME` or
   `-ExohostHome` moves it) and sends **`remote-status`** (read only). No exohost: it stops with a message.
2. Starts the AVD `exosuit-s8` on port 5584 **with a window** (reuses `emulator-5584` when it is up), installs the debug APK,
   turns the emulator's animations off. The emulator keeps running after the script ends; stop it with
   `adb -s emulator-5584 emu kill`.
3. If remote access is **off**, sends **`remote-enable`** with the relay of `src/config/RelayUrl.hx` (the public Exosuit relay, or
   `-Relay https://...`): the panel's "Enable remote access". If it is already on, nothing is changed, the relay in use stays.
   Then it waits up to 90 s for exohost to report the relay connected.
4. Sends **`remote-invite`** (300 s): the panel's "Create pairing invitation". One one-time URL (with the machine key
   fingerprint), nothing else.
5. Starts pairing in the app with that URL (the debug build's test-rig extra, which needs the marker `files/automation.on`; the
   script removes the marker again right after the launch). `-NoAutoPair` instead fills the app's pairing field through an
   `exosuit://pair` link and you press Pair.
6. Prints `PHONE CODE` and, once the device is pending in exohost, `EXOHOST CODE`, then waits (10 minutes) until the device is
   known to exohost. **The owner:** taps "The code matches" on the phone, then in the editor's Remote Access panel compares the
   code, chooses which workspaces to share and presses Approve. The phone follows later grants without pairing again.

What it does to the real exohost: three kinds of control request over its pipe (`remote-status`, `remote-devices`, and the
two that change something: `remote-enable` if off, `remote-invite`), all of which the editor's Remote panel sends too. It adds one
pending pairing (a device id with a one-time key, expiring in 300 s) and, if remote access was off, leaves it on with the
default relay. It does not approve, grant, revoke, restart or stop anything, does not read or write exohost's home, and
the owner's editor is not touched. To undo: Remote Access panel, "Disconnect from this relay" (or `exohost remote off`), and
revoke the device (`exohost remote revoke <id>`).

**Relay choice.** The public default relay rejects phones (below), so when remote access is off and the default fails its probe, `connect-real.ps1` uses the repo's own relay on this PC (`-LocalRelay` forces it): `relay/worker` started detached by `local-relay.py` on 127.0.0.1:18787 (log and pid in `android/build/local-relay`; `npm ci` runs if needed), the emulator reaches it through `adb reverse`. `connect-real.ps1 -StopLocalRelay` stops it. If remote access is already on with another relay that rejects phones, the script never switches it on its own: it prints `pwsh -NoProfile -File android/scripts/connect-real.ps1 -SwitchRelay`, which turns remote access off and on again with the local relay; devices paired through the old relay must pair again. A real exohost accepts a loopback http relay only when it was started with `EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP=1` (otherwise `remote-enable` answers `relay_loopback_disabled` and the script says how to restart it with that variable). Tested 2026-11-18 on an isolated exohost that was on the stale public relay: `-SwitchRelay -AutoApprove` paired, the workspace opened, the terminal showed output.

The tested path used an isolated exohost and a local relay (`-ExohostHome <host>\exohost-home -AutoApprove`, the exohost that
`mobile-machine-host.py` starts; the script approved as the owner would). Tested 2026-11-18 against the public default relay `https://exosuit-relay.joao-9f7.workers.dev`: pairing FAILS. That deployment is older than the Android app: it answers `403 origin_not_allowed` to every client without an `Origin` header (a phone sends none; relay/worker/src/index.ts allows that since 586fb253). The emulator's TLS and DNS are fine (the CA file is written, the host resolves and answers). Fix: deploy your own relay (`docs/mobile/own-relay.md`) and use it (`-Relay`, remote access off first). `connect-real.ps1` now detects this before pairing and says so. The mechanism with a current relay is proven on loopback http only.
emulator (TLS trust, `TlsTrust.kt`; the local runs use loopback http). If pairing fails there, the logcat lines
`exosuit-pairing` and `exosuit-tls` and the `Relay connection:` line in the editor's Remote panel say why.

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

Measured on a warm machine (emulator-5556), without `-Live`: cold worker 70 s (first round only), one-line edit in `RemoteMachinesPanel.hx` 28 s
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

Measured (emulator-5556, edit of the label in the Remote panel, screenshots before and after looked at): the patch is applied
21 s after the compile starts (3 functions retyped; 3.5 s CLI start and request, 3.8 s preparing the session, 10 s IR assembly,
which is not incremental yet, see `docs/haxeon-compiler-bugs.md`), the app logs the patch as applied immediately and shows the new
text on the next frame; the full module is on the phone 2 s later. The reload loop it replaces took 34 s and restarted the
app. The first round of a session (cold worker) is a reload and takes about 70 s.

Not covered: native code, Kotlin, Gradle or native-package changes. `dev.ps1` notices them (`native.stamp`, written by
`build.ps1`) and runs the full build and install instead (`-NoFallback` makes that an error). Release builds.
That full build is for the ABI of the device it installs to (`ro.product.cpu.abi`: x86_64 or arm64-v8a), not always
x86_64.

## Native libraries come from upstream

There are no configure-time patches. Branch `mobile-upstream` supplied the changes (merged here): haxeon's Android
CMake options `HAXEON_ANDROID_NATIVEKIT` and `HAXEON_ANDROID_UIKIT` (set by `native/CMakeLists.txt`), Mbed TLS for
libwebsockets, `UiHostRuntime` without a window, the UIKit frame retry, and the sokol `GL_TEXTURE_MAX_LEVEL` fix.

## Pairing with a machine

A phone pairs once with a **machine** (exohost, the per-user daemon; ADR 0005 section 4) and sees every workspace the owner
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
  `machine-<relay id>` as its id), and gives `openService(id)`, a ServiceOpener for `WorkspaceLink`: it issues `OPEN`
  (30 s: it starts an idle service), whose answer names the service's generation and root, and hands the link a
  connector that issues `OPEN` again on every reconnect. A dropped channel ends every stream, and the links reconnect
  through `OPEN`.
- The phone holds the same `WorkspaceLinks` and `WorkspaceLink`s as the desktop editor; only the route differs (a relay
  stream instead of exohost's pipe).

The Android files are in `android/haxe/src/`:

- `src/workspace/client/PairingLink` parses the one-time URL (`wss://relay/v1/machines/<m>/pair/<d>?secret=...#mk=<fingerprint>`;
  plain `ws` only for loopback). The phone connects without the
  `#mk=` fragment. After the Noise handshake it checks the machine key it reached against the fingerprint: a mismatch
  ends the pairing ("The machine that answered is not the one that made this invitation"), a match shows "The machine's
  key matches the invitation." An invitation from an older desktop has no fingerprint; the phone still pairs and shows
  "This invitation carries no machine key (it comes from an older desktop), so comparing the code is the only check."
  The desktop asks for invitations valid 300 s, the longest the relay (`MAX_PAIRING_TTL_SECONDS`) and
  `WorkspacePairingManager` allow.
  `src/workspace/client/DevicePairing` (shared with the browser) runs the Noise pairing, shows the 6-digit code, and after approval and the user's
  confirmation stores the credentials and connects. Pairing grants only `machine.directory`. Pairing a machine does not
  disturb the machines already connected; pairing the same machine again replaces the older pairing.
- `PhoneCredentials` is the list of paired machines (relay origin, machine id, device id, device key, device token,
  pinned machine key, machine name), version 2.
- `RemoteMachine` is one paired machine: the relay route, the `DeviceMachine`, and its `WorkspaceLinks`: the kept link of
  the open workspace and a row link for each running granted workspace besides (at most 14: a device holds 16 streams,
  one is the machine's and one the open workspace's).
- The open workspace is its machine's kept `WorkspaceLink`. `RemoteMachines` presents it to `ExosuitApp` as the attachment (the Workbench client,
  files, terminals) exactly as the local workspace is presented; the delivery-uncertainty guard in
  `RpcWorkspaceWorkbenchClient` is keyed by the workspace id (`workspaceIdentity`), so a prompt whose delivery is
  unknown stays flagged across reconnects and across switching workspaces. One workspace is open at a time.
- The Remote sidebar panel (`graphical/src/ui/RemoteMachinesPanel`, shared with the browser) lists the paired machines (online, offline, or needs attention with the
  reason), under each its granted workspaces (running or idle, with the session count), under each the groups and
  sessions from its catalog, and Forget. A machine granted nothing says "Waiting for the owner to grant workspaces."
  Tapping a workspace opens it (idle ones start). Below the list: pair another machine (URL, then the code to compare).
  A Paste button beside the URL field reads the Android clipboard (the field has no paste menu on the phone).
- Invitation links. Sharing text to Exosuit from any app (`ACTION_SEND`, `text/plain`) or opening an
  `exosuit://pair?u=<urlencoded invitation>` link (`ACTION_VIEW`) puts the first `ws://` or `wss://` link of the text
  into the pairing field and shows the Remote panel. It never starts pairing, since any app can send these: the person
  presses Pair. Text that holds no pairing link is ignored and logged (`exosuit-prefill`). The Activity sends the
  `prefill` command (`UiBridge`, `AndroidExosuitFactory.prefillPairing`); across a process restart the link travels in
  the `prefill_url` extra. On a cold start the link wins over reopening the last view: the panel stays on screen, and
  the saved last view is kept (not rewritten) until a workspace is opened again.
- Reconnecting. The Activity watches the default network (`ConnectivityManager.registerDefaultNetworkCallback`,
  permission `ACCESS_NETWORK_STATE`). When it changes (callbacks coalesced for 500 ms; the one Android delivers at
  registration when there is a network is ignored; an app started offline takes its first one as the network coming
  back) it sends the `network` command with `changed: true`, and `RemoteMachines.networkChanged` drops and redials every
  machine and the open workspace, since their sockets belong to the old network. It redials at most once per 2 s; a
  change within that time is treated as `changed: false`. When the app returns to the foreground after more than 5 s the
  Activity sends `changed: false`: only connections waiting out a backoff dial at once, and healthy ones are left alone
  (`DeviceMachine.retryNow`, `RpcClient.retryNow` in haxeon).
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

`scripts/mobile-machine-host.py start --out DIR` runs, all isolated: the wrangler relay on a free loopback port, an
isolated exohost with remote access enabled for it, two workspaces ("Alpha" with one fake Codex session, "Beta" with two;
their services are started first so the sessions exist, and report to that exohost), and a loop that
approves the pending device with no workspaces once `approve` is requested. `grant --out DIR Alpha:all Beta:read` and
`revoke-grant --out DIR Beta` send the same control requests the desktop panel sends. `DIR/ready.json` has the
invitation URL and ids; `DIR/pairing.json` the machine's pending code; `stop --out DIR` ends everything.

```
python scripts/build.py --only agent
python scripts/haxeon_cli.py build --project exohost/haxeon.json
python scripts/haxeon_cli.py build --project tests/mobile-pairing/haxeon.json      (the admin tool that makes the sessions)
pwsh -NoProfile -File android/scripts/machine-acceptance.ps1 [-Avd exosuit-s8] [-Port 5554] [-OutDir dir] [-SkipBuild]
```

The script builds, starts the host and the emulator, pairs once (checking the phone's code equals the machine's before
approving), shows the machine granted nothing, grants Alpha, then Beta (the pairing code must not be asked for again),
opens each by tapping its row in the Remote list (there is no intent for it), works the Claude Code terminal (below), restarts
the app (it reconnects from the Keystore), and revokes Beta. Screenshots `1-pairing-code.png` to `14-new-claude.png`
are in the output directory; look at them. Every tap is by label from the phone's automation snapshot (no pixel positions).
`-PairBy paste` gets the invitation to the phone the way a person does: it goes on the Android clipboard, the script
taps the Remote panel's Paste button, checks that this did not start pairing, and taps Pair. `-Keep` leaves the host
and the emulator running at the end for checks that follow.
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
  change) continues by replay and fetches no snapshot. Older history is not on the phone (`historyLimit`, see
  `docs/design/terminal-host-status.md`).
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

## Hardening notes

- Emulator: `-gpu host -no-window` is not the default; `swiftshader_indirect` stays (default in `emulator-lib.ps1`, `-Gpu host` is accepted by the acceptance script and renders the app correctly). The emulator now starts with `-cores 2 -memory 3072`.
- Back at the app's root moves the task to the background; Home, relaunch, and screen off/on resume the drawn UI (the splash hang was an endless loop in `mobile_host_destroy`, fixed in NativeKit).
- Debug builds with `files/automation.on` write `files/automation/snapshot.json` (labelled elements, app state). `android/scripts/phone-ui.ps1` taps by label from it. The rigs remove `automation.on` when they end (`machine-acceptance.ps1` in its `finally`, `e2e-local.ps1` when the rig stops), so a device is not left accepting test-rig extras; a rig that was killed outright can leave it behind until its next `up` and `down`.
- Pairing race: the phone's `resetPairing` closed the relay channel that the machine connection reuses, and the desktop judged "closed" before reading the phone's confirmation. The phone now lets go of the channel; the desktop reads the confirmation before treating the close as a failure.
- Large terminal frames: replay records are cut at 24 KB, batches at 48 KB, and `SNAPSHOT` is paged (`offset`/`total`), all under the 65487-byte relay frame.
- Control strip (re-checked 2026-11-04 on the persistent rig, swiftshader_indirect): not reproduced. With the phone controlling the Claude terminal, the editor's Take control (rig step `takeover`) and a second client (rig step `hold`, the admin tool's `--hold-control`) each made the phone show "Read only · another client controls this terminal" and Take control within 0.1 to 2 s (screenshot and snapshot), and the phone's Take control made the editor read only (step `editor-state`), three cycles, also after a tab switch. The earlier miss was most likely the acceptance script reading a stale automation snapshot (fixed in 83fa94de) or the host-GPU headless emulator not presenting frames; if it comes back, run those rig steps first.

## Resume checks

`android/scripts/machine-acceptance.ps1 -Step resume-home,resume-back,resume-screen,resume-kill,resume-network,resume-desktop` (or `resume-all`) pairs once, opens Alpha's Claude terminal, then does each thing and waits until the UI snapshot shows the machine online, its workspaces listed, the open workspace connected and the terminal drawn. Each step saves a screenshot and a line in `<OutDir>esume	imes.log`. `-Reuse` runs against a host and emulator that are already up.

- Back closes the terminal view first, so `resume-back` ends at the Workbench, not the terminal.
- A cold start (`resume-kill`) reconnects the machine from the stored pairing in about 2.5 s; the workspace is not reopened by itself.
- Before a relaunch that must reconnect, `machine-acceptance.ps1` puts the `adb reverse` rule to the relay back if it is gone (`Assert-RelayTunnel`; it prints a `RIG:` line when it had to). An emulator transport reset drops the rule and a cold-started app then stays offline; that looked like an app bug once (2026-11-13).
- Network loss is simulated by wifi and data off, removing the `adb reverse` rule and `adb reconnect` (the relay is reached through the reverse tunnel, so toggling wifi alone changes nothing).
- Desktop restart is exohost stopping and starting on the host's home. The relay keeps a device's socket when the machine behind it restarts and tells the device nothing; the old Noise session is dead. `DeviceMachine` now ends the connection when its directory read times out (at most 15 s refresh + 8 s timeout), and the client dials again.
