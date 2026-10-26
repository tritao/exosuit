# M12 — Integrated terminal

Depends on M11.1, M11.4 and M9. The reference is Pragtical's terminal plugin
(`../pragtical/subprojects/terminal/plugins/terminal/`), which has about 70
`terminal:*` commands.

## M12.1 — Session model

- [x] Define a `TerminalSession` abstraction: id, status, write, resize,
  pollEvents, requestReplay, terminate, detach, close, offset and
  applyCheckpoint. Output is ordered by byte offset. Drop duplicates, and
  request a replay when there is a gap. Workbench sessions (M14) can supply
  another backend to the same session model.
- [x] Local backend over M11.1 and M11.4. Add profiles (shell, cwd, env) and
  register them through the plugin API. Do not pass the host `NO_COLOR` to
  children. Set `TERM=xterm-256color`.

Acceptance: deterministic tests feed out-of-order, duplicate and gapped output
and assert the final screen and replay requests.

## M12.2 — Terminal view

Initial Linux slice: a local shell opens in a dock panel. Retained UIKit row
canvases repaint changed cells with indexed and true-color foreground/background
colors and a cursor marker. The pane resizes the PTY to its resolved cell grid.
Default and ANSI colors now follow paired workbench light/dark palettes.
Text input, navigation/control keys, emulator Kitty key encoding when active,
focus reporting, Ctrl+Shift+V clipboard paste with DEC 2004 bracketed-paste
encoding, application mouse reports (click/release/drag/hover/wheel), and wheel
scrollback are wired. Shift-wheel scrollback bypass and Control-wheel/hover modifiers are verified
on Linux; pixel-precision mouse reporting still needs qualification. Left-drag
selection (Shift-drag during application mouse reporting), native highlighting
and Ctrl+Shift+C clipboard copy are implemented and verified with reversed
multiline Japanese text. Search, links and font roles remain open. `scripts/test-terminal-ui.sh`
exercises the live dock, resize, and shell input under Xvfb. The checklist below
remains open for full terminal behavior and measurement.

Application shortcut routing is command-based in both panel and editor terminals.
Quick Open (Ctrl+P), the command palette (Ctrl+Shift+P), tab switching
(Ctrl+Tab / Ctrl+Shift+Tab), sidebar visibility (Ctrl+B), terminal toggles,
settings, new/open file dialogs, zoom, layout and navigation commands take priority over PTY input.
Rebinding one of these commands follows its ID, including bindings to plain
Ctrl letters. Editor editing commands remain with the shell by default, so
Ctrl+C, Ctrl+D, Ctrl+R and Ctrl+Z retain their terminal meaning. Ctrl+Shift+C/V
continue to copy/paste in the terminal. Terminal search is not implemented yet;
Ctrl+F continues to reach the shell.

The user preference `terminal/keyboard/commands_to_skip_shell` is a JSON array
of overrides to `ui.TerminalShortcutPolicy`'s default command IDs. For example,
`["-files:open", "my:command"]` returns Quick Open's current shortcut to the
shell and gives `my:command` application priority. Domain IDs accept the
optional `exosuit.` bridge prefix; the last override for an ID wins. Changes
apply to existing terminals immediately. Routing resolves the winning binding
and focus scope before filtering; a rejected binding cannot expose a lower
priority command. Disabled or unbound commands fall back to terminal input,
nonrepeatable commands suppress held-key repeats, and modal focus traps block
application commands. `scripts/test-terminal-cursor-ui.py` covers routing and
PTY bytes alongside the rendering checks.

- [ ] Add a grid-rendering view on UIKit `CanvasView`. Redraw only dirty rows.
  Support bold and italic through font roles, 256-color and true color, a
  `theme`/`tango` scheme, `minimum_contrast_ratio` (default 3) with a bounded
  cache, cursor styles, and scrollback scrolling.
- [ ] Input: key encoding including Kitty keyboard protocol mode, paste
  (bracketed), mouse reporting, focus events and IME commit.
- [ ] Selection and copy, search in scrollback, clickable links, font size
  increase and decrease, and terminal-specific font roles.
- [ ] Placement: open in a dock tab or a toggleable drawer. Restart the local
  session. Close prompts while a foreground process is running.

Acceptance: the view runs `vim`/`less`/`htop`-class full-screen programs
(alternate screen, mouse), handles resize without corruption, and copies the
selection. Port `terminal_redraw` as a benchmark. It must cover 600×40
256-color output, record frame time p95 in `docs/release-qualification.md`,
and keep typing latency in a neighboring editor within budget.

Exit: daily shell use inside the editor without falling back to an external
terminal.
