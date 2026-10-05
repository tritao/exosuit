# Editor native bindings

The editor-specific C contract is `native-packages/plugin-host/include/exosuit_plugin_host.h`.
`scripts/update-plugin-host-bindings.sh` generates and checks its portable HXI binding
across Linux, Windows, and both macOS architectures. The projection exposes
`plugin.host.ffi.PluginHostApi` and `PluginHostTypes`.

`plugin.host.PluginHost` owns the retained dispatch callback. Replacement installs
the new pointer before closing the old handle; shutdown unregisters before closure.
Callback failures reach application code as exceptions without unwinding through C.
Plugin managers share ownership and release the bridge after unloading their plugins.
The source SDK retains `pragtical.Editor` and API version 2 for compatibility,
while its host calls target the independent `exosuit_plugin_host` library.

Processes use Haxeon's `sys.io.Process.spawn` and `sys.io.ChildProcess`, with
nonblocking byte pipes, partial writes, exit polling, cancellation, and cleanup.
The editor adapter retains incomplete UTF-8 scalars across output reads, and
JSON-RPC queues bytes so partial writes cannot duplicate or split a frame incorrectly.
Existing blocking Haxeon process APIs remain compatible. Streaming subprocesses
currently have a POSIX backend; Windows spawn reports that it is unsupported.

UIKit and NativeKit own real windows, fonts, drawing, events, and clipboard access.
Command input receives asynchronous clipboard callbacks from the UI host and
rejects completions after prompt closure, replacement, or intervening edits.
`platform.Platform` is only an application key vocabulary translated by the UI bridge.

The old platform C implementation, renderer, native bindings, and build dependency
are removed. Test-only models live under `tests/support/haxe/testing/model` and
use deterministic text metrics rather than simulated native windows or fonts.
Application test entries live in their own projects. Rendering coverage uses
hosted UIKit smoke tests rather than the model test host.

The retention annotation precedes nullable callback parameters so Clang preserves
the original callback type and emits `nullable<CB> @retained` in the interface.
