# Getting started

## Release archive

Unpack the Linux archive and run the executable from any directory:

```sh
tar -xzf pragtical-haxeon-*-linux-x86_64.tar.gz
./pragtical-haxeon-*-linux-x86_64/pragtical-haxeon [file-or-directory ...]
```

The archive is self-contained for Pragtical Haxeon code, HashLink runtime
modules, the Haxeon language server, fonts, defaults and notices. The host still
uses compatible system SDL 3, FreeType and HarfBuzz libraries. Linux x86-64 is
the only currently claimed build; Windows and macOS have not been qualified.

Pass a file to open it or a directory to add it as a workspace project. Use
Ctrl+Shift+P for the command palette. Project tasks are deliberately selected
with `build:run-task`; no project command is executed merely by opening a folder.

## Source checkout

The release inputs are recorded in `release.lock`. Place matching Haxeon and
Pragtical checkouts beside this repository, or set `HAXEON_ROOT` and
`PRAGTICAL_ROOT`. Then run:

```sh
SKIP_FORMAT_CHECK=1 ./scripts/test.sh
./scripts/run.sh
```

`run.sh` reuses the existing SDL build while its source and toolchain inputs are
unchanged. Set `PRAGTICAL_FORCE_REBUILD=1` to force a clean rebuild before
launching.

`SKIP_FORMAT_CHECK=1` is only needed while the inherited formatting baseline is
being normalized; compiler, native and behavioral gates still run. Create the
pinned local artifact and prove relocation with:

```sh
./scripts/test-release.sh
```

The complete local gate is `./scripts/ci.sh`. It runs Haxeon compatibility,
headless editor tests, graphical SDL tests and the unpacked release test.

## Configuration and plugins

See [configuration](configuration.md) for user/project layers and portable mode,
[build tasks](build-tasks.md) for deliberate project processes, and
[plugin development](plugin-development.md) for manifest plugins. Relative font
paths in settings resolve beside the settings file; built-in font paths resolve
beside the installed executable.
