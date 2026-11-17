"""G03, port against baseline: the side bar's Files tree (explorer trees publish a change signal on the port, D3).

Alpha holds a1-a3.txt and a folder `sub` with s1-s3.txt.

  keys       a click on a1.txt, then Down x3, Up x2: the selection moves (no file opens).
  expand     `sub` expands with Right and collapses with Left (keyboard, T11), then expands and collapses by a click on
             its row (pointer): s1.txt shows and goes each time.
  create     a file written into Alpha's folder from outside shows in the tree (the watcher, T2/T13), and goes when it is
             deleted (file-deletion).
  idle       nothing for 4 s."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403


def prepare(out, root, env, exohost):
    sub = os.path.join(out, "fixture", "alpha", "sub")
    os.makedirs(sub, exist_ok=True)
    for index in range(1, 4):
        with open(os.path.join(sub, "s%d.txt" % index), "w") as f:
            f.write("sub file %d\n" % index)


FIXTURE = port_fixture({"workspaces": ["alpha"], "open": "alpha"})


def shown(label):
    return lambda s: any(e["label"] == label for e in s["elements"])


def gone(label):
    return lambda s: not any(e["label"] == label for e in s["elements"])


def run(gui):
    attached(gui, "Alpha")
    check_traced(gui)
    folder = os.path.join(os.path.dirname(gui.out), "fixture", "alpha")
    gui.check("the Files tree lists a1.txt and sub", lambda s: shown("a1.txt")(s) and shown("sub")(s), 20,
              detail=lambda s: [e["label"] for e in s["elements"] if e["role"] in ("4", "31")][:30])
    time.sleep(1)

    begin(gui, "keys")
    click(gui, gui.element("a1.txt", role="4"))
    for chord in ("down", "down", "down", "up", "up"):
        key(gui, chord, 0.25)
    begin(gui, "expand")
    click(gui, gui.element("sub"))
    key(gui, "right", 0.6)
    gui.check("Right expands sub (keyboard)", shown("s1.txt"), 4)
    key(gui, "left", 0.6)
    gui.check("Left collapses sub (keyboard)", gone("s1.txt"), 4)
    click(gui, gui.element("sub"))
    gui.check("a click on sub's row expands it (pointer)", shown("s1.txt"), 4)
    click(gui, gui.element("sub"))
    gui.check("a second click collapses it (pointer)", gone("s1.txt"), 4)

    begin(gui, "create")
    mark(gui, "write new-file.txt")
    path = os.path.join(folder, "new-file.txt")
    with open(path, "w") as f:
        f.write("made from outside\n")
    gui.check("a file written from outside shows in the tree", shown("new-file.txt"), 15)
    mark(gui, "delete new-file.txt")
    os.remove(path)
    gui.check("deleting it removes its row", gone("new-file.txt"), 15)
    idle(gui, "idle", 4)
    end(gui)
    gui.shot("explorer")
    close_window(gui)


if __name__ == "__main__":
    run_port(run)
