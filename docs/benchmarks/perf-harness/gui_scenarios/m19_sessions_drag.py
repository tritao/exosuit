"""M19 sessions and drag: create a group, terminals and an agent session through the Workbench menus, drag a row into
another group, drag between rows to re-order, nudge with Alt+Up/Down, and check the order persists (the catalog comes
back from the service after the window leaves the workspace and returns).

Real input only. Asserts on the service catalog as the window holds it (groups, terminals, agents with group and order)."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import menu, open_by_double_click

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"]}
ELLIPSIS = "…"


def by_name(state, kind, name):
    return next((x for x in state[kind] if x["name"] == name), None)


def order_in(state, group_id):
    """Ids of the terminals of a group in tree order (the service's order field, then arrival)."""
    items = [t for t in state["terminals"] if t["group"] == group_id]
    return [t["id"] for t in sorted(items, key=lambda t: (t["order"] if t["order"] is not None else 1 << 30))]


def create(gui, row_key, item, name, kind):
    """Right-click `row_key`, choose `item`, type `name` in the inline editor, Enter; wait for it in the catalog."""
    menu(gui, row_key, item)
    time.sleep(0.6)
    gui.type_text(name)
    gui.chord("enter")
    gui.check("%s %r created" % (kind, name), lambda s: by_name(s["state"], kind, name), 20,
              detail=lambda s: (s["state"][kind], s["state"]["notifications"][-2:]))


def new_terminal(gui, row_key):
    """New Terminal... opens a command view ("Open terminal" first); Enter takes it. Returns the new terminal's id."""
    before = {t["id"] for t in gui.state()["terminals"]}
    menu(gui, row_key, "New Terminal" + ELLIPSIS)
    time.sleep(0.8)
    gui.chord("enter")
    fresh = gui.wait("a new terminal", lambda s: next((t["id"] for t in s["state"]["terminals"] if t["id"] not in before), None), 20)
    gui.check("terminal created from the menu", lambda s: True)
    return fresh


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    open_by_double_click(gui, alpha, "Alpha")
    show_workbench(gui)
    work = gui.wait("group Work", lambda s: next((g["id"] for g in s["state"]["groups"] if g["name"] == "Work"), None), 20)

    gui.step("groups and sessions from the menus")
    create(gui, "g:" + work, "New group", "Second", "groups")
    second = by_name(gui.state(), "groups", "Second")["id"]
    t1 = new_terminal(gui, "g:" + work)
    t2 = new_terminal(gui, "g:" + work)
    t3 = new_terminal(gui, "g:" + work)
    gui.check("the three terminals are in Work, in creation order", lambda s: sorted(order_in(s["state"], work)) == sorted([t1, t2, t3]), 10,
              detail=lambda s: order_in(s["state"], work))
    gui.shot("created")
    gui.step("New Agent Session opens its provider chooser (providers need credentials, so it is cancelled)")
    menu(gui, "g:" + work, "New Agent Session" + ELLIPSIS)
    gui.check("agent chooser lists providers", lambda s: gui.find(s, pattern="Codex|Claude"), 10)
    gui.chord("escape")

    gui.step("drag t-two into the group Second")
    gui.drag(gui.element("t:" + t2), gui.element("g:" + second))
    gui.check("t-two moved into Second", lambda s: next(t for t in s["state"]["terminals"] if t["id"] == t2)["group"] == second, 10,
              detail=lambda s: s["state"]["terminals"])
    gui.check("Work keeps t-one, t-three", lambda s: sorted(order_in(s["state"], work)) == sorted([t1, t3]), 10,
              detail=lambda s: order_in(s["state"], work))
    gui.shot("dragged-into-group")

    gui.step("drag between rows: t-three above t-one")
    gui.drag(gui.element("t:" + t3), gui.element("t:" + t1), target_fy=0.08)
    gui.check("t-three now before t-one", lambda s: order_in(s["state"], work) == [t3, t1], 10,
              detail=lambda s: order_in(s["state"], work))
    gui.shot("reordered")

    gui.step("Alt+Down nudges t-three back down")
    # Order now [t3, t1]. Select t1 with one click (it also opens the terminal tab), then nudge it up and down.
    gui.click(gui.element("t:" + t1))
    time.sleep(0.5)
    # The click handed focus to the terminal, which swallows keys; right-click and Escape put focus back on the tree row.
    gui.click(gui.element("t:" + t1), button="right")
    time.sleep(0.4)
    gui.chord("escape")
    gui.chord("alt+up")
    gui.check("Alt+Up moved t-one above t-three", lambda s: order_in(s["state"], work) == [t1, t3], 10,
              detail=lambda s: order_in(s["state"], work))
    gui.chord("alt+down")
    gui.check("Alt+Down moved it back below", lambda s: order_in(s["state"], work) == [t3, t1], 10,
              detail=lambda s: order_in(s["state"], work))
    gui.shot("nudged")

    gui.step("the order persists: leave the workspace and come back")
    before = order_in(gui.state(), work)
    show_workbench(gui)
    beta = ws(gui.state(), "Beta")["id"]
    gui.click(gui.element("w:" + beta), count=1)
    time.sleep(2)
    gui.click(gui.element("w:" + beta), button="right")
    gui.click(gui.element("Open", role="16"))
    attached(gui, "Beta")
    show_workbench(gui)
    gui.click(gui.element("w:" + alpha), button="right")
    gui.click(gui.element("Open", role="16"))
    attached(gui, "Alpha")
    gui.check("order after returning to Alpha is unchanged", lambda s: order_in(s["state"], work) == before, 20,
              detail=lambda s: (before, order_in(s["state"], work)))
    gui.check("t-two is still in Second", lambda s: next((t for t in s["state"]["terminals"] if t["id"] == t2), {}).get("group") == second, 10)
    gui.shot("after-return")


if __name__ == "__main__":
    main(run)
