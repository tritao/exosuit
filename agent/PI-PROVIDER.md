# Pi provider

Install and sign in to Pi on the workspace host, then choose **New Pi session**
from a Workbench group's context menu. Exosuit launches `pi --mode rpc` directly
from Haxe; `EXOSUIT_PI_BIN` overrides the executable. Pi keeps its normal model
configuration, credentials, context files, skills and extensions. Sign-in remains
in Pi's CLI. The test-only `EXOSUIT_PI_SCRIPT` launch prefix supports fake peers.

The first integration supports model and thinking selection, streamed text,
reasoning and tool output, extension confirmation/selection/text dialogs, Stop,
editor detachment and explicit resume. Selection dialogs take the exact option
text from the prompt field. Input/editor dialogs take the prompt verbatim.
Truncated dialogs can be declined but cannot be approved or answered.

The daemon owns one process per Pi resource. SQLite stores the native session
file path, permission/model/thinking choices and a bounded activity snapshot.
Detaching an editor leaves the process running. Daemon restart does not relaunch
Pi or resend prompts; choose Resume explicitly. Missing native conversation files
fail recovery rather than silently replacing a conversation. An empty native
session that never received a message may not have a file yet.

Permission enforcement comes from an injected Pi extension stored in the
workspace service's private state directory. Pi must confirm the hook loaded
before Exosuit accepts a prompt. Supervised asks before commands, edits and
extension tools; Auto-accept edits also allows native edit/write tools; Full
access permits tools without Exosuit approval. Native read-only tools continue
without prompting. Unknown/replaced tools require approval. These checks cover
Pi tool calls, not arbitrary code run by trusted extensions or an OS sandbox.
Changing permission mode restarts Pi with an immutable policy and resumes its
native conversation. Stop terminates the owned Pi process, clears live dialogs,
and requires explicit resume before another message.

While Pi is working, **Queue message** stores a follow-up for after the current
turn settles. Enter queues when no question or approval is waiting; use the
explicit button while responding to a request. Follow-ups run one at a time in
submission order, using the model and permissions active when they start. Pending
cards offer **Remove queued message**, **Pause queued messages**, and **Use as
draft**. Pausing leaves the active turn running.

**Steer now** sends instructions to Pi's current run at its next input boundary.
Skills and prompt templates keep Pi's native expansion. Extension commands can
be queued for a later turn or sent while idle. The native pending list shows
what Pi is waiting to consume; **Clear Pi pending messages** clears that native
list, including messages queued by Pi extensions. Daemon-owned follow-ups keep
their individual Remove controls.

Stop, transport failure, and daemon restart pause follow-ups. Resume Pi first,
then choose **Resume queued messages** to release unsent follow-ups. Messages
with uncertain delivery stay visible and are never resent automatically. Inspect
the native conversation before explicitly sending a new copy; **Use as draft**
only copies text, and **Dismiss input** removes the local notice. Rejected
submissions preserve the composer draft.

Pending user input is bounded to eight messages and 4096 total UTF-8 bytes. The
durable outbox keeps sixteen delivery receipts; a monotonic token serial rejects
expired receipts instead of admitting them as new work. State is saved before
native delivery. Only queued, unsent follow-ups can be removed individually;
steering already handed to Pi uses its native clear-all operation.

Protocol frames are bounded to 256 KiB, queues to 1 MiB, pending RPC requests to
32, and dialogs to 16. Control requests time out after 60 seconds. Prompt requests
can remain pending while extension dialogs are open. Malformed frames, process
failure or ambiguous delivery disconnect Pi without retrying the prompt. Activity
retains 128 items, paged eight at a time, with six shortened items saved across
restart. This snapshot does not import Pi's full native history.

Type `/` at the start of the composer to discover native extension commands and
prompt templates, or `$` to discover skills. Type more to filter. Up/Down selects
a suggestion; Tab or Enter inserts it; Escape dismisses suggestions. Selecting a
skill inserts `/skill:<name> ` so Pi performs its normal expansion. Review or add
arguments, then send the message. Clicking a suggestion also inserts without
sending. Shift+Enter still inserts a newline.

The catalog comes from Pi's `get_commands`, including user/project scope when
reported. It respects what Pi loads for the current workspace and its extension
trust settings. **Refresh commands** queries the running session again. Newly
installed resources may require a fresh session. Discovery failures leave the
conversation usable and show an error beside the composer. TUI-only commands
that Pi does not advertise are not suggested.

Usage meters, app-tool/MCP bridging, subagent
presentation, native forks and rollback are follow-up work. Terminal decorations
from Pi extensions have no UI mapping yet.

Run deterministic adapter/failure tests:

```sh
python3 scripts/test-pi-agents.py
python3 scripts/test-pi-agents.py --inputs
```

Run the actual installed Pi against a temporary loopback mock model endpoint:

```sh
EXOSUIT_PI_BIN=/path/to/pi python3 scripts/test-pi-agents.py --real
EXOSUIT_PI_BIN=/path/to/pi python3 scripts/test-pi-agents.py --real --inputs
```

The real fixture uses an isolated Pi directory and no account or paid API. It
checks startup, discovery, streaming, native Write approval/decline, automatic
edits, Stop, policy restart and native session resume. Pi 1.4.0 is the version
used during implementation; other versions need the same RPC envelopes and
extension tool hooks. Desktop acceptance is run separately from these protocol tests.

Desktop acceptance uses the actual app and real Pi with an isolated profile and
local mock model. It exercises pointer/keyboard controls, approvals, stop/resume,
editor reattachment, skill/command selection and daemon restart:

```sh
EXOSUIT_PI_BIN=/path/to/pi xvfb-run -a -s "-screen 0 1280x1024x24 -noreset" \
  python3 scripts/test-pi-desktop.py
```

Set `PI_UI_ARTIFACTS` to retain screenshots and layout/state captures.

Pass `--inputs` to the desktop test to exercise Queue/Steer, rejected drafts,
removal, pause and explicit recovery.
