"""Everyday sweep, sessions: a terminal from every place that offers one (the empty state's button, the workspace
row's menu, a group row's menu, the Workbench toolbar, the command palette with the terminal focused), the agent chooser from the menus, then rename,
close the tab and reopen it from its row, Close Terminal, and a group made, renamed and removed.

Real input only. Each flow is its own stage, so one broken flow does not hide the others."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sweep_common import *  # noqa: F401,F403
from m19_sessions_drag import by_name, create

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"]}


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    began = time.monotonic()
    open_by_double_click(gui, alpha, "Alpha")
    gui.results.append({"check": "Alpha opened in %.1f s" % (time.monotonic() - began), "ok": True, "note": ""})
    show_workbench(gui)
    wrow = "w:" + alpha
    made = {}
    dump(gui, "opened")

    def from_empty_state():
        gui.check("the empty state offers its three starts", lambda s: gui.find(s, "New terminal in this workspace", role="1")
                  and gui.find(s, "New group", role="1") and gui.find(s, pattern="^New agent session", role="1"), 5)
        before = terminal_ids(gui.state())
        gui.click(gui.element("New terminal in this workspace", role="1"))
        time.sleep(0.8)
        if gui.state()["commandViewActive"]:
            gui.chord("enter")
        made["e"] = fresh_terminal(gui, before, "empty state: New terminal makes a terminal")
        gui.check("its tab is open", lambda s: kinds(s["state"]).count("terminal") == 1, 5, detail=lambda s: s["state"]["panes"])
        dump(gui, "first-terminal")
    stage(gui, "terminal from the empty state's button", from_empty_state)

    def first_group():
        menu(gui, wrow, "New Group" + ELLIPSIS)
        time.sleep(0.6)
        gui.type_text("Work")
        gui.chord("enter")
        gui.check("workspace row menu: New Group makes the group Work", lambda s: by_name(s["state"], "groups", "Work"), 20,
                  detail=lambda s: (s["state"]["groups"], s["state"]["notifications"][-2:]))
    stage(gui, "group from the workspace row's menu", first_group)
    work = (by_name(gui.state(), "groups", "Work") or {}).get("id", "missing")
    grow = "g:" + work

    def from_workspace_menu():
        before = terminal_ids(gui.state())
        menu(gui, wrow, "New Terminal" + ELLIPSIS)
        gui.wait("New Terminal prompt", lambda s: s["state"]["commandViewActive"], 5)
        gui.chord("enter")
        made["w"] = fresh_terminal(gui, before, "workspace row menu: New Terminal makes a terminal")
        gui.check("its tab is open", lambda s: kinds(s["state"]).count("terminal") == 2, 5, detail=lambda s: s["state"]["panes"])
    stage(gui, "terminal from the workspace row's menu", from_workspace_menu)

    def from_group_menu():
        before = terminal_ids(gui.state())
        menu(gui, grow, "New Terminal" + ELLIPSIS)
        gui.wait("New Terminal prompt", lambda s: s["state"]["commandViewActive"], 5)
        gui.chord("enter")
        made["g"] = fresh_terminal(gui, before, "group row menu: New Terminal makes a terminal")
        gui.check("the group's terminal is in Work", lambda s: next(t for t in s["state"]["terminals"] if t["id"] == made["g"])["group"] == work, 5,
                  detail=lambda s: s["state"]["terminals"])
    stage(gui, "terminal from the group row's menu", from_group_menu)

    def from_toolbar():
        before = terminal_ids(gui.state())
        gui.click(gui.element("New terminal", role="1"))
        time.sleep(0.8)
        if gui.state()["commandViewActive"]:
            gui.chord("enter")
        made["t"] = fresh_terminal(gui, before, "toolbar: New terminal makes a terminal")
    stage(gui, "terminal from the Workbench toolbar", from_toolbar)

    def from_palette():
        # The new terminal's tab has the keyboard now, as it does for a user who just made one.
        before = terminal_ids(gui.state())
        gui.chord("ctrl+shift+p")
        gui.check("Ctrl+Shift+P opens the palette while a terminal has focus", lambda s: s["state"]["commandViewActive"], 4,
                  detail=lambda s: s.get("focus"))
        if not gui.state()["commandViewActive"]:
            focus_tree(gui, grow)
            gui.chord("ctrl+shift+p")
            gui.wait("palette from the tree", lambda s: s["state"]["commandViewActive"], 5)
        gui.type_text("New Terminal")
        time.sleep(0.5)
        dump(gui, "palette-new-terminal")
        gui.chord("enter")
        time.sleep(0.8)
        if gui.state()["commandViewActive"]:
            gui.chord("enter")
        made["p"] = fresh_terminal(gui, before, "palette: New Terminal makes a terminal")
    stage(gui, "terminal from the command palette", from_palette)
    dump(gui, "five-terminals")
    def rows_in_order(s):
        ys = [gui.find(s, "t:" + made[k])[0]["y"] for k in ("e", "w", "t", "p") if made.get(k) and gui.find(s, "t:" + made[k])
              and next(t for t in s["state"]["terminals"] if t["id"] == made[k])["group"] == ""]
        return len(ys) >= 2 and ys == sorted(ys)
    gui.check("the workspace's terminals are listed in the order they were made", rows_in_order, 2,
              detail=lambda s: [(t["name"], gui.find(s, "t:" + t["id"])[0]["y"]) for t in s["state"]["terminals"] if gui.find(s, "t:" + t["id"])])
    no_errors(gui, "after creating terminals")

    def agent_choosers():
        for row, name in ((wrow, "workspace"), (grow, "group")):
            menu(gui, row, "New Agent Session" + ELLIPSIS)
            gui.check("%s row menu: the agent chooser lists providers" % name, lambda s: gui.find(s, pattern="Codex|Claude"), 8,
                      detail=lambda s: [e["label"] for e in s["elements"] if e["role"] == "16"][:20])
            if name == "group":
                dump(gui, "agent-chooser")
            gui.chord("escape")
            gui.wait("chooser closed", lambda s: not s["state"]["commandViewActive"], 5)
    stage(gui, "agent session chooser from the menus", agent_choosers)

    def rename_terminal():
        tid = made.get("g") or next(iter(terminal_ids(gui.state())))
        menu(gui, "t:" + tid, "Rename Terminal" + ELLIPSIS)
        time.sleep(0.6)
        dump(gui, "rename-terminal")
        gui.type_text("builds")  # the current name is selected, so typing replaces it
        gui.chord("enter")
        gui.check("the terminal is called builds in the catalog", lambda s: next(t for t in s["state"]["terminals"] if t["id"] == tid)["name"] == "builds", 10,
                  detail=lambda s: s["state"]["terminals"])
        gui.check("its tab is called builds", lambda s: "builds" in [t["title"] for p in s["state"]["panes"] for t in p["tabs"]], 5,
                  detail=lambda s: s["state"]["panes"])
    stage(gui, "rename a terminal from its row", rename_terminal)

    def close_and_reopen_tab():
        tid = made.get("g") or next(iter(terminal_ids(gui.state())))
        gui.click(gui.element("t:" + tid))
        gui.check("a click on the row shows its tab", lambda s: active_title(s["state"]) == "builds", 5, detail=lambda s: (active_title(s["state"]), titles(s["state"])))
        count = len(titles(gui.state()))
        focus_tree(gui, "t:" + tid)
        palette(gui, "Close Tab")
        gui.check("the tab closed, the terminal is still in the catalog", lambda s: len(titles(s["state"])) == count - 1 and tid in terminal_ids(s["state"]), 6,
                  detail=lambda s: (titles(s["state"]), s["state"]["terminals"]))
        gui.click(gui.element("t:" + tid))
        gui.check("a click on its row opens the tab again", lambda s: len(titles(s["state"])) == count and active_title(s["state"]) == "builds", 8,
                  detail=lambda s: (active_title(s["state"]), titles(s["state"])))
    stage(gui, "close a terminal's tab and reopen it from its row", close_and_reopen_tab)

    def close_terminal():
        tid = made.get("w") or next(iter(terminal_ids(gui.state())))
        count = len(titles(gui.state()))
        menu(gui, "t:" + tid, "Close Terminal")
        time.sleep(0.6)
        dump(gui, "close-terminal")
        if gui.state()["commandViewActive"]:
            gui.chord("enter")
        gui.check("Close Terminal removes it from the catalog", lambda s: tid not in terminal_ids(s["state"]), 10, detail=lambda s: s["state"]["terminals"])
        gui.check("and closes its tab", lambda s: len(titles(s["state"])) == count - 1, 5, detail=lambda s: titles(s["state"]))
        gui.check("and its row is gone", lambda s: not gui.find(s, "t:" + tid), 5)
    stage(gui, "Close Terminal from the row's menu", close_terminal)

    def group_life():
        create(gui, grow, "New group", "Second", "groups")
        second = by_name(gui.state(), "groups", "Second")["id"]
        reveal(gui, work, second)
        menu(gui, "g:" + second, "Rename group")
        time.sleep(0.6)
        gui.type_text("Renamed")  # the old name is selected, so typing replaces it
        gui.chord("enter")
        gui.check("the group is called Renamed", lambda s: by_name(s["state"], "groups", "Renamed"), 10, detail=lambda s: s["state"]["groups"])
        dump(gui, "group-renamed")
        menu(gui, "g:" + second, "Remove Group")
        time.sleep(0.6)
        if gui.state()["commandViewActive"]:
            dump(gui, "remove-group-prompt")
            gui.chord("enter")
        gui.check("the group is removed", lambda s: not any(g["id"] == second for g in s["state"]["groups"]), 10, detail=lambda s: s["state"]["groups"])
        gui.check("and its row is gone", lambda s: not gui.find(s, "g:" + second), 5)
    stage(gui, "make, rename and remove a group", group_life)
    no_errors(gui, "at the end")
    dump(gui, "end")


if __name__ == "__main__":
    main(run)
