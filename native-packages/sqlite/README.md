# SQLiteKit

SQLiteKit is a reusable Haxeon package around a vendored SQLite amalgamation.
Its C ABI uses opaque database and statement handles. Open acquires a
nonblocking exclusive lock on `<database>.sqlitekit-lock`; close releases it.
The sidecar remains on disk so a process cannot replace the lock inode while
another process holds it. Callers should use one stable path spelling for a
database. A 5-second busy timeout is the Haxe wrapper default; the C caller
chooses its own timeout.

The native API supports prepare, typed bind, step, typed column reads, immediate
transactions, change counts and last-insert IDs. `sqlitekit_column_blob`
borrows SQLite's column memory until the next step, reset or finalize, avoiding
an extra native copy. The Haxe `Statement.columnBlob()` wrapper makes a safe
copy into `haxe.io.Bytes`, since the Haxe caller cannot retain SQLite's borrowed
memory across those operations.

Build and run the package contract with `tests/run.sh`. It runs the four-target
HXI audit, a native C test, and a Haxeon smoke covering rollback and blob
round trips. The native build and Haxe test artifacts stay under
`tests/build/`.
