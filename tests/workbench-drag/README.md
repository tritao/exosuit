Run with `haxeon/scripts/haxeon run --project tests/workbench-drag/haxeon.json`.

Checks moving Workbench groups, terminals and agent sessions into groups, including hierarchy cycles, unchanged destinations and workspace ownership. Real TreeView pointer sequences cover click preservation, selection, declarative rebuilds, cancellation, release validation, hover expansion and edge scrolling.

With suit on (machine, workspace, then groups), the real Workbench panel drags a terminal and an agent session out of a sub-group onto a top-level group and checks that each sends the same service call as Move to Group… (terminal rename with the new group, agent `move`). Drops onto the item's own group, onto other workspace rows and the machine row, and while the terminal catalog is busy send nothing; pressing another row ends an open rename unsaved before the drag starts.

The open workspace's row is the workspace root (`WorkspaceProtocol.ROOT_GROUP`, no group): dropping a terminal or session on it moves it there, dropping one already there is refused, and the terminal service loads, keeps and moves root terminals.

The provider checks use the real authorized RPC routes for Codex, Claude and Pi with an in-memory persistence fixture. They verify saved grouping, restart recovery, stale-source conflicts, missing destinations, read-only denial and storage failures without launching agent CLIs. Moves preserve the native session identity and working directory.

Legacy services must advertise agent move support before the client sends a move. The Workbench fixture verifies an unsupported drop produces one dismissible notification, leaves tree rows in place, and succeeds after support is advertised.

Agent Rename is exercised through the context menu and F2, with Enter, Escape, blur cancellation, blank-name validation and focus restoration. Provider tests cover normalized names, conflicts, read-only authorization, restart persistence and storage failure. Open-view title synchronization is checked across panes and workspace identities; an in-flight stale catalog must not undo an accepted rename.

Native naming distinguishes provider titles from explicit Workbench labels. The coordinator tests cover migration without native writes, durable intents, lost responses, storage failures and restart reconciliation. UI tests cover native capability negotiation, inspecting the title before editing, distinct menu labels, stale-service rejection and cross-pane title updates. `scripts/test-native-session-names.py` exercises the actual daemon adapters without model execution, and `scripts/test-claude-session-names.py` checks the pinned SDK in a relocated runtime layout. The optional `scripts/test-codex-session-names.py` checks an installed Codex app server with a disposable thread and no inference.
