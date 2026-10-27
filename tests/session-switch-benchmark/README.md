# Workbench session switch benchmark

Run from the repository root on Linux:

```sh
xvfb-run -a python3 scripts/benchmark-session-switch.py --output out/session-switch-timing
xvfb-run -a python3 scripts/benchmark-session-switch.py --skip-build --pixels --output out/session-switch-pixels
```

Each run uses an isolated settings directory, workspace manager and two fake Codex
processes through the real terminal provider path. It opens both terminals, then
alternates between their Workbench rows 24 times using native X11 input.
This measures switching retained terminal sessions, not starting Codex, integrated
conversation views, physical keyboard latency or physical display scanout.

The script generates a test entry from the current GraphicalMain, inserting
`frame-probe.hx.inc`; production startup, workspace connections and polling stay
in use. The generated source and build are ignored. Frame diagnostics are written
after rendering. Click release timestamps come from a root capture handler, matching Workbench
activation on release. A frame rendered while the button is still held may
correctly retain the previous session.
Timing includes the observer's effect on scheduling; diagnostic serialization is
after the completion timestamp.

The pixel run captures after the native event pump returns, when presentation has
completed. Capturing inside onFrameRendered would read the previous presented
buffer. Pixel capture is intentionally separate from timing: synchronous PNG
capture substantially slows the event loop. Pixel checks compare a stable text
region across all captured transition frames, requiring distinct, consistent
content for each selected session. Frame diagnostics check selection, session
content and terminal view presence. Reports, screenshots and input observations
remain in the output directory. Manager state is symlinked to a short private
/tmp directory to respect Unix socket path limits.

To exercise both side-panel dividers against a TUI whose synchronized redraw is
split across delayed PTY writes, add `--resize --pixels`. The report checks every
submitted terminal row set for partial/empty output, verifies multiple grid widths,
and checks presented screenshots for retained text. This uses deterministic fake
Codex output through the real workspace PTY/RPC path; it does not run Codex itself.
