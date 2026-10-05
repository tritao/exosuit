# Configuration

Open **Settings…** from the command palette or press **Ctrl+,**. UIKit's settings
panel provides category navigation, search, an Advanced switch, validation and
per-setting reset controls. Changes save automatically and apply to open editors.
Font file and fallback changes marked with an asterisk require an application restart.

Preferences use UIKit's JSON settings store. Only values that differ from their
registered defaults are saved; resetting a preference restores its default.
Unknown module settings survive saves. Legacy `settings.conf` files are ignored.

The user file is `settings.json` in the existing application configuration directory:

- Linux/BSD: `$XDG_CONFIG_HOME/pragtical-haxeon`, or `~/.config/pragtical-haxeon`.
- macOS: `~/Library/Application Support/Pragtical Haxeon`.
- Windows: `%APPDATA%/Pragtical Haxeon`.

`PRAGTICAL_PORTABLE` overrides both configuration and state directories. Session,
recovery and other workspace state retain their existing storage formats and locations.

```json
{
  "version": 1,
  "values": {
    "editor/fonts/font_size": 16,
    "editor/display/minimap_enabled": true,
    "editor/display/scrollbar_visibility": "auto",
    "editor/display/scroll_animation_type": "smooth",
    "editor/display/scroll_animation_duration": 0.12,
    "editor/indentation/tab_width": 4,
    "editor/indentation/insert_spaces": true,
    "terminal/fonts/font_size": 14
  },
  "state": {}
}
```

Scroll animation accepts `smooth` or `none`; duration is 0–0.3 seconds.
Scrollbar visibility accepts `auto`, `always` or `hidden`. The minimap hides on
narrow editor panes. Font paths should be absolute; built-in defaults resolve
relative to the installed application. Theme colors under `appearance/colors`
are signed RGBA integers and appear under Advanced settings.

The graphical editor resolves default script and emoji fallback fonts from the
platform when needed. An explicit `editor/fonts/font_fallback_paths` list is loaded
at startup in its configured order.

Array preferences are JSON strings containing arrays. For example, the value of
`languages/haxeon/command` is `"[\"/path with spaces/haxeon-lsp\",\"--stdio\"]"`.
An empty array uses `$HAXEON_LSP`, then the bundled server, then
`$HAXEON_ROOT/scripts/haxeon-lsp`. Arguments are passed directly without shell splitting.
Advanced keyboard overrides use the same array representation, with entries such
as `"Ctrl+A|doc:select-all"` under `editor/keyboard/keybindings`.

Project configuration is separate, in `.exosuit/project.json`. It uses the same
JSON envelope and supports `languages/haxeon/enabled`, `languages/haxeon/command`,
`languages/haxeon/verbose` and `files/explorer/excluded_names`. Other preferences
remain user-wide. Project values that differ from defaults override user values;
resetting a project value resumes inheritance. External JSON edits are checked
at most twice per second while the application updates. Malformed JSON leaves
the last valid settings active; saved values outside their registered type or
range fall back to defaults, following UIKit's store policy.

Haxeon sessions belong to workspace folders. The first backed `.hx` document
starts that folder's server; nested folders own their documents in preference
to outer folders. Tab switches and closing the last document keep the session
warm. Removing a folder or disabling its server retires that session. Changing
its server configuration restarts only that folder's session, including a warm
session with no documents. Explicit Stop suppresses automatic startup for that
folder until Start is used or the folder is removed. Failures appear in status and Problems;
restarts back off by 0.25, 0.5 and 1 second, then require recovery via settings
or Start. Thirty seconds of healthy operation resets the retry count.

Language commands appear in the command palette when the active document's
server supports them. Default shortcuts are Ctrl+Space for completion,
Ctrl+Shift+G for document symbols, Ctrl+Shift+H for references, and Ctrl+Alt+H
for rename. Symbols and references use a searchable picker; Enter navigates
and Escape dismisses. Rename asks for a new name and updates managed buffers
without saving them. Undo each affected document to reverse its changes.

In the graphical Explorer, a single file click opens a preview in the active
editor pane. Each pane reuses its one preview tab when another file is clicked.
Double-click a file or its tab to keep it open. Editing, moving, or reordering
a preview also keeps it open; undoing an edit does not make it temporary again.
Folder labels and disclosure arrows expand or collapse on a single click.
A double-click on a folder label toggles it once. Right-click selects a tree item and opens its menu without previewing it.

Graphical scrollbar visibility is shared by UIKit scroll views.
`workbench.scrollbarVisibility=auto` (default) keeps the bar transparent until
its narrow edge control is hovered or the content is scrolled. It remains
visible during hover, dragging, or keyboard focus, then waits 500 ms and fades
over 200 ms. UIKit's reduced-motion preference skips the fade.
Use `always` to keep overflowing scrollbars visible, or `hidden` to remove both
the bar and its pointer target while retaining wheel and keyboard scrolling.
Changes apply live across scrollable panels. Bars overlay content without
changing viewport size.

`editor/display/minimap_enabled` shows a file overview on the right of graphical and web editors.
Click to jump or drag its viewport to scroll. It hides below 480 logical pixels of
editor width. Previews keep a consistent miniature scale and scroll with the editor instead of
compressing the whole file. Cached pages contain at most 512 lines and 80 columns; large files use
neutral strokes to avoid forcing full-document syntax highlighting. The preview
is cached as an 80-column bitmap with at most 1,024 rows, keeping GPU geometry
bounded even for dense files.

`editor/display/tab_tooltip_delay` controls the tab tooltip hover delay in seconds (default `0.8`, range `0`–`5`). Tooltips hide when leaving or clicking a tab.

The sidebar uses one shared width across Activity Bar destinations. Resizing, collapsing, and reopening retain that width. Older sessions migrate from the selected destination’s saved width.

Editor text and line numbers request a dedicated monospace font family. The configured editor font is loaded into that family, with a system monospace fallback if unavailable. Workbench labels retain their proportional UI font. The browser bundles IBM Plex Mono for code and IBM Plex Sans for UI.

Application zoom is stored as `appearance/workbench/zoom_percent` (default 100,
range 70–200). Ctrl+= or Ctrl+Shift+= zooms in, Ctrl+- zooms out, and Ctrl+0
resets to 100%; macOS uses Cmd. Each step changes zoom by 10 percentage points.
Zoom scales the whole interface and is independent of editor/terminal font size
and monitor pixel density. It applies immediately and persists across launches.

Text fields and the editor support Ctrl+Backspace/Delete to delete the previous/next
word (Option on macOS). Selected text is deleted as-is. Editor word deletion works
with multiple carets and restores the original carets on undo.

Text fields keep their own undo history: Ctrl+Z undoes, Ctrl+Shift+Z or Ctrl+Y
redoes (Cmd+Z/Shift+Z on macOS). Typing groups end at navigation, focus changes,
spaces, or a one-second pause. Paste, word deletion, and IME composition have
separate undo steps. The code editor keeps its document-owned history.
