# ADR 0007: One core, two shells; touch controls in the UI kit; a session index instead of a session tree

Status: accepted (2026-11-18; proposed the same day). Builds on [ADR 0005](0005-machines-and-workspaces.md) and
[ADR 0006](0006-workspaces-without-folders.md). Mockups: the "PhoneShell mockups" canvas (Sessions, Terminal,
Machines, Unfolded, All sessions).

## Context

The Android app pairs with a machine and runs the desktop UI unchanged (`graphical/` `ExosuitApp`). On 2026-11-18 it
was used against a real exohost: it listed the machine's workspaces, opened the Workbench, attached to a running Claude
Code terminal, and sent a prompt that was answered. Everything works; the shape does not fit a phone:

- **Desktop chrome takes the space.** The activity rail is always about 14% of the width, the title bar shows `0 fps`,
  the tab strip truncates names, and the status bar doubles as the open-tabs switcher.
- **Navigation is the dock.** `ResponsiveLayout` shows one dock panel at a time below 480 px. A phone navigates a stack
  (list, detail, back), with a bottom bar for destinations.
- **The Workbench is a deep tree.** Machine, workspace, group, session: four levels, indented, right-edge icons
  clipped, rows smaller than a fingertip. Groups are mostly dates. "What needs me on this machine?" has no view.
- **Touch is partial.** The UI kit has tap, double-tap, long-press and drag recognizers, a gesture arena, safe-area and
  keyboard insets, and Back routing. It has no fling (drag reports no velocity), no pinch, no navigation stack, no
  bottom bar or bottom sheet, no snackbar, and sizes are desktop-only. Menus and tooltips assume a pointer.
- **Fold and unfold already work.** The Activity handles size changes itself (`configChanges` in the manifest), so a
  Z Fold resize reaches the running app as a resize. Verified on the emulator: 1080 to 1968 px wide and back, same
  process; the desktop split appears unfolded and one panel at a time folded.

## Decision

### 1. One application core, two shells

`ExosuitApp` (about 3,000 lines) is split into:

- **Core**: sessions, workspaces, the machine client, panels as views (TerminalPane, chat, the session index, Remote,
  Files, Search), commands, notifications. It knows nothing about docks, rails or tab strips.
- **Shell** interface: open, focus and close a view; show a notice; ask for a choice (menu or sheet); report the
  focused view. Two implementations:
  - **DesktopShell**: today's dock, rail, tabs, status bar and `ResponsiveLayout`, moved without behaviour change.
  - **PhoneShell**: a navigation stack (Back pops), a bottom bar (Sessions, Files, Search, Machines), full-screen
    views, sheets for menus, snackbars for notices. No rail, no tab strip, no fps in the title.

The shell is chosen by **form factor, not platform**: touch-primary and narrower than the breakpoint (initially
600 dp) uses PhoneShell; everything else uses DesktopShell. A fold or unfold swaps the shell in place: views and
sessions are core objects and survive the swap; the focused view is re-opened in the new shell (a terminal becomes the
full-screen terminal folded, and stays focused in the split unfolded). `AndroidExosuitFactory` stops special-casing
panels; the shell decides.

### 2. Touch controls belong to the UI kit

Generic controls go into haxeon's UI kit (`haxeon/packages/ui`), as small commits on the exosuit fork branch that can
go upstream:

| Control | Why |
| --- | --- |
| Fling scrolling: drag velocity, momentum, overscroll edge | lists stop dead without it; touchpads gain too |
| Density tokens: row height, touch target (48 dp), indent, font scale | the same widgets draw touch-sized, no forks |
| NavigationStack: push, pop, slide transition, Back pops | PhoneShell's backbone |
| BottomBar: icon and label destinations, safe-area aware | replaces the rail |
| BottomSheet / ActionSheet | replaces right-click menus; long-press opens it |
| Snackbar | "Connection lost · Retry" instead of status-bar text |
| Pinch recognizer | terminal font zoom |
| Swipe recognizer and swipe row actions | swipe a session to stop or archive; swipe between open sessions |
| Touch text selection with handles | copy from the terminal and chat |
| Tooltips: long-press fallback, none on touch-only | no hover on a phone |

