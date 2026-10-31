"""The driver's own safety: with another program in front it must refuse keys and clicks and leave that program untouched.
A small window of its own (started and stopped here) takes the foreground and records any text it receives."""
import os
import subprocess
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

FIXTURE = {"workspaces": ["alpha"], "open": None, "appArgs": ["--open-workbench"]}

DECOY = r'''
import sys, tkinter
path = sys.argv[1]
root = tkinter.Tk()
root.title("driver guard decoy")
root.geometry("300x120+200+200")
entry = tkinter.Entry(root); entry.pack(fill="x"); entry.focus_force()
root.attributes("-topmost", True)
def dump():
    open(path, "w").write(entry.get() + "|clicks=" + str(clicks[0])); root.after(100, dump)
clicks = [0]
root.bind("<Button-1>", lambda e: clicks.__setitem__(0, clicks[0] + 1))
dump(); root.mainloop()
'''


def run(gui):
    gui.wait("workspace rows", lambda s: gui.find(s, pattern="^w:"), 60)
    row = gui.element(pattern="^w:")
    log = os.path.join(gui.out, "decoy.txt")
    script = os.path.join(gui.out, "decoy.py")
    with open(script, "w") as f:
        f.write(DECOY)
    decoy = subprocess.Popen([sys.executable, script, log])
    try:
        gui.wait("decoy in front", lambda s: gui._foreground_pid() == decoy.pid, 15)
        gui.expect_refusal("keys are refused while another window is in front", lambda: gui.type_text("leak"))
        gui.expect_refusal("a chord is refused", lambda: gui.chord("ctrl+shift+a"))
        gui.expect_refusal("a click is refused", lambda: gui.click(row))
        time.sleep(0.5)
        text = open(log).read()
        gui.check("the decoy received nothing", lambda s: text == "|clicks=0", 1, detail=lambda s: text)
        gui.check("no key or button is left held", lambda s: not gui.held_keys and not gui.held_buttons, 1)
    finally:
        decoy.kill()
        decoy.wait()


if __name__ == "__main__":
    main(run)
