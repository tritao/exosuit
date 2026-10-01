# TerminalSession

This host package joins a `TerminalBackend` to a TerminalKit emulator. It has
no dependency on Exosuit's application package. Local sessions use NativeKit
PTYs; a remote backend can implement the same event and replay contract.

An application owns one `TerminalProfileRegistry` and gives it to plugins that
contribute profiles. Registration uses the plugin context's lifetime hook:

```haxe
profiles.add(context.id, "shell", TerminalProfile.shell(workspacePath), context.own);
```

The registry removes the profile when that context is disabled, reloaded, or
unloaded. Resolve the entry and pass its `profile` to `LocalPtyBackend.spawn`
when opening a local session. The graphical terminal view is a later layer.
