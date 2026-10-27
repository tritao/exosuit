# Vendored terminal sources

- `vendor/libtsm` is a Git submodule of
  [tritao/libtsm](https://github.com/tritao/libtsm), pinned to
  `a676fa19a9498cb789cb20cf3c4eee6c89ad05a9` on branch
  `terminalkit-scrollback-draw`. The commit adds the scrollback viewport API
  used by the Pragtical backend. libtsm is MIT; its included `shl-htable` is
  LGPLv2+ and bundled wcwidth has its own license. See `vendor/libtsm/COPYING`,
  `LICENSE_htable`, and `external/wcwidth/LICENSE.txt`.
- `vendor/pragtical`: Pragtical terminal libtsm backend and header, MIT,
  copied from the local `subprojects/terminal/native/emulator` reference.
  See `vendor/pragtical/LICENSE`. The additions at the end of the header and
  backend expose active-screen row IDs and borrowed cells for the snapshot API,
  and a history line iterator that suppresses transient cursor inversion while
  preserving the caller's viewport and cursor visibility.

The package excludes the host UI and PTY runtime. The submodule commit builds
on the fork's `next` branch; its `main` branch lacks the terminal mode APIs
needed by this backend. The pinned libtsm stores at most ten Unicode code
points per cell (`TSM_UCS4_MAXLEN`), so longer combining sequences are
truncated by the backend itself.

The local libtsm host-colour extension sets default foreground/background RGB
values without the screen erase and SGR reset performed by its palette setters.
It updates OSC 10/11 replies and retains application palette overrides. Host
defaults survive VT resets and are configured by the terminal owner rather than
included in output history.
