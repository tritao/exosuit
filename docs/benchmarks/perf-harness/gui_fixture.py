"""Prepares one GUI scenario run: isolated state roots, fixture folders and (through an isolated suit) the workspaces the
scenario starts with. Writes ENV.json (environment for the editor) and prints nothing else on success.

    python -I gui_fixture.py --root CHECKOUT --out RUNDIR --scenario NAME

A scenario module may define FIXTURE = {"workspaces": ["alpha", "beta"], "open": "alpha"}: each name is a folder under
RUNDIR/fixture holding a1.txt, a2.txt, ... and becomes a suit workspace called Alpha, Beta, ...; `open` is the folder
the editor starts in. Nothing here touches the user's suit, agent state, scratch folders or sessions: every root is under
RUNDIR, and suit runs in `isolated` mode with its own home."""
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
    from suit import library_path, library_variable
    spec = importlib.util.spec_from_file_location("scenario", HERE / "gui_scenarios" / (scenario + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.argv_backup, sys.argv = sys.argv, [scenario]
    spec.loader.exec_module(module)
    sys.argv = sys.argv_backup
    fixture = getattr(module, "FIXTURE", {"workspaces": ["alpha"], "open": "alpha"})
    haxeon = Path(os.environ.get("HAXEON_ROOT", root / "haxeon"))
    hl = haxeon / ".tools" / "hashlink" / "hl.exe"
    suit = root / "suit" / "build" / "host" / "main.hl"
    env = {
        "PRAGTICAL_PORTABLE": str(out / "state"),
        "EXOSUIT_SUIT": "isolated", "EXOSUIT_SUIT_HOME": str(out / "suit-home"), "EXOSUIT_SUIT_SCAN": "0",
        "EXOSUIT_SUIT_TRAY": "0", "EXOSUIT_SUIT_IDLE_SECONDS": "150", "EXOSUIT_SUIT_LAUNCHER": str(suit),
        "EXOSUIT_AGENT_STATE_HOME": str(out / "agent-state"), "EXOSUIT_SCRATCH_HOME": str(out / "scratch"),
        "EXOSUIT_AUTOMATION_DIR": str(out / "automation"),
    }
    for key, value in fixture.get("env", {}).items():  # extra variables for the editor; {result} is the result folder
        env[key] = value.replace("{result}", str(out / "result"))
    for key in ("state", "agent-state", "scratch", "result"):  # the app makes the automation folder itself, owner-only
        (out / key).mkdir(parents=True, exist_ok=True)
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
    child_env[library_variable()] = library_path(suit, hl, haxeon, os.environ.get(library_variable(), ""))
    started = subprocess.run([str(hl), str(suit), "start"], env=child_env, capture_output=True, text=True, timeout=60)
    if started.returncode != 0:
        sys.exit(f"suit start failed ({started.returncode}): {started.stderr}{started.stdout}")
    for name in fixture["workspaces"]:
        result = subprocess.run([str(hl), str(suit), "workspace", "new", "--name", name.capitalize(), str(folders[name])],
                                env=child_env, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            sys.exit(f"suit workspace new failed ({result.returncode}): {result.stderr}{result.stdout}")
    # The isolated suit may have started a daemon for the registry; it exits when idle (EXOSUIT_SUIT_IDLE_SECONDS).
    start = folders[fixture["open"]] if fixture.get("open") else None
    (out / "ENV.json").write_text(json.dumps({"env": env, "open": str(start) if start else None,
                                              "fixture": str(out / "fixture"), "appArgs": fixture.get("appArgs", [])}))


main()
