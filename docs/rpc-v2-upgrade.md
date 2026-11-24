# Haxeon RPC v2: rebuild everything together

From the haxeon pin that merges exosuit-m19 into haxeon's main, Exosuit speaks haxeon RPC protocol v2. Methods are
named on the wire, and calls return a Future (`workspace.transport.RpcCalls` keeps Exosuit's callback style over it).
`RpcHandshake` answers a v1 peer with `unsupported_protocol`, so a v2 process and a v1 process cannot talk.

Rebuild and restart these together; none of them talks to an older build of another:

- the editor (graphical)
- exohost
- the workspace and agent services (`agent/`)
- the Android app
- the browser site (web guest)
- the Windows build

Unaffected: terminal hosts (their link to the service is a `MessageTransport`, not RPC), and the relay, which forwards
the bytes of a device's connection without reading its RPC.

## Upgrading a machine

1. Quit exohost (tray menu Quit, or stop its process): its workspace and agent services stop with it.
2. Sweep orphan services: any `agent/build/host/main.hl` process still running from the old build (a service whose
   exohost died stays up). Stop them, or a new window may reach one and fail its handshake.
3. Build (`python3 scripts/build.py`, `android/scripts/build.sh`, the web build) and start the new editor, which starts
   the new exohost.
4. Rebuild and reinstall the Android app and reload the browser site before pairing or connecting them again.