Exosuit-specific screens (session list, terminal key row, Machines) stay in `graphical/src/ui`.

### 3. A session index replaces the session tree as the model

All sessions of a machine (later, of every paired machine) form one **index**. Each session carries facets: machine,
workspace, groups (tags; a session can be in several), kind (Claude, Codex, terminal, chat), state (needs attention,
working, idle, exited) and last activity.

- **Views are filters plus a sort plus a sectioning** over the index. The default is "All sessions": needs attention
  first, then working, then most recent.
- **Scope is a filter, not a location. No breadcrumbs.** Groups are tags, so there is no "up" to navigate to:
  - The title is the scope switcher: `cube ▾` (all workspaces) or `exosuit ▾` opens a sheet to pick a machine or
    workspace in one step from anywhere.
  - Group, kind and state are chips. A chip opens a searchable sheet; several groups can be picked; clearing a chip
    widens the list again.
  - Back belongs to screens, not scope: it leaves a terminal for the list exactly as it was. Changing a filter never
    adds a Back step.
  - Saved views ("Needs me", "exosuit · today") can later be pinned as chips; they replace deep paths.
  This generalises today's Agent Mode group scope.
- **Sectioning is a display choice**: by workspace, group, day or state. Date groups can come from timestamps;
  hand-made groups stay as named collections.
- **The desktop tree stays as one projection**: "section by workspace, then group" draws today's Workbench tree from
  the index, and drag-to-regroup edits a tag. The phone's Sessions screen is another projection of the same index.
- **Notifications are the needs-attention filter.**

exohost gains a machine-wide session query that merges every workspace service's sessions with state and last
activity (each service already lists its own; the phone shows them today). `WorkbenchTreeModel` becomes a projection
of that index. Stored groups do not change format; they are read as tags.

## Phases

Each phase is reviewed and lands separately, with an emulator screenshot check (headless, `adb exec-out screencap`)
and the affected suites.

1. **Kit basics**: fling scrolling and density tokens. Improves today's app on the phone at once.
2. **Shell split**: extract the Shell interface and DesktopShell with no behaviour change (desktop suites and a GUI
   capture unchanged).
3. **PhoneShell v1**: NavigationStack and BottomBar in the kit; Sessions (current tree data) and the full-screen
   terminal; fold and unfold swap the shell.
4. **Session index**: exohost's machine-wide query, the index model, All sessions with chips, breadcrumb and
   sectioning, on phone and desktop; the tree becomes a projection.
5. **Touch polish**: sheets for menus, snackbar, swipe actions, pinch zoom, touch text selection, Machines screen.

## Consequences

- The desktop does not change until phase 4, and then only gains the All sessions view; its tree keeps working.
- A narrow desktop window can opt into PhoneShell later; a tablet or an unfolded Fold keeps DesktopShell.
- UI kit work lands on the haxeon fork branch first; until it is upstream, Exosuit pins that branch.
- Open: the exact breakpoint (600 dp or the Fold's outer width), whether chat sessions and terminals share one list,
  and how a session in several groups is drawn in the tree projection.

## Learned while building it (2026-11-18)

- A touch-primary host under 600 dp gets PhoneShell; the Fold's unfolded inner screen (1968x2184 px) gets DesktopShell
  and the open session stays focused across the swap. `EXOSUIT_FORM_FACTOR=phone` gives the desktop a 412x915 phone
  window driven by scripted touch, which is where the layout was checked before the emulator.
- Chat sessions and terminals share one list. A chat opened from the phone must say it is shown
  (`showAgents`), or its view is never read.
- In the kit, `grow` also grows to fit content: a screen inside a stack must use `stretch` or its list never scrolls.
- A sheet's focus trap focuses its first focusable node; the handle comes first so a sheet does not raise the
  on-screen keyboard.
