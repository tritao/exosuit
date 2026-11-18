"""G08, port against baseline: an agent session's chat panel (the fake Codex, no real provider).

Alpha's row menu starts New Agent Session; the fake answers every prompt with "FAKE-REPLY: <prompt>" at once.

  typing     the prompt field gets "hello from the port check" one key at a time: on the port only the session
             panel's scope rebuilds (F2), the Send button enables in the same frame.
  reply      Enter sends it; the prompt and the reply show in the transcript.
  slash      "/" opens the command suggestions, Down x2, Up, Escape closes them, Backspace clears the field.
  scroll     wheel notches over the transcript, up then down.
Then a second prompt, so the transcript holds two turns, and the window closes."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403

FIXTURE = port_fixture(with_fake_agents({"workspaces": ["alpha"], "open": None, "appArgs": ["--open-workbench"]}))
PROMPT = "hello from the port check"


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 1 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    show_workbench(gui)
    gui.open_workspace(alpha)
    attached(gui, "Alpha")
    check_traced(gui)
    sid = new_agent_from_menu(gui, "w:" + alpha, "Alpha's row menu")
    if sid is None:
        return
    gui.check("the session is ready for a prompt", lambda s: gui.find(s, "Codex prompt"), 30)
    field = gui.element("Codex prompt")
    gui.click(field)
    time.sleep(0.5)

    begin(gui, "typing")
    type_keys(gui, PROMPT, 0.12)
    time.sleep(0.4)
    begin(gui, "reply")
    key(gui, "enter", 0.1)
    gui.check("the prompt shows in the transcript", lambda s: any(PROMPT in l for l in shown_transcript(s["state"]) if l.startswith("userMessage")), 20,
              detail=lambda s: (active_tab(s["state"]), s["state"]["notifications"][-3:]))
    gui.check("the fake's reply shows in the transcript", lambda s: any(("FAKE-REPLY: " + PROMPT) in l for l in shown_transcript(s["state"])), 20,
              detail=lambda s: active_tab(s["state"]))
    gui.shot("reply")
    gui.click(gui.element("Codex prompt"))
    time.sleep(0.3)

    begin(gui, "slash")
    type_keys(gui, "/", 0.3)
    for chord in ("down", "down", "up"):
        key(gui, chord, 0.25)
    gui.shot("suggestions")
    key(gui, "escape", 0.3)
    key(gui, "backspace", 0.3)
    begin(gui, "scroll")
    prompt = gui.element("Codex prompt")
    x, y = prompt["x"] + prompt["w"] / 2, max(80, prompt["y"] - 200)
    for notches in (3, 3, 3, -3, -3, -3):
        wheel(gui, x, y, notches)
        time.sleep(0.2)
    idle(gui, "idle", 4)
    end(gui)
    ask(gui, "second turn", "the same session")
    close_window(gui)


if __name__ == "__main__":
    run_port(run)
