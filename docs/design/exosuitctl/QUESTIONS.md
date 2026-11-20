# exosuitctl: questions

## Rounds 1 and 2, answered
Q1 A · Q2 (b) · Q3 (a) · Q4 (d) · Q5 (a) · Q6 (a) · Q7 (a), named `exosuitctl` · Q8 (a) · Q9 (a) · Q10 (b) · Q11 (a) ·
Q12 (a) · Q13 (a) · Q14 (a) · Q15 (a), plus the Workbench redesign. The decisions table in `TDD-exosuit-ctl.md`
(header) records them.

## Round 3, answered: Q16 (c) · Q17 (a) · Q18 (a) · Q19 (b). No questions remain open; the TDD is final for review.

❓ **Q16** - **Line and column when opening a file**: `editor.open` gets optional `line` and `column` params, which
Pragtical ignores. The command line needs a way to pass them. On Windows `C:\a.txt:12` is ambiguous because of the
drive letter's colon. Options:
- **(a)** `path:line[:col]`, parsed only when the trailing parts are digits and the whole string is not an existing
  file. This is the form compilers print, so it can be pasted from build output.
- **(b)** An explicit flag only: `exosuitctl open --line 12 --column 3 PATH`, and `exosuit --goto 12:3 PATH`.
- **(c)** Both.

➡️ (c). (a) for pasting from compiler output, and (b) for scripts that must never be misparsed. The rule "only when
digits and no such file" is tested on drive-letter paths.

---

❓ **Q17** - **What does `terminal.read` return?**: Agents and tests read terminals through the control plane (T4).
Options:
- **(a)** Rendered text: the visible screen rows, the cursor position, and scrollback lines since a sequence number.
  This is what a person sees, and what an agent can reason about.
- **(b)** The raw VT byte stream since an offset. It is exact, but every client must emulate a terminal.
- **(c)** Both, chosen per call.

➡️ (a) now. (b) only if a test needs byte-exact output, since the editor already holds the rendered model.

---

❓ **Q18** - **How do clients get events?**: Pragtical sends every event to every client that completed hello. exohost
will carry many more events (`ui.changed`, terminal output, `exosuit.state`), which most CLI calls never want.
Options:
- **(a)** On exohost's main pipe, a client subscribes explicitly (`exosuit.events.subscribe {names, instance?}`), and
  `exosuitctl watch [EVENT...]` streams the events as JSON lines. The Pragtical pipes keep Pragtical's behaviour but send
  only Pragtical's two event names.
- **(b)** Every client gets every event, as in Pragtical.

➡️ (a). It keeps one-shot CLI calls cheap and gives agents a stream to wait on instead of polling.

---

❓ **Q19** - **What happens when you type while an agent is driving the same window?**: With Q10's synthetic input,
your real keys and the agent's injected input can interleave in one window. Options:
- **(a)** No arbitration. Both go into the queue in arrival order. The tray's "being driven" indicator is the warning.
- **(b)** Real input wins. Injected input is held back while real input arrived in the last ~1 s, and the call
  answers `busy` (retryable) when it waits too long.
- **(c)** Injected input goes only to windows that do not have the OS focus.

➡️ (b). Your input should never be corrupted by an agent, and `busy` with retryable=true is already the protocol's
way of saying "try again shortly".
