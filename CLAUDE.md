# Agent notes

## Windows: error dialogs stall runs

On Windows a crashed or misconfigured program often does not exit. It shows a modal dialog and waits for someone to
press OK, so an unattended build, test or capture hangs with no output. Seen here:

- "The code execution cannot proceed because nativekit.dll was not found" (loader; the DLL's directory is not on PATH)
- HashLink "Fatal Error: Failed to load library ..." (`haxeon\out` or `haxeon\.tools\hashlink` not on PATH)
- MSVC Debug CRT "Debug Error! abort() has been called" and assert boxes
- Windows Error Reporting "... has stopped working"

Rules:

- Launch every built program, test executable, `ctest`, `hl.exe` and build through the guard, with a timeout that fits:
  `pwsh -NoProfile -File docs/benchmarks/perf-harness/run-guarded.ps1 -TimeoutSeconds N -Exe <program> "-ArgLine:<args>" [-Log file] [-WorkingDirectory dir]`
  It sets an error mode its children inherit (loader errors become exit codes, crashes skip Error Reporting), stops the
  whole process tree when a dialog appears anyway, prints the dialog's text and closes it. Exit 125: a dialog
  appeared. Exit 124: timeout.
- Prefer running a test executable directly through the guard over `ctest`: `ctest` starts tests with the default error
  mode, so a loader error there is drawn on the user's desktop before the guard can close it.
- Exit code -1073741515 (0xC0000135) means a DLL was not found. Fix PATH; it is not a test failure. Every `hl.exe` run
  needs `haxeon\out` and `haxeon\.tools\hashlink` on PATH.
- Build native tests Release or RelWithDebInfo, not Debug: Debug CRT asserts and `abort()` raise dialogs.
- If something seems stuck, look for a dialog before waiting longer:
  `Import-Module docs/benchmarks/perf-harness/guard.psm1; [PerfHarness.Windows]::Visible() | ? ClassName -eq '#32770'`
- GUI captures (which move the real mouse) run only through `docs/benchmarks/perf-harness/measure.ps1` or the capture
  queue (`request-capture.ps1`), one at a time.
