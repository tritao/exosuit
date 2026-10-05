# Workspace protocol contract

Status: planned. Shared rules for M14/M16, implemented through Haxeon RPC.
Keep one service and typed client API across local sockets and remote transport.
Add methods only as the delivery slices need them; no separate protocol framework.

## Common rules

- Stable opaque workspace/resource ids identify persisted state. A new service
  epoch invalidates connection handles and stale replay cursors.
- Attach/detach affects a client subscription. Stop affects the resource's work.
  Delete removes a workspace resource explicitly. Disconnect never means stop
  or delete; provider history deletion is a separate explicit action.
- Authenticate before privileged dispatch. Check workspace/device permissions
  for requests and event delivery; revocation closes affected subscriptions.
  Viewing, terminal control, agent prompting and approvals are distinct grants.
- Mutations carry operation ids and expected revisions where appropriate.
  Store the operation digest/outcome with the mutation, reject reuse with a
  different payload, and expose outcome lookup. Define retention before relying
  on retries; expired/unknown outcomes are ambiguous, not proof of no execution.
- Subscriptions establish a cursor before snapshot fetching. Buffer bounded
  concurrent events, then reconcile. Resume with epoch/cursor; on gaps or expired
  history, fetch fresh state. Client UI state remains local.
- Use bounded messages/queues and fair work budgets. Bulk traffic cannot starve
  control or approvals. Slow consumers disconnect with a recoverable error.
- Negotiate versions/capabilities; never reuse method/field ids. Stable errors
  distinguish invalid input, denied access, stale revisions, replay gaps,
  unsupported features, overload and uncertain operation outcomes.
- Logs record request/resource ids and outcomes, excluding credentials,
  encryption keys, file contents and terminal/conversation payloads by default.

## Named groups

Persist a named nested group hierarchy with optional working-directory
references and sibling order. New sessions inherit the nearest group directory
unless explicitly overridden, and retain the resolved cwd thereafter. Group
moves/renames never restart sessions; directory associations do not grant access.
Use the same group tree across clients, with client-local expansion/selection.

## Terminals

Many clients may watch. One explicit controller owns input and resize through
an expiring, generation-fenced lease; takeover is visible. Loss of control or
revocation rejects stale input. Output uses byte offsets and checkpoint/replay.
Input acknowledgements mean bytes accepted by the service, not shell completion.
Never replay unacknowledged terminal input automatically after reconnect.
Restart creates a new runtime generation; old offsets/input cannot target it.

## Agents

Expose create/attach/prompt/read/wait/interrupt/recover through typed provider
capabilities. Retain provider-specific items and external session ids. Prompt
submission uses operation reconciliation; a timeout does not prove no turn began.
Approval/input requests have stable ids, current status and scope; the service
accepts one resolution, marks stale/competing replies, and reconciles uncertain
provider delivery rather than claiming distributed exactly-once execution.
Codex interruption targets a turn, never the shared daemon. Claude hook failure
surfaces degraded status; process liveness alone does not mean a task completed.

## Remote boundary and acceptance

Relay routing/authentication is separate from encrypted workspace messages.
Pairing binds device/machine identities; key lifecycle uses an established
protocol/library. No provider credentials or workspace histories live in relay.

Required tests: two clients viewing/control transfer; disconnect with active
terminal/agent; lost mutation response without duplicate execution; stale input
and approval races; epoch/replay-gap recovery; revocation; slow-consumer flood;
unsupported version/capability. File specifics are in WORKSPACE-FILES.md.

Deliver these rules alongside actual M14 methods. The first workspace/RPC slice
proves hello, one query, one recoverable subscription and one reconciled mutation.
Separate generation, generic streaming extensions and advanced transports wait
until a working consumer needs them. Current roadmap next remains M10.2.
