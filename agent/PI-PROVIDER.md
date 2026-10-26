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

Protocol frames are bounded to 256 KiB, queues to 1 MiB, pending RPC requests to
32, and dialogs to 16. Control requests time out after 60 seconds. Prompt requests
can remain pending while extension dialogs are open. Malformed frames, process
failure or ambiguous delivery disconnect Pi without retrying the prompt. Activity
retains 128 items, paged eight at a time, with six shortened items saved across
restart. This snapshot does not import Pi's full native history.

Skills can still be invoked using Pi's native prompt syntax, but skill discovery,
active steering, queued messages, usage meters, app-tool/MCP bridging, subagent
presentation, native forks and rollback are follow-up work. Terminal decorations
from Pi extensions have no UI mapping yet.

Run deterministic adapter/failure tests:

```sh
python3 scripts/test-pi-agents.py
```

Run the actual installed Pi against a temporary loopback mock model endpoint:

```sh
EXOSUIT_PI_BIN=/path/to/pi python3 scripts/test-pi-agents.py --real
```

The real fixture uses an isolated Pi directory and no account or paid API. It
checks startup, discovery, streaming, native Write approval/decline, automatic
edits, Stop, policy restart and native session resume. Pi 1.4.0 is the version
used during implementation; other versions need the same RPC envelopes and
extension tool hooks. Desktop compilation is checked separately from interactive
UI acceptance.
