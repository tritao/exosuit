# Pragtical Haxeon

A new editor implementation with its application core written in Haxeon. The
native host owns platform lifecycle and resources; reloadable Haxeon domains own
editor behavior.

The graphical backend compiles Pragtical's renderer sources directly and uses
its font shaping, glyph atlas, dirty-region cache, and SDL surface backend behind
the platform ABI. The editor core never receives SDL or renderer pointers.
The document view supports measured caret placement, vertical navigation,
line-number and selection drawing, resize-aware clipping, scrolling, and mouse
drag selection.
Input is routed through a Pragtical-style named command registry and ordered
keymap with predicate-based fallbacks; text input remains a separate event path.

## Build and test

```sh
./scripts/test.sh
```

By default the build uses sibling checkouts at `../realtime-haxe` and
`../pragtical`. Override them with `HAXEON_ROOT` and `PRAGTICAL_ROOT`.

See [the platform boundary decision](docs/architecture/0001-platform-boundary.md).

## Current capabilities

The editor now covers safe document persistence and recovery, multiple views and
selections, command/file/search palettes, project indexing and replacement,
layered live configuration, reloadable owned plugins, build tasks, and Haxeon
language diagnostics/navigation. The SDL host supports Unicode clipboard and
paths, distinct IME preedit state, display-scale events, shaped font fallbacks,
and a relocatable Linux release archive. Exact qualification evidence and open
platform limitations are recorded in `docs/release-qualification.md`.
