# Recovery and troubleshooting

Session state, unsaved recovery snapshots, replacement backups and the editor
trash live under the platform state directory documented in
[configuration](configuration.md). Set `PRAGTICAL_PORTABLE=/chosen/directory` to
put configuration and state together for diagnosis or a removable installation.

On startup, dirty documents belonging to the restored workspace return directly
to their previous tabs. `recovery:open` lists only retained unsaved snapshots
that are not already open, and startup opens that view only when such orphaned
snapshots exist. Accepting a snapshot retires the stored copy before a
still-dirty document creates new recovery state. Workspace replacement backups
remain available after partial failure, and file deletions go to the
editor-managed trash rather than being irreversibly removed.

Configuration and plugin failures preserve the last valid state and appear in
notifications and `errors:inspect`. A failed dynamic plugin reload keeps the last
working plugin active; use `plugins:show-diagnostics`, then explicitly reload or
disable it. A failed language server is restartable from its language commands;
release archives select their bundled server, while developers can explicitly set
`HAXEON_LSP` to another launcher.

Known limitations are tracked in [release qualification](release-qualification.md).
