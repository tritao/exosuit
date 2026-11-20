---
name: android-toolchain
description: Install, check, repair and use Exosuit's Android toolchain (SDK, JDK 21, NDK, cmake/ninja, AVD exosuit-s8) on Windows, macOS and Linux; build the APK, run the emulator, run machine acceptance, and connect the emulator to the owner's real exohost. Use when anything Android is missing, deleted or broken, or when asked to build, run or pair the Android app.
---

# Android toolchain

## Where it lives

One per-user folder, outside every checkout, pinned by `android/toolchain.json` (the only place versions are written):

| OS | Folder |
| --- | --- |
| Windows | `%LOCALAPPDATA%\exosuit-android` |
| macOS | `~/Library/Application Support/exosuit-android` |
| Linux | `~/.local/share/exosuit-android` |

Inside: `sdk/` (platform-tools, emulator, android-36, build-tools 36.0.0, NDK 30.0.16248370, cmake 3.31.6 with ninja, the
system image, cmdline-tools), `jdk/` (Temurin 21), `gradle-home/`, `avd/`, `user-home/`, `downloads/`, `logs/`.
`EXOSUIT_ANDROID_HOME` moves the whole folder. `android/scripts/env.ps1` (Windows) and `env.sh` (macOS/Linux) default
`ANDROID_HOME`, `JAVA_HOME`, `GRADLE_USER_HOME`, `ANDROID_AVD_HOME`, `ANDROID_USER_HOME` to it and put the SDK's cmake and
ninja on PATH, so every script works from a plain shell. Never set these by hand unless using another toolchain.

## Commands

- Check (installs nothing, exit 1 if anything is missing): `pwsh -NoProfile -File android/scripts/setup.ps1 -Check` /
  `android/scripts/setup.sh --check`. `bootstrap.ps1` checks the toolchain and haxeon together.
- Install or repair (also after the folder was deleted; idempotent, resumes downloads, verifies SHA-1/SHA-256, creates the
  AVD `exosuit-s8`): `pwsh -NoProfile -File android/scripts/setup.ps1` / `android/scripts/setup.sh`. `-SkipAvd` / `--skip-avd`
  for build only. It accepts Google's SDK licenses. Apple silicon and arm64 Linux get the arm64-v8a image.
- haxeon first: `pwsh -NoProfile -File scripts\build-windows.ps1` (the Android build needs `haxeon-cli.hl` and `hl.exe`).
- Build the APK (about 6 min): `pwsh -NoProfile -File android/scripts/build.ps1` gives
  `android/app/build/outputs/apk/debug/app-debug.apk`. `android/scripts/build.sh` does the same on macOS and Linux (arm64-v8a only on Apple silicon). Logs in `android/build/`.
- Headless emulator and screenshot: `android/scripts/run-emulator.ps1 [-Avd exosuit-s8] [-Port 5584]`.
- Acceptance (16 checked screens, about 3 minutes, isolated test host, headless):
  `android/scripts/machine-acceptance.ps1 -Avd exosuit-s8 -Port 5584 -OutDir <dir>`; then LOOK at the screenshots.
- Morning connect to the owner's real exohost: `android/scripts/connect-real.ps1` (`-DryRun` first). It starts the visible
  emulator, turns on Remote access only if it is off, makes one invitation and starts pairing; the owner compares the
  code and presses Approve in the editor. It never stops exohost and never approves. Details: `docs/mobile/android.md`.

## Rules

- Run every program through `docs/benchmarks/perf-harness/run-guarded.ps1` (CLAUDE.md); the scripts already guard their tools.
- Never touch `C:\Users\corbi\projects\exosuit`, `%LOCALAPPDATA%\exosuit*` (the owner's exohost lives there) or processes you
  did not start. Kill only your own emulator: `adb -s emulator-5584 emu kill`, then `adb kill-server` if you started adb.
- Windows: use `System32\tar.exe` and `curl.exe`, not Git Bash's; a loader dialog means a PATH problem, not a failed test.
- To change a version, edit `android/toolchain.json` (and AGP/Gradle in `android/build.gradle.kts` and the wrapper), run
  `setup`, update `docs/mobile/android.md`.
- A broken half-install: delete the item's folder (or the whole toolchain folder) and run setup again; downloads in
  `downloads/` are kept and re-verified.
