# Workbench redesign: questions for the owner (round 1)

These are the decisions that design depends on (WORKBENCH-DESIGN.md). Every question here can be answered now; the
ones that depend on these answers come in round 2. The point is to confirm what you expect to see and what you expect
to happen, not implementation details.

❓ **Q1** - **A click on a workspace row opens it**: Today a single click on another workspace's row only expands it,
and if that workspace is idle, it also starts its service. Enter or a double click opens it. Proposed: a single click
opens the workspace in this window. The tabs switch to that workspace's tabs, and Files, Search and Changes follow it,
exactly as a click on a group row does today. The chevron only expands or collapses, without opening anything.
Options:
- (a) A click opens; the chevron expands.
- (b) A click opens and also expands the row.
- (c) A click only selects; New Agent Session and the other actions work from the row without opening it.

➡️ (a). This is "selecting is Open". After a click on a running workspace, its tabs appear within 2 frames.

---

❓ **Q2** - **Where a session made from another workspace's row appears**: Tabs are kept per context
(machine/workspace/group). If you right-click `eon-series` while you are in `exosuit` and pick New Agent Session,
where does it open?
- (a) The window opens `eon-series` and the new session is a tab there. You are now in `eon-series`, and your
  `exosuit` tabs wait one click away.
- (b) The session opens as a tab in the current `exosuit` tab strip, marked with its workspace, and the window
  stays in `exosuit`. Tab strips can then mix workspaces.
- (c) It is created, but it only shows in the tree; no tab opens until you click it.

➡️ (a). It keeps one rule: tabs belong to the workspace you are in. It also fits Q1: what you click on is where you
end up. (b) is closer to "opening as a tab here", but it would give the side panels and the window title two
workspaces at once, so that is a separate decision.

---

❓ **Q3** - **What expanding an idle workspace does**: Today expanding an idle workspace starts its service, and the
rows show only if this window saw that workspace earlier in this run. Proposed: the service keeps a small snapshot on
disk, so expanding shows the last-known sessions, terminals and groups without starting anything. The service starts
only when you create something in that workspace or open one of its items.
- (a) Expand shows the snapshot and starts nothing.
- (b) Expand starts the service, as today, but quickly.
- (c) Every workspace runs all the time.

➡️ (a). Idle workspaces cost nothing, and with a fast start (Q4) the first create does not feel the difference.

---

❓ **Q4** - **One process per workspace, or one for all**: Today an idle workspace starts as a chain of three
HashLink processes (launcher, manager, service), each loading 12.6 MB of bytecode. That chain plus the connect
measures about 0.8 to 1 s on this machine. To get to milliseconds:
- (a) One process per running workspace, as today, started as one process instead of three. suit keeps one spare
  process already loaded, and that spare takes over the workspace you start; suit then loads the next spare. This
  costs one extra idle process. A crash or an update affects one workspace only. Expected about 50 to 200 ms (not
  measured yet).
- (b) One resident process serves every running workspace. Adding a workspace takes milliseconds and uses the
  fewest resources. A crash or an update of that process stops every workspace at once; terminals survive, because
  their host processes are separate.
- (c) Only collapse the chain to one process, with no spare. Expected about 0.2 to 0.4 s.

➡️ (a). It reaches the speed target with one spare process and keeps workspaces isolated from each other. (b) can
come later if the spare's memory turns out to matter.

---

❓ **Q5** - **When a running workspace stops**: In practice a workspace you have started keeps running until you
close the last editor window, because every window keeps a connection to every running workspace. Proposed: a
workspace stops after a period during which no window shows or uses it (no tab open, row not expanded) and none of
its sessions or terminals is active. Busy agents and live terminals keep it up.
- (a) Stop after N minutes of that. Which N? (Today's setting is 60 s with no clients.)
- (b) Never stop on its own; only Quit or Stop in suit ends it.
- (c) Stop as soon as the last window closes its tabs.

➡️ (a) with N = 10 minutes. With a fast start (Q4), stopping costs little, and a session's history comes back when it
resumes.

---

❓ **Q6** - **Remove the suit-off and single-folder modes**: The Workbench has a second code path for every decision,
for running without suit (`EXOSUIT_SUIT=off`, folder-only windows), plus rules that guess which workspace a window
opened on a bare folder belongs to. Proposed: suit is always on. Opening a folder opens the workspace that holds it, or
creates one for it.
- (a) Remove both.
- (b) Keep suit-off for tests only.
- (c) Keep both.

➡️ (a). It deletes the most code and leaves one model. Tests use an isolated suit home, as they already can.

---

❓ **Q7** - **New Agent Session without a dialog**: Today New Agent Session opens a chooser (provider and folder)
before anything is created. To match "add a workspace, then immediately open a session":
- (a) The menu item creates a session at once, with your default provider in the workspace's folder (or the group's).
  A submenu or a modifier key offers the other providers and Change Folder….
