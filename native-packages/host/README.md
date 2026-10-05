# Host services

This package owns the existing native platform/process ABI bindings and build.
Both the graphical app and workspace daemon consume it. Keeping FFI ownership in
one package avoids registering the same interface twice in projects that depend
on both executables.

The native library and exported ABI names remain compatible. This extraction
does not create an editor/UI dependency for the daemon. Process pipes are
nonblocking and bounded; adapters split writes to respect the atomic pipe limit.
