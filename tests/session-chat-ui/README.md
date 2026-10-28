# Session chat UI regression fixture

Run `haxeon run --project tests/session-chat-ui/haxeon.json` from the repository root. On Windows, use the guard in `CLAUDE.md` for both the build and the executable. For a direct HashLink run, set `PATH` to include `haxeon/out`, `haxeon/.tools/hashlink`, and the project's native DLL directories, and set the working directory to `tests/session-chat-ui` so the fixture font resolves.

The fixture uses a fake workspace agent and the real UI layout and event dispatcher. It exercises session actions, navigation, links, narrow and wide layouts, dark and light themes, Claude and Pi input behavior, transcript scrolling, and disabled states. It also runs the button-theme, sidebar, status, Markdown, and session-projection suites. It checks that the message copy action is available without writing to the system clipboard; it does not exercise live providers or inspect rendered pixels.
