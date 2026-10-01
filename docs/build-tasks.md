# Build tasks

Project tasks live in `.pragtical/tasks.conf`. The editor never reads or runs this
file automatically: invoke `build:run-task` from the command palette, then choose
a task. Use `build:cancel-task` to stop the active task.

Each `task=` begins a task. Arguments are separate repeated fields, so paths and
values containing spaces never pass through a shell:

```text
task=test
executable=./scripts/test.sh
cwd=.
argument=--filter
argument=a path with spaces
environment=MODE=debug
```

`cwd` defaults to the project root and relative values resolve from that root.
Environment entries override inherited variables for the child. Output is read
without blocking the editor, retained within 10,000 lines and 1 MiB, and shown in
a Build Output tab. Lines shaped like `path:line:column: message` are clickable and
open the referenced position. Task configuration errors and launch failures are
reported through the editor error log.

This repository provides `build-headless`, `test-headless`, and `build-uikit` tasks
in its own `.pragtical/tasks.conf`, which is also used by the project command palette. The real-window smoke supplies its own disposable
task and checks process output and published diagnostics.
