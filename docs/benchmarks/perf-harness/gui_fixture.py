"""Prepares one GUI scenario run: isolated state roots, fixture folders and (through an isolated exohost) the workspaces the
scenario starts with. Writes ENV.json (environment for the editor) and prints nothing else on success.

    python -I gui_fixture.py --root CHECKOUT --out RUNDIR --scenario NAME

A scenario module may define FIXTURE = {"workspaces": ["alpha", "beta"], "open": "alpha"} (and "env": {NAME: value} and "settings": {preference: value} for the editor): each name is a folder under
RUNDIR/fixture holding a1.txt, a2.txt, ... and becomes an exohost workspace called Alpha, Beta, ...; `open` is the folder
the editor starts in. A module may also define prepare(out, root, env, exohost), called once the workspaces exist, to fill
them (ws_open seeds catalogs and tabs): `env` is the environment exohost runs with, `exohost(*args)` runs exohost's CLI. Nothing
here touches the user's exohost, agent state, scratch folders or sessions: every root is under RUNDIR, and exohost runs with a
home of its own."""
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def arg(name):
    return sys.argv[sys.argv.index(name) + 1]


def main():
    root, out, scenario = Path(arg("--root")), Path(arg("--out")), arg("--scenario")
    sys.path.insert(0, str(root / "scripts"))
    from exohost import library_path, library_variable
    from test_driver import agent_homes
    spec = importlib.util.spec_from_file_location("scenario", HERE / "gui_scenarios" / (scenario + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.argv_backup, sys.argv = sys.argv, [scenario]
    spec.loader.exec_module(module)
    sys.argv = sys.argv_backup
    fixture = getattr(module, "FIXTURE", {"workspaces": ["alpha"], "open": "alpha"})
    haxeon = Path(os.environ.get("HAXEON_ROOT", root / "haxeon"))
    hl = haxeon / ".tools" / "hashlink" / "hl.exe"
    exohost = root / "exohost" / "build" / "host" / "main.hl"
    env = {
        "PRAGTICAL_PORTABLE": str(out / "state"),
        "EXOSUIT_EXOHOST_HOME": str(out / "exohost-home"), "EXOSUIT_EXOHOST_SCAN": "0",
        "EXOSUIT_EXOHOST_TRAY": "0", "EXOSUIT_EXOHOST_IDLE_SECONDS": "150", "EXOSUIT_EXOHOST_LAUNCHER": str(exohost),
        "EXOSUIT_AGENT_STATE_HOME": str(out / "agent-state"), "EXOSUIT_SCRATCH_HOME": str(out / "scratch"),
        # Services read Claude Code's and Codex's transcripts: the run's own folders, never ~/.claude or ~/.codex.
        **agent_homes(out / "homes"),
    }
    # A scenario may add variables: {out} is the run folder, {result} its result folder, {root} the checkout, {python} this interpreter.
    for key, value in fixture.get("env", {}).items():
        env[key] = (value.replace("{result}", str(out / "result")).replace("{out}", str(out))
                    .replace("{root}", str(root)).replace("{python}", sys.executable))
    for key in ("state", "agent-state", "scratch", "result"):
        (out / key).mkdir(parents=True, exist_ok=True)
    if fixture.get("settings"):  # preference values the editor starts with, e.g. {"workbench/agents/session_mode": "integrated"}
        (out / "state" / "settings.json").write_text(json.dumps({"values": fixture["settings"]}))
    folders = {}
    for name in fixture["workspaces"]:
        folder = out / "fixture" / name
        folder.mkdir(parents=True, exist_ok=True)
        for index in range(1, 4):
            (folder / f"{name[0]}{index}.txt").write_text(f"{name} file {index}\n" * 3)
        folders[name] = folder
    for name in fixture.get("folders", []):  # plain folders, no workspace: for attaching
        folder = out / "fixture" / name
        folder.mkdir(parents=True, exist_ok=True)
        for index in range(1, 4):
            (folder / f"{name[0]}{index}.txt").write_text(f"{name} file {index}\n" * 3)
    child_env = dict(os.environ, **env)
    child_env[library_variable()] = library_path(exohost, hl, haxeon, os.environ.get(library_variable(), ""))

    def exohost_cli(*arguments):
        return subprocess.run([str(hl), str(exohost), *arguments], env=child_env, capture_output=True, text=True, timeout=60)
    started = exohost_cli("start")
    if started.returncode != 0:
        sys.exit(f"exohost start failed ({started.returncode}): {started.stderr}{started.stdout}")
    for name in fixture["workspaces"]:
        result = exohost_cli("workspace", "new", "--name", name.capitalize(), str(folders[name]))
        if result.returncode != 0:
            sys.exit(f"exohost workspace new failed ({result.returncode}): {result.stderr}{result.stdout}")
    if hasattr(module, "prepare"):
        module.prepare(out, root, child_env, exohost_cli)
    # The isolated exohost may have started a daemon for the registry; it exits when idle (EXOSUIT_EXOHOST_IDLE_SECONDS).
    start = folders[fixture["open"]] if fixture.get("open") else None
    (out / "ENV.json").write_text(json.dumps({"env": env, "open": str(start) if start else None,
                                              "fixture": str(out / "fixture"), "appArgs": fixture.get("appArgs", [])}))


main()
