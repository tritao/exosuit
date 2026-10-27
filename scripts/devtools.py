#!/usr/bin/env python3
"""Build and run the standalone Haxeon DevTools UI."""
from pathlib import Path
import os
import subprocess
import socket
import sys

from haxeon_cli import run_cli


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    home = Path(os.environ.get("HAXEON_ROOT", root / "haxeon")).resolve()
    environment = {}
    native = home / "out/packages/ui/native"
    libraries = [native, native / "nativekit", native / "nativekit/modules/gpu"]
    variable = "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
    environment[variable] = os.pathsep.join([*(str(p) for p in libraries), os.environ.get(variable, "")])
    if "--launch-exosuit" in sys.argv[1:]:
        status = run_cli(root, ["build", "--project", str(root / "graphical/haxeon.json")], environment)
        if status != 0:
            return status
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        environment.update(EXOSUIT_PROJECT_ROOT=str(root), EXOSUIT_HAXEON_CLI_PYTHON=sys.executable,
                           EXOSUIT_DEVTOOLS_PROFILER_PORT=str(port), HAXEON_HOME=str(home), HAXEON_ROOT=str(home))
        libraries += [home / "out", home / ".tools/hashlink"]
        libraries += sorted(p for p in (root / "graphical/build/host/native").iterdir() if p.is_dir())
        environment[variable] = os.pathsep.join([*(str(p) for p in libraries), os.environ.get(variable, "")])
        suffix = ".exe" if os.name == "nt" else ""
        arguments = [arg for arg in sys.argv[1:] if arg != "--launch-exosuit"]
        return subprocess.run([str(home / (".tools/hashlink/hl" + suffix)), "--diagnostics", str(port),
                               str(root / "graphical/build/host/main.hl"), "--open-devtools", *arguments],
                              cwd=root, env=dict(os.environ, **environment)).returncode
    if any(arg.startswith(("--profiler-port=", "--profile-capture=")) for arg in sys.argv[1:]):
        suffix = ".exe" if os.name == "nt" else ""
        bridge = root / "devtools/build/profiler.hl"
        bridge.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(home / (".tools/haxe/haxe" + suffix)), "-cp", str(home / "src"),
                        "-cp", str(root / "devtools/bridge"), "-main", "ProfilerBridge", "-hl", str(bridge)], check=True)
        environment.update(HAXEON_DEVTOOLS_BRIDGE=str(bridge), HAXEON_DEVTOOLS_RUNTIME=str(home / (".tools/hashlink/hl" + suffix)))
        environment["HAXEON_DEVTOOLS_PROFILER_TOOL"] = str(home / (".tools/hashlink/hlprof-live" + suffix))
    return run_cli(root, ["run", "--project", str(root / "devtools/haxeon.json"), "--", *sys.argv[1:]], environment)


if __name__ == "__main__":
    sys.exit(main())
