# Local plugin development

Create a directory under `plugins/` containing `plugin.conf` and one or more Haxe
sources. The bundled example is runnable as-is:

```sh
python scripts/run.py
```

`run.py` discovers `plugins/*/plugin.conf`. An external manifest can be loaded
directly with `--plugin=/absolute/path/plugin.conf`, or discovered by adding its
parent directory to the colon-separated `PRAGTICAL_PLUGIN_DIRS` environment
variable.

A version-1 manifest declares `manifestVersion=1`, `apiVersion=2`, a stable plugin
ID and semantic plugin version, an entry module and its sources. Commands and
syntax contributions are data in the manifest; host capabilities are accessed by
importing `pragtical.Editor`. See `plugins/example/` for the complete lifecycle and
`docs/plugin-api.md` for ownership and state-transfer rules.

While the editor is running, source edits are observed and debounced. Compilation
and source reads run off the event loop; publication, activation and rollback run
at an editor update safe point. Use the command palette entries `plugins:disable`,
`plugins:enable`, `plugins:reload` and `plugins:show-diagnostics` for explicit
control. Compile or activation failures retain the last working plugin.

The dynamically supplied SDK currently guarantees `pragtical.Editor` and the
language/runtime primitives used by the example. Release inputs and the bundled
Haxeon language service are revision-pinned; dynamic plugin compilation remains
limited to this deliberately exposed SDK rather than an arbitrary host checkout.

Host API failures are raised inside plugin code, with UTF-8 messages intact, so
plugins can catch them. Failed activation still rolls back owned contributions.
The host dispatch uses a checked response internally; plugin code uses the same
`pragtical.Editor` methods. Retired host tokens cannot access a later session.
