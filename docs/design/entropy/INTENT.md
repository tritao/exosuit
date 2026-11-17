# What Exosuit is meant to be (the yardstick for the entropy pass)

Distilled on 2026-11-15 from the owner's answers in `docs/design/workbench/QUESTIONS.md` (Workbench Q1–Q11),
`docs/design/exohostctl/QUESTIONS.md` and the decisions table in `TDD-exosuit-ctl.md` (exohostctl Q1–Q19), and the owner's
standing instructions. Every mechanism in the codebase is judged against these statements. Code that exists only to
serve a model the owner rejected is junk, however well it is tested.

## The owner's complaint

"I really feel we made this thing a lot more complex than it needs to be." The workspace work, M19, exohost and the
mobile app added junk and meaningless code. The goal is a codebase that is lower in entropy, higher in quality,
simpler, faster, cleaner and leaner.

## Product intent

1. **Exosuit is the owner's daily editor.** The things that hurt today:
   - opening a workspace is slow;
   - a new workspace does not immediately offer sessions;
   - terminals die, and resume rarely works.
2. **Speed: milliseconds, no waits.**
   - A click on a workspace opens it. A click takes milliseconds.
   - Starting a workspace's service on this machine should take milliseconds. Every "wait for reconnect" needs a
     reason to exist.
3. **One model, with exohost always on.**
   - The exohost-off mode (`EXOSUIT_EXOHOST=off`) and folder-only windows are removed (WB Q6).
   - A folder that no workspace holds becomes a new workspace named after it, and opens (WB Q10).
   - Tests use an isolated exohost home, not a second code path.
   - The owner agreed to this on the condition that Exosuit is very fast. They also want a later "VS Code
     replacement" use: `exosuit <folder>` or `exosuit <file>`, which just opens it. That must stay cheap to add, as
     a presentation of the same model (a one-folder workspace, a loose file tab in the MRU window, the Workbench out of
     the way), never a second code path. A simplification that would make it hard is wrong.
4. **One connection concept: a link per workspace, plus a focus.**
   - Selecting a workspace opens it (WB Q1). Every row, open or idle, has its full menu.
   - A session made from a row opens in that workspace, and the window goes there (WB Q2).
   - "Which workspace this window is attached to" stops gating actions. The attached-versus-foreign split and its
     implicit state machine go.
5. **Workspace processes.**
   - One process per running workspace instead of the launcher → manager → service chain, plus one warm spare held by
     exohost while an editor window is open (WB Q4, Q9).
   - Idle workspaces cost nothing and show a last-known snapshot without starting anything (WB Q3).
   - A workspace stops after 10 minutes unused; busy agents keep it up (WB Q5). Live terminals no longer need to: their
     hosts outlive the service, and the next service takes them back (ENTROPY-PLAN §5).
6. **Push, not poll.** Polling while nothing changes is waste.
7. **New Agent Session creates at once,** with a "Default agent provider" setting (Claude for now) and a submenu for
   the others (WB Q7, Q8). A failed start keeps the tab and the typed text, shows the cause and Retry, and never
   sends the text by itself (WB Q11).
8. **exohost is the final arbiter and the single control plane.**
   - exohost lists everything Exosuit-related and can end all of it. A polite quit keeps terminals.
   - exohost is the only server, Pragtical control protocol v1 compatible. `exohostctl` and `exohost` are one program with two
     invocation names (Q1, Q7).
   - Each editor keeps one persistent link to exohost. Quit is a request the editor answers, not WM_CLOSE (Q4).
   - The link replaces the editor's registry file (Q6).
   - Automation command files and `snapshot.json` are retired in favour of protocol methods and events (Q9, Q11).
   - Events are opt-in (Q18).
   - Every mechanism exohostctl replaces is removed, not kept beside it (exohostctl goal 7).
9. **Exosuit can be driven entirely over the protocol, without computer use** (exohostctl G8). Synthetic input goes
   into the UI's own queue, never OS input (Q10). Real input always wins (Q19).
10. **Terminals survive and resume.** Terminal hosts outlive services. Agent sessions (Claude, Codex, Pi) resume their
    own conversation.
11. **The mobile app matters** (Z Fold 7). Remote access goes through exohost and the relay. It is only worth what it
    does, not what it adds.

## Engineering intent

- **Low entropy** in design and in history. There is one way to do each thing. Removed beats added, and merged beats
  parallel. A history of a few topic commits built from the final tree is the model (214 → 17 commits was "a great
  compression number").
- **Tests prove real behaviour.** The owner distrusts the 70-suite run ("mostly garbage"). Keep the tests that
  exercise a real feature path. Delete tests that pin removed mechanisms, test mocks of mocks, or prove nothing. Where
  code is simple enough, a careful read beats a test.
- **Progress, not ceremony.** No useless test runs, and no timeouts far beyond the expected runtime.
- **Docs match the code.** Stale status notes, roadmap boxes and handoff files are entropy too.
- **haxeon is out of scope here** (a separate pass covers it). Compiler bugs and workarounds met on the way are noted
  in `docs/haxeon-compiler-bugs.md`.
