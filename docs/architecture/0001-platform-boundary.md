# ADR 0001: Own the platform API and adapt Pragtical's native backend

Status: superseded

Superseded by: [0002-nativekit-uikit-host.md](0002-nativekit-uikit-host.md)

**Supersession note:** This decision established the layered architecture
(custom platform ABI, opaque handles, pull-based events) that the headless
core still uses. However, the graphical layer now relies on NativeKit's
`DesktopUiHost` instead of a custom SDL loop, and UIKit instead of a
Pragtical-adapted renderer. The core principles (opaque resources, clean
boundary) remain; the implementation moved to an off-the-shelf host.

## Decision

Pragtical Haxeon defines a small platform-neutral Haxe API and a versioned flat
C ABI. Its initial graphical backend will adapt Pragtical's SDL3 platform and
renderer implementation. SDL structures, constants, and pointers do not cross
the ABI. Lime is a design reference and a possible future backend, not a core
dependency.

The native host owns the outer application loop and durable resources. Haxeon
owns editor state and behavior. Native resources cross the boundary as opaque,
generation-checked integer handles. Events cross through a pull queue as
normalized value records. Rendering reuses Pragtical's renderer sources
directly, including its font shaping, glyph atlases, dirty-region cache, drawing
primitives, and portable SDL surface backend. The Haxeon bridge selects that
backend with a tiny adapter and exposes only opaque font handles and
value-oriented draw operations.

The renderer source remains owned by the sibling Pragtical checkout rather than
being forked here. Builds use `PRAGTICAL_ROOT` (defaulting to `../pragtical`), so
renderer changes can be validated against both applications without maintaining
a copied implementation.

## Why

Depending on Lime would first require Haxeon to support Lime's macros, build
tooling, broad standard library usage, CFFI conventions, and unrelated asset,
audio, and rendering facilities. Raw SDL externs would instead leak pointer
lifetimes, structure layouts, backend choices, and platform-specific main-loop
rules into reloadable editor code.

This boundary permits a deterministic headless backend, protects native objects
from stale references after domain reloads, and preserves Pragtical's mature
rendering behavior without exposing its C types to editor code.

## Ownership

- The native host owns windows, renderers, fonts, processes, and OS objects.
- Haxeon code borrows opaque handles and never receives native pointers.
- Destroying a resource invalidates its handle generation.
- Body patches retain host resources.
- Domain reload retires callbacks before state restoration.
- Events are copied into a host queue and pulled at a Haxeon safe point.

## Main-loop contract

The graphical host will translate `SDL_AppInit`, `SDL_AppEvent`,
`SDL_AppIterate`, and `SDL_AppQuit` into stable Haxeon entry calls. Patch
publication occurs between event delivery and the next update, never while a
domain call is active.
