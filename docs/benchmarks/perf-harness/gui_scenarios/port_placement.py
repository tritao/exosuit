"""A saved window placement on startup (window.conf in the state folder). PORT_PLACEMENT=on seeds bounds on the primary
monitor, which the window must open at; PORT_PLACEMENT=off seeds bounds no monitor covers, which the editor must ignore
and open where the system puts it. Either way the editor must start, and on quit it saves where the window really was."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403

ON = (140, 120, 900, 700)
OFF = (-30000, -30000, 900, 700)
SEED = OFF if os.environ.get("PORT_PLACEMENT") == "off" else ON
FIXTURE = port_fixture({"workspaces": ["alpha"], "open": "alpha",
                        "stateFiles": {"window.conf": "%d %d %d %d normal\n" % SEED}})


def saved(gui):
    path = os.path.join(os.path.dirname(gui.out), "state", "window.conf")
    try:
        parts = open(path).read().split()
        return [int(value) for value in parts[:4]] + parts[4:]
    except (OSError, ValueError):
        return None


def run(gui):
    gui.wait("the window shows the workspace", lambda s: s["state"].get("openWorkspace") is not None, 30)
    gui.shot("opened")
    close_window(gui)
    placement = saved(gui)
    if SEED == ON:
        ok = placement is not None and abs(placement[0] - ON[0]) <= 2 and abs(placement[1] - ON[1]) <= 2 \
            and abs(placement[2] - ON[2]) <= 2 and abs(placement[3] - ON[3]) <= 2
        gui.results.append({"check": "a placement on a monitor is applied and saved back as it was", "ok": ok, "saved": placement})
    else:
        ok = placement is not None and placement[0] > -10000 and placement[1] > -10000
        gui.results.append({"check": "a placement on no monitor is ignored: the window opens on a monitor", "ok": ok, "saved": placement})


if __name__ == "__main__":
    run_port(run)
