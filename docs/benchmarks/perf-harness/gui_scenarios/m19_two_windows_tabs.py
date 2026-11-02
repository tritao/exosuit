"""M19 Phase 8: tabs belong to the window. Two editor windows on the same group (window 2 is started from the group's row
with Open in New Window) open different files and each keeps its own tabs; both see the same terminal, and what is typed
into it in one window shows in the other, in both directions.

The second window's automation folder is EXOSUIT_NEW_WINDOW_AUTOMATION_DIR (set by the fixture)."""
import os
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from gui_driver import Gui
from m19_folders import menu, open_by_double_click
from m19_sessions_drag import create, new_terminal

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"],
           "env": {"EXOSUIT_NEW_WINDOW_AUTOMATION_DIR": "{out}/automation-2"}}


def documents(state):
    """File names of the open document tabs, in order."""
    return [t["title"].replace("\\", "/").split("/")[-1] for p in state["panes"] for t in p["tabs"] if t["kind"] == "document"]


def terminal_text(state):
    """Everything the terminal tabs show."""
    return "\n".join(line for p in state["panes"] for t in p["tabs"] if t["kind"] == "terminal" for line in t.get("lines", []))


def run(gui):
    second_pid = None
    try:
        gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
        alpha = ws(gui.state(), "Alpha")["id"]
        open_by_double_click(gui, alpha, "Alpha")
        show_workbench(gui)
        work = gui.wait("Alpha's group Work", lambda s: next((g["id"] for g in s["state"]["groups"] if g["name"] == "Work"), None), 20)
        # Work has the workspace's folder and so shares the root's context key; a group of its own has a key of its own.
        create(gui, "g:" + work, "New group", "Second", "groups")
        second = next(g["id"] for g in gui.state()["groups"] if g["name"] == "Second")
        gui.click(gui.element("g:" + work))
        quick_switch(gui, "Second")
        gui.check("window 1 is on the group Second", lambda s: s["state"]["context"].endswith("/" + second), 10, detail=lambda s: s["state"]["context"])

        gui.step("Open in New Window on the group Second: window 2 on the same group")
        reveal(gui, work, second)
        menu(gui, "g:" + second, "Open in New Window")
        second_pid = gui.wait("window 2 registered on Second",
                              lambda s: next((w["pid"] for w in s["state"]["otherWindows"] if w["context"].endswith("/" + second)), None), 60)
        two = Gui(second_pid, os.path.join(os.path.dirname(gui.dir), "automation-2"), os.path.join(gui.out, "window2"),
                  max(10, gui.deadline - time.monotonic()), 30)
        two.wait("window 2 attached to Alpha", lambda s: s["state"]["openWorkspace"] == alpha and s["state"]["groups"] is not None, 40)
        two.check("window 2 is on the same group as window 1", lambda s: s["state"]["context"].endswith("/" + second), 5,
                  detail=lambda s: s["state"]["context"])

        gui.step("each window opens its own file")
        gui.focus()
        open_file(gui, "a1.txt")
        gui.check("window 1 shows a1.txt", lambda s: documents(s["state"]) == ["a1.txt"], 10, detail=lambda s: documents(s["state"]))
        two.focus()
        show_workbench(two)
        open_file(two, "a2.txt")
        two.check("window 2 shows a2.txt", lambda s: documents(s["state"]) == ["a2.txt"], 10, detail=lambda s: documents(s["state"]))
        time.sleep(1)
        gui.check("window 1 still shows only a1.txt", lambda s: documents(s["state"]) == ["a1.txt"], 5, detail=lambda s: documents(s["state"]))
        two.check("window 2 still shows only a2.txt", lambda s: documents(s["state"]) == ["a2.txt"], 5, detail=lambda s: documents(s["state"]))
        gui.shot("window1-tabs")
        two.shot("window2-tabs")

        gui.step("one terminal in the group; window 1 types into it, window 2 sees it")
        gui.focus()
        terminal = new_terminal(gui, "g:" + second)
        gui.check("window 1 has the terminal tab", lambda s: any(t["kind"] == "terminal" for p in s["state"]["panes"] for t in p["tabs"]), 10)
        two.wait("window 2 lists the terminal", lambda s: any(t["id"] == terminal for t in s["state"]["terminals"]), 20)
        two.focus()
        reveal(two, work, second)
        if not two.find(two.snapshot(), "t:" + terminal):
            two.click(two.element("g:" + second))
            two.chord("right")
        two.click(two.element("t:" + terminal))
        two.check("window 2 opened the terminal in a tab", lambda s: any(t["kind"] == "terminal" for p in s["state"]["panes"] for t in p["tabs"]), 10)
        time.sleep(2)  # both shells' prompts
        gui.focus()
        gui.type_text("echo FROM-ONE-" + "1111")
        gui.chord("enter")
        gui.check("window 1 shows its own input", lambda s: "FROM-ONE-1111" in terminal_text(s["state"]), 15, detail=lambda s: terminal_text(s["state"]))
        two.check("window 2 shows what window 1 typed", lambda s: "FROM-ONE-1111" in terminal_text(s["state"]), 15, detail=lambda s: terminal_text(s["state"]))

        gui.step("window 2 takes control of the terminal, types, and window 1 sees it")
        two.focus()
        two.check("window 2 is a viewer: another client controls the terminal", lambda s: two.find(s, "Take control"), 10)
        two.click(two.element("Take control"))
        two.check("window 2 controls the terminal now", lambda s: not two.find(s, "Take control"), 10)
        gui.check("window 1 is a viewer now", lambda s: gui.find(s, "Take control"), 10)
        two.click(two.element("t:" + terminal))  # the click hands the keyboard to the terminal
        two.shot("before-typing")
        two.type_text("echo FROM-TWO-2222")
        two.chord("enter")
        two.check("window 2 shows its own input", lambda s: "FROM-TWO-2222" in terminal_text(s["state"]), 15, detail=lambda s: terminal_text(s["state"]))
        gui.check("window 1 shows what window 2 typed", lambda s: "FROM-TWO-2222" in terminal_text(s["state"]), 15, detail=lambda s: terminal_text(s["state"]))

        gui.step("the document tabs are still each window's own")
        gui.check("window 1 documents: a1.txt only", lambda s: documents(s["state"]) == ["a1.txt"], 5, detail=lambda s: documents(s["state"]))
        two.check("window 2 documents: a2.txt only", lambda s: documents(s["state"]) == ["a2.txt"], 5, detail=lambda s: documents(s["state"]))
        gui.shot("window1-end")
        two.shot("window2-end")
    finally:
        if second_pid is not None:
            subprocess.run(["taskkill", "/PID", str(second_pid), "/T", "/F"], capture_output=True)


if __name__ == "__main__":
    main(run)
