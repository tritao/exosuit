# NativeKit desktop services

The graphical application has an opt-in NativeKit adapter for native desktop
services. Window and rendering ownership remain unchanged. The adapter currently
provides lifecycle management, event polling, asynchronous file and directory
dialogs, asynchronous clipboard reads, clipboard writes, and shell operations.

The build expects a sibling NativeKit checkout at `../nativekit`. Set
`NATIVEKIT_ROOT` when it lives elsewhere. Enable the adapter at runtime with:

```sh
PRAGTICAL_NATIVEKIT=1 ./scripts/run.sh
```

The NativeKit shared library must be discoverable by the process. For a local
build this normally means adding its CMake build directory to
`LD_LIBRARY_PATH`. Builds and normal application runs do not load NativeKit when
the feature is disabled.

Application code should use `NativeDesktopServices`, not the generated raw
binding. Completion callbacks run when `poll()` drains the NativeKit event queue
from the graphical update loop.