- (b) Keep the chooser, but have it start creating as soon as it opens, with the default already selected.
- (c) Keep the chooser as it is.

➡️ (a). One click, and typing works. A choice you have already made is not asked again.

---

## Round 1 answers (owner)

Q1 (a): every row has its full menu, open or idle, and a click takes milliseconds. Q2 (a). Q3 (a). Q4 (a): one
process per workspace, the chain collapsed to one process, plus a warm spare. Q5 (a), N = 10 minutes. Q6 (a).
Q7 (a).

# Round 2

Each of these follows from a round-1 answer. Nothing else is open now.

❓ **Q8** - **Which provider "New Agent Session" uses**: Q7 makes New Agent Session create a session at once with
"the default provider", but there is no such setting today. The chooser lists Codex, Claude, Pi and Exosuit, in that
order.
- (a) A setting, "Default agent provider", which you choose once (it starts as Claude or Codex: you say which).
  The submenu offers the rest.
- (b) The provider you used last, remembered per workspace.
- (c) The provider you used last, the same for every workspace.

➡️ (a), starting as the provider you use most. It is predictable: the same click always does the same thing, and the
submenu is one step away when you want another provider.

---

❓ **Q9** - **When the warm spare exists**: Q4 adds one pre-started spare process, so starting an idle workspace
takes milliseconds. suit holds it. Nothing starts at login (your earlier rule), and suit exits when nothing needs it.
- (a) The spare exists while at least one editor window is open. The first start after you launch the editor can
  find the spare still loading, which costs a fraction of a second once.
- (b) The spare exists whenever suit runs, also with no editor open, for example while only suitctl or the phone uses
  the machine.
- (c) A spare exists only after the first workspace start of the session, to be ready for the next one.

➡️ (a). It costs nothing when you are not using Exosuit, and it is ready by the time you click anything.

---

❓ **Q10** - **Opening a folder that no workspace holds**: Q6 removes folder-only windows. When you open a folder
(the command line, Open Folder, a drag) that is not attached to any workspace:
- (a) A new workspace named after the folder is created with that folder attached, and it opens.
- (b) You are asked: add the folder to the current workspace, or make a new workspace for it.
- (c) It opens as a loose folder in the current workspace's Files view only, without attaching it.

➡️ (a). One step, nothing to answer, and Remove takes it away again. Adding a folder to an existing workspace stays
in the row's Attach Folder….

---

❓ **Q11** - **A session that fails to start after you typed into it**: With input queued from the first keystroke, a
start can fail after you have typed (a broken build, a missing CLI). What should the tab do?
- (a) Keep the tab and what you typed. Show the cause in the tab with Retry, and send the queued text when a retry
  succeeds.
- (b) Keep the tab and the text, show the cause, and never send the text by itself: you send it again after the
  retry.
- (c) Close the tab and report the error in the notification area.

➡️ (b). Nothing you typed is lost, and nothing is sent later without you seeing it go. Text that runs as a command
in a terminal is not replayed after a delay you did not watch.

---

## Round 2 answers (owner)

Q8 (a): a "Default agent provider" setting, Claude for now. Q9 (a): the spare exists only while an editor window is
open. Q10 (a): a folder that no workspace holds becomes a new workspace named after it, and opens. Q11 (b): keep the
tab and the text, show the cause and Retry, and never send the text by itself.

No questions remain open. WORKBENCH-DESIGN.md is final for review.
