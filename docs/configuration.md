# Configuration

Pragtical Haxeon reads versioned `key=value` data. Built-in defaults are applied
first, then user settings, then the active project's `.pragtical/settings.conf`.
Project configuration is parsed only as data and is never executed. A file with an
unknown key, unsupported version or invalid value is rejected as a whole; the last
valid effective settings remain active and the error is shown in the editor.

The user settings file is stored at:

- Linux and BSD: `$XDG_CONFIG_HOME/pragtical-haxeon/settings.conf`, falling back
  to `~/.config/pragtical-haxeon/settings.conf`.
- macOS: `~/Library/Application Support/Pragtical Haxeon/settings.conf`.
- Windows: `%APPDATA%/Pragtical Haxeon/settings.conf`.

Session, recovery, replacement-backup and trash data use `$XDG_STATE_HOME` on
Linux/BSD, `~/Library/Application Support` on macOS and `%LOCALAPPDATA%` on
Windows. Setting `PRAGTICAL_PORTABLE` makes that directory authoritative for both
configuration and state, independent of the host platform.

Every non-empty file starts with `version=1`. Supported settings are:

```text
version=1
editor.fontPath=data/fonts/JetBrainsMono-Regular.ttf
editor.fontFallbacks=data/fonts/NotoSansSymbols2-Regular.ttf,/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc,/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf,/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
editor.fontSize=15
editor.tabWidth=4
editor.insertSpaces=true
editor.scroll_animation_type=smooth
editor.scroll_animation_duration=0.12
plugins.haxeon.enabled=true
plugins.haxeon.command=[]
plugins.haxeon.verbose=false
workbench.sidebarWidth=220
files.exclude=.git,.hg,.svn,.devstack,build,out,node_modules
search.caseSensitive=false
search.wholeWord=false
search.maxResults=10000
keybinding=Ctrl+Shift+P|commands:open
```

Theme colors are signed decimal RGBA integers. The configurable roles are
`editorBackground`, `editorForeground`, `accent`, `surface`, `surfaceElevated`,
`surfaceActive`, `surfaceInactive`, `surfaceHover`, `border`, `divider`,
`foregroundMuted`, `foregroundSubtle`, `foregroundDisabled`, `selection`,
`searchMatch`, `caret`, `overlay`, `information`, `warning`, `error`, and
`scrollbar`, each prefixed with `theme.`.

Files are watched by bounded polling. Valid changes replace fonts and keymaps
live; removing an override restores the value from the next lower layer.
Relative font paths in user or project settings resolve relative to that settings
file. Built-in font paths resolve relative to the installed executable, so launch
working directory does not affect packaged resources.

Editor scrolling uses `smooth` (default) or `none` (immediate).
`editor.scroll_animation_duration` is seconds from 0 to 0.3; 0 is immediate.
Smooth motion covers 99% of the distance in that duration and snaps within
0.5 logical pixels. Wheel reversals respond immediately. Scrollbar dragging,
session restoration use immediate offsets. These settings
reload for existing and future document panes.

Haxeon language-server commands are JSON arrays of executable and arguments;
for example `plugins.haxeon.command=["/path with spaces/haxeon-lsp", "--stdio"]`.
An empty array uses `$HAXEON_LSP`, then the bundled server, then
`$HAXEON_ROOT/scripts/haxeon-lsp` (`HAXEON_ROOT` defaults to `../haxeon`).
Environment overrides name one executable and are never shell-split. The compiler
root fallback resolves against the editor launch directory before the server
starts in the project directory. `plugins.haxeon.enabled=false` disables
server startup. `plugins.haxeon.verbose=true` logs protocol messages to the
launch console, limited to 2,048 characters per message.
