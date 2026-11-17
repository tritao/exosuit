# Questions for the owner (entropy pass)

These are the decisions the plan cannot take from INTENT or from the code. Each has a recommended answer, marked ➡️.
The plan ([ENTROPY-PLAN.md](ENTROPY-PLAN.md)) says which step waits on which answer. Steps 0 to 7 need none of them
except E4 and E5, which only change how much Step 5 deletes.

## E1. The built-in chat view for agent sessions

Exosuit can show an agent session in two ways. One is a terminal running Claude, Codex or Pi; this is the default and
costs about 650 lines. The other is Exosuit's own chat view, which talks to the agent programs directly. The chat
view is about 12,000 lines, plus about 5,500 lines of tests. Today every workspace service prepares all four chat
providers at each start, even if no chat session exists; for Codex that starts three extra programs.

- A. Remove the chat view. Agent sessions are terminals only. Removes about 12,000 lines.
- ➡️ B. Keep it, but make it cost nothing until you open a chat session. Nothing starts and nothing is polled for it
  otherwise. Merge its three near-copies per provider into one (about 850 lines less). Decide on removal later, once
  the phone app shows whether a chat view is needed there.
- C. Leave it as it is.

Why B: it fixes the speed cost now and keeps a feature a phone screen may need. If you never use the chat view and
do not want it on the phone, A is the larger clean-up and I would take it.

## E2. Remote access from a web browser

A phone can reach your workspaces in two ways: the Android app, and a web page in a browser. They use different
machinery. The app goes through exohost. The web page makes each workspace service connect out by itself, which is the
older design. Keeping the web page means keeping that older design alive, or rebuilding the page on the new one.

- ➡️ A. Drop the browser client. The Android app is the remote client. Removes about 2,400 lines of product code,
  about 1,200 more of the older hosting design, and about 950 lines of tests.
- B. Keep it and rebuild it on exohost, like the app. About 500 lines of new work; the older design still goes.
- C. Keep both designs.

## E3. Workspace files (`.exosuit-workspace`) and "Recent workspaces"

There are two things called a workspace. One is the list exohost keeps, which the Workbench shows. The other is a file
you save with "Save Workspace As…" and reopen from the welcome page. The file kind predates the Workbench. With both,
a window can be in four different states, and several menus exist twice.

- ➡️ A. Remove the file kind: the save and open commands, the welcome-page buttons and the recent list. A workspace is
  what the Workbench lists. `exosuit <folder>` still opens a folder: it becomes a workspace named after the folder.
  Removes about 400 lines.
- B. Keep the files as a way to export and import a workspace from exohost's list. About 150 lines stay.
- C. Keep both kinds.

## E4. When a workspace service is from a different build than the editor

Today a service can keep running across editor builds. To support that there is code that compares builds, shows
"Workspace connected (another build)", offers an update, and lets you choose per workspace which build manages it
(the "Machine" side panel). About 650 lines.

Once terminals always live in their own host programs (Step 1), restarting a service loses nothing you can see.

- ➡️ A. Remove all of it. When an editor opens a workspace whose service is from another build, exohost restarts that
  service at once, unless an agent turn is running in it; then it restarts when the turn ends. Terminals carry on.
- B. Keep the "another build" notice and a manual Restart button. Remove the per-workspace build choice.
- C. Leave it as it is.

One thing to confirm with A: your stable build and a development build should not share workspaces at the same time.
Development runs already use separate state, so this is the case today.

## E5. Old saved state

About 1,550 lines exist only to read state written before the workspace change of 2026-10-31, and to convert it.
The conversion check runs every time a service starts. On this machine the conversion is done.

- ➡️ A. Remove it. A service that meets old state stops with a clear message that names the last build able to
  convert it.
- B. Keep the conversion one more month, then remove it.

Choose B only if another machine, or a backup you may restore, still has state from before 2026-10-31.

## E6. The built-in "Exosuit" agent (AgentKit)

Beside Claude, Codex and Pi there is a fourth provider: a small agent built into Exosuit. Nothing else depends on it.
One damaged record of it stops a whole workspace service from starting. It is about 920 lines in Exosuit, 513 lines
of tests, and 1,726 lines in haxeon packages.

- ➡️ A. Remove it from Exosuit. The haxeon packages stay where they are for the haxeon pass to judge.
- B. Keep it, fix the start failure, and load it only when used.

## E7. Window tests that only run on Linux

21 test scripts drive a real editor window on Linux (through a virtual display). The Windows test run skips all of
them, and five have no caller at all. They cover editor decorations, the workspace UI, the language server in the UI
and the terminal cursor: about 5,500 lines of tests plus the scripts.

- ➡️ A. Delete them. After Step 9 the editor can be driven through exohost on any system, so the checks worth keeping are
  rewritten once in that form and run on Windows too. Linux keeps building and keeps the non-window tests.
- B. Keep them until Step 9 is done, then port all of them.
- C. Keep them; Linux window tests are a goal of their own.

## E8. Bringing an agent terminal back after its program has ended

When a Claude, Codex or Pi terminal has ended (a reboot, or its host program died), its row stays in the Workbench.
Today the conversation only continues if you choose Restart from the menu.

- ➡️ A. Opening such a row continues the conversation by itself, in the same tab. It never sends any text for you.
  Plain shell terminals show their last screen and start a new shell only when you ask.
- B. Keep it manual, but name the button "Resume" and show it in the tab.
- C. After a reboot, bring back every agent terminal at once, without waiting for you to open it.

Why not C: it starts many agent programs at login for sessions you may not look at.

## Owner answers, round 1 (2026-11-15)

- **E1: keep the chat view, made lazy (B).** The owner wants the first-class chat UI fleshed out later for Claude and Pi as well as Codex, and will use it more once Exosuit is stable and fast. So it costs nothing until a chat session opens, and the three near-copies per provider merge into one base. Nothing is removed.
- **E2: B.** Exosuit in the browser stays and is rebuilt on exohost. The Android app is a different kind of remote client. The service's own outbound hosting still goes.
- **E3: A.** Workspace files and the Recent workspaces list are removed.
- **E4: A.** exohost restarts a service from another build at once (after a running agent turn), and terminals carry on. The notice, the update offer and the Machine panel go.
- **E5: A.** Pre-10-31 state readers and the conversion are removed.
- **E6: A.** AgentKit is removed from Exosuit. The haxeon-agentkit packages stay in haxeon for its own pass. Its removal and E5's are pure deletions, so both move into step 0.
- **E7: A.**
- **E8: A.**
