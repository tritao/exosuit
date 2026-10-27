# Agent session ownership and creation

Session creation has three owners:

- `WorkspaceAgentService` binds the workspace RPC methods. Its provider registry
  owns authorization, cross-provider identity checks, the shared 32-resource
  limit, paged catalogs, group occupancy, polling and shutdown. It routes by the
  provider field on creation and by resource ownership afterward. Missing provider
  fields retain the legacy Codex meaning. Codex, Claude and Pi are protocol
  adapters implementing the same `LocalAgentProvider` interface; none routes to
  another vendor adapter.
- `WorkspaceAgentCreation` owns one client operation: reserved resource ID,
  workspace root/generation, connection, startup retry deadline, request state,
  progress phase and completion callback. Its lifetime is separate from actions
  on existing sessions. Another session can keep working while creation runs.
- `ExosuitApp.createProviderAgent` is the shared UI entry for toolbar, provider
  picker and replacement creation. It reads `workbench/agents/session_mode` and
  dispatches either an interactive terminal or an integrated conversation. The
  Codex toolbar uses this same entry, rather than a separate structured-only path.

Integrated creation hands the complete validated `AgentRecord` to the UI. Opening
that record does not wait for or look it up in the mutable catalog. Catalog reads
issued before creation are fenced, and a fresh catalog refresh projects the
resource into Workbench. A pending tree selection waits for the matching resource
and workspace; both terminal and conversation tabs use the same synchronization
on creation and editor restoration.

Only an explicit, unambiguous `provider_starting` response retries creation, with
the same resource ID. Uncertain failures are surfaced without automatic retries.
A connection or workspace generation change cancels the operation; a late result
cannot open a tab in another scope. Repeated clicks cannot replace an in-flight
operation. Creation errors and session-action errors have separate lifetimes,
and background reads do not clear either. Workbench shows creation progress.

The returned identity, group, provider and workspace root are validated before
handing the record to the UI. Non-Codex creation additionally requires the daemon's
advertised provider support, preventing old daemons from silently treating the
request as Codex. Session discovery and pre-session model queries accept an
optional provider; legacy queries retain their Codex default. Adapters that do
not support those operations return an explicit unsupported-operation error.

## Verification

```sh
python3 scripts/test-workspace-agents.py
python3 scripts/test-claude-agents.py
python3 scripts/test-pi-agents.py
python3 scripts/test-pi-agents.py --inputs
xvfb-run -a -s '-screen 0 1280x1000x24' python3 scripts/test-agent-session-creation-ui.py
```

The native tests cover direct record handoff before catalog arrival, late catalog
fencing, simultaneous creation and unrelated session actions, stable startup
reservations, uncertain failures, generation changes, shared provider limits,
cross-provider identity conflicts and authorization. Vendor protocol suites run
through the neutral service, including a Claude-only service without Codex.

The desktop matrix uses test-only CLI peers and real X11 input. It creates Codex
and Claude through the provider picker in both terminal and integrated modes,
checks visible editor tabs, tree selection and editor reattachment, and checks
that the Codex toolbar follows the selected mode. Terminal cases also assert CLI
output is rendered and editor reattachment does not relaunch the process. Use
`--provider codex|claude`, `--mode terminal|integrated` or `--skip-build` to narrow a
run. `--legacy-agent /path/to/older/main.hl` checks the persistent update error
without a create side effect. The full matrix is included in `scripts/ci.sh`.

The matrix does not use paid inference. Real vendor compatibility and interactive
approval/question behavior remain covered by their separate opt-in acceptance
checks. This refactor does not add full history import, session discovery for
Claude/Pi, or automatic recovery of uncertain prompt delivery.
