# Workspace service

The workspace service is one process per running workspace. It holds the workspace's groups, agent sessions and
terminal records in SQLite, serves its files and source control, and listens only on a same-user local pipe. It has no
UIKit or GPU dependency. How it fits with exohost, the editor and devices is in
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

The program is `agent/src/app/AgentMain.hx`. exohost starts it when an editor opens the workspace (`workspace.open` on the
editor's exohost link) or a paired device needs it. By hand:

```sh
python3 scripts/build.py
"$(python scripts/haxeon_paths.py)/hl" agent/build/host/main.hl --workspace ID [--folder F]... [--scratch S]
```

exohost finds the bytecode through `EXOSUIT_AGENT_LAUNCHER`, or beside its own (a checkout's `agent/build/host/main.hl`,
a bundle's `exosuit-agent.hl`).

## State and start

- **State folder.** `workspaces/<id>` under `$XDG_STATE_HOME/exosuit` on Linux or `%LOCALAPPDATA%\Exosuit` on
  Windows, private to the user (`AgentState.hx`). `EXOSUIT_AGENT_STATE_HOME` moves the parent. It holds `agent.lock`,
  `workspace.json` (which workspace and folders), `catalog.sqlite`, `service.log`, `catalog-snapshot.bin` and the
  terminal hosts' folders.
- **One service per workspace.** The service takes `agent.lock` and exits with status 3 when another holds it.
- **Ready.** It listens on its pipe at once and reports to exohost (`service-attach`: workspace, pipe, pid, generation,
  root, build; `src/exohost/ExohostServiceLink.hx`). exohost hands that pipe to editors and devices; nothing about how to
  reach the service is written to disk. Connections that arrive while the catalog, terminals and agents come up wait
  in the pipe.
- **Warm spare.** `main.hl --spare` loads, links to exohost (`service-spare`) and waits. exohost hands it a workspace
  (`adopt`) when an idle one is opened, so the open needs no process start. exohost keeps one spare while an editor is
  linked.
- **Pipe.** A Windows named pipe whose DACL grants only the current user; a private a short `.sock` in `workspace-sockets` beside the state folders
  elsewhere. Clients check the service's identity (generation and root) before they watch its catalog.
- **Devices.** The service never dials a relay. exohost forwards a paired device's stream to the pipe, sending first an
  intro with the device's grants (`ForwardedStream`); the service serves that connection with only those grants.
  Folder changes and source-control trust stay local only.

## Stop

- exohost asks over the link (`stop`, now or after the running agent turn). A service of another build is restarted that
  way when its workspace is next opened.
- It stops by itself after `EXOSUIT_SERVICE_IDLE_SECONDS` (600 by default) with no client and no busy agent turn.
  Running terminals do not keep it: they live in terminal hosts, which outlive it. Idle chat processes lengthen the
  wait to ten times the limit, at most ten minutes (`WorkspaceLifetime`).
- On stop it writes `catalog-snapshot.bin`, ends its provider processes and closes its database. Closing a window
  only closes that window's connection.
- The loop waits on events; it turns every 10 ms only for half a second after something happened, and every 50 ms
  while provider processes run.

## Terminals

Each terminal runs in its own terminal host process ([terminal-host-status.md](../docs/design/terminal-host-status.md)),
which keeps the program and its screen while the service stops, crashes or idles out; the next service takes it back.
The service relays at most 2 MiB of recent output per terminal (`WorkspaceTerminalManager.REPLAY_BYTES`); a view
further behind takes the screen from the host. Input batches are at most 64 KiB; sizes are up to 512 columns by 256
rows; a catalog holds at most 256 terminal records. Only the host answers the program's terminal queries, using the
colours the controlling view sends.

## Agent sessions

Settings → Workbench → Agents: "Agent session mode" (`workbench/agents/session_mode`) chooses how new Codex, Claude
and Pi sessions open: `terminal` (the default) runs the provider's own CLI in a terminal; `integrated` runs it under the
service and draws it in the chat panel. "Default agent provider" (Claude) is what New Agent Session starts at once.
The executables come from PATH, or `EXOSUIT_CODEX_BIN`, `EXOSUIT_CLAUDE_BIN` and `EXOSUIT_PI_BIN`.

`workspace.provider.WorkspaceAgentService` binds the agent RPCs, shares authorization and limits across providers,
and builds a provider only when it is first needed. How a session continues after a restart is in
[agent-sessions.md](../docs/design/agent-sessions.md). Provider references: [CODEX.md](CODEX.md),
[CLAUDE-PROVIDER.md](CLAUDE-PROVIDER.md), [PI-PROVIDER.md](PI-PROVIDER.md).

## Tests

- `python3 scripts/test-workspace-terminals.py`: permissions, open retry, input order, bounded replay, reattachment.
- `python3 scripts/test-terminal-hosts.py`: a terminal survives its service; exohost lists, keeps and ends hosts.
- `python3 scripts/test-workspace-agents.py`, `test-claude-agents.py`, `test-pi-agents.py`: sessions through the
  service with fake CLIs.
- `python3 scripts/test-agent-idle.py`: the idle stop.
- `python3 scripts/test-machine-remote.py`: a device reaching a workspace through exohost and a local relay.
- `python3 scripts/test-workspace-attachment.py`, `bash scripts/test-workspace-persistence.sh`, `test-workspace-transport.sh`:
  identity and reuse, storage, real transports.
