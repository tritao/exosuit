Run with `haxeon/scripts/haxeon run --project tests/workbench-drag/haxeon.json`.

Checks moving Workbench groups, terminals and agent sessions into groups, including hierarchy cycles, unchanged destinations and workspace ownership. Real TreeView pointer sequences cover click preservation, selection, declarative rebuilds, cancellation, release validation, hover expansion and edge scrolling.

The provider checks use the real authorized RPC routes for Codex, Claude and Pi with an in-memory persistence fixture. They verify saved grouping, restart recovery, stale-source conflicts, missing destinations, read-only denial and storage failures without launching agent CLIs. Moves preserve the native session identity and working directory.

Legacy services must advertise agent move support before the client sends a move. The Workbench fixture verifies an unsupported drop produces one dismissible notification, leaves tree rows in place, and succeeds after support is advertised.

Agent Rename is exercised through the context menu and F2, with Enter, Escape, blur cancellation, blank-name validation and focus restoration. Provider tests cover normalized names, conflicts, read-only authorization, restart persistence and storage failure. Open-view title synchronization is checked across panes and workspace identities; an in-flight stale catalog must not undo an accepted rename.
