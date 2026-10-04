# M9 — Editor shell parity on UIKit

Depends on M8. This milestone recovers behavior that M2–M4 delivered on the old
renderer and the UIKit port lost. It also adopts the shell improvements from
the Pragtical fork. Add widget capabilities in UIKit (`../uikit`) as general
features; do not special-case exosuit inside UIKit.

## M9.1 — Styled text and decorations

- [x] Add styled spans or decoration ranges to UIKit `TextArea`/`TextLayout`:
  foreground color, background, underline (wavy for diagnostics) and
  whole-line backgrounds. Reuse the measured layout and invalidate only the
  changed rows.
- [x] Render syntax highlighting from the existing syntax registry,
  diagnostics from `PluginDecorationRegistry`, search matches, bracket
  matches and the current line.
- [x] Render multiple selections and carets from the normalized
  multi-selection model (M2.4).

Acceptance: highlighting repairs after edits at multiline boundaries.
Diagnostic underlines follow edits and clear on fix. Multi-caret typing is
visible and correct. Typing p95 stays within the M7.1 budget.

## M9.2 — Editor surfaces

- [x] Anchor hover, completion and signature popups to the real caret
  rectangle instead of the fixed `TextInputArea` in `UiWorkbenchHost.hx`.
- [x] Add context menus for the editor, tabs and the file tree using UIKit
  popups. Their commands go through `CommandRegistry`.
- [x] Implement `focusPane`, `moveActiveTab` and `closeActivePane` with
  DockWorkspace splits. Persist the layout through DockWorkspace persistence
  and the session.

Acceptance: keyboard-only split, focus, move and close works. Layout and open
tabs restore after restart. Popups track the caret while scrolling.

Verified for Linux automation on 2026-10-04; see STATUS for separate-process
restart, keyboard-only document panes, terminal grid resizing and session
recovery evidence. Terminal-tab keyboard transfer and physical IME/non-Linux
acceptance are separate follow-ons.

## M9.3 — Sidebar modes and search

- [ ] Port the Pragtical shared sidebar idea onto DockWorkspace: a
  registerable sidebar host with modes (`register(mode, provider, {label,
  order, visible, width})`), lazy providers, a tab strip, and persisted mode,
  visibility and per-mode width. Files becomes the first mode.
- [ ] Add a Search mode that renders `workspaceSearchResults`, with
  navigation and replace preview. Workbench registers its own mode in M14.
- [ ] Mouse-wheel scrolling must reach scrollable panels; this mirrors the
  Pragtical fix.

Acceptance: modes switch by command and click. Restart restores mode and width.
Project search results navigate to the correct positions after edits.

## M9.4 — Smooth scrolling

- [ ] Port the uncommitted Pragtical change (`data/core/view.lua`,
  `config.lua`, `settings.lua` in `../pragtical`). Use a frame-rate-independent
  exponential approach, `1 - 0.01^(dt/duration)`, with a default duration of
  0.12 s that snaps within 0.5 px. Expose `scroll_animation_type` and the
  duration in configuration. Read the uncommitted diff; do not modify that
  checkout.

Acceptance: these deterministic tests mirror `scripts/lua/tests/view.lua`. The
first frame moves more than 40% of the distance. Motion settles within the
duration. Reversing direction keeps no momentum.

Exit: README known-gaps no longer lists styled text, multi-cursor rendering,
context menus or pane operations.
