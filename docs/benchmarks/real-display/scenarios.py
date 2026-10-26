#!/usr/bin/env python3
"""Scripted sessions for run.sh, played by the app into its own window (--input-script). Times are seconds after the
first content frame; coordinates are window-local logical pixels in the default 1280x840 window. Each phase is a pair
of "<phase>-start" and "<phase>-end" checkpoints, which report.py summarizes.

Usage: scenarios.py NAME OUT_JSON   (prints the files the session opens at launch, one per line)"""
import json
import sys

A, P, ENTER, BACKSPACE, PAGE_DOWN, HOME, END, CONTROL = 65, 80, 257, 259, 267, 268, 269, 2
FRAME = 1 / 60


class Session:
    def __init__(self, start=3.0):
        self.events, self.t = [], start

    def at(self, kind, **fields):
        self.events.append({"at": round(self.t, 4), "kind": kind, **fields})

    def wait(self, seconds):
        self.t += seconds

    def mark(self, label):
        self.at("checkpoint", label=label)

    def click(self, x, y):
        self.at("move", x=x, y=y)
        self.at("down", x=x, y=y)
        self.wait(0.03)
        self.at("up", x=x, y=y)

    def key(self, key, modifiers=0):
        self.at("key", key=key, modifiers=modifiers) if modifiers else self.at("key", key=key)

    def open(self, name, phase):
        """Opens a file through the file finder (Ctrl+P), as a person would; the phase covers it being shown."""
        self.mark(phase + "-start")
        self.key(P, CONTROL)
        self.wait(0.4)
        self.at("text", text=name)
        self.wait(0.6)
        self.key(ENTER)
        self.wait(4.0)
        self.mark(phase + "-end")
        self.wait(0.5)


def session():
    """Startup, sidebar switching, hovering, typing, scrolling and paging in a 10 MB file opened at launch."""
    s = Session(0.5)
    s.mark("startup-start")
    s.t = 4.0
    s.mark("startup-end")
    s.mark("sidebar-start")
    for x, y in [(36, 137), (36, 247), (36, 82)] * 3:  # search, workbench, files
        s.click(x, y)
        s.wait(0.6)
    s.mark("sidebar-end")
    s.wait(0.5)
    s.mark("hover-start")
    ys = list(range(60, 275, 5))
    for sweep in range(4):
        for y in ys if sweep % 2 == 0 else ys[::-1]:
            s.at("move", x=28, y=y)
            s.wait(0.033)
    s.mark("hover-end")
    s.wait(0.5)
    s.click(450, 132)
    s.wait(0.5)
    s.mark("typing-start")
    for word in ["ordinary", "editable", "profiled", "realistic"] * 3:
        for character in word + " ":
            s.at("text", text=character)
            s.wait(0.08)
    for _ in range(20):
        s.key(BACKSPACE)
        s.wait(0.08)
    s.mark("typing-end")
    s.wait(0.5)
    s.at("move", x=700, y=450)
    s.wait(0.3)
    s.mark("scroll-start")
    for direction in (-1, 1):
        for _ in range(120):
            s.at("scroll", dx=0, dy=direction)
            s.wait(0.03)
    s.mark("scroll-end")
    s.wait(0.5)
    s.mark("paging-start")
    for _ in range(30):
        s.key(PAGE_DOWN)
        s.wait(0.06)
    s.key(END, CONTROL)
    s.wait(0.5)
    s.key(HOME, CONTROL)
    s.wait(0.5)
    s.mark("paging-end")
    s.mark("idle-start")
    s.wait(3.0)
    s.mark("idle-end")
    return s, ["big.txt"]


def open_files():
    """Opens a normal source file, then the 10 MB file, through the file finder."""
    s = Session()
    s.open("ExosuitApp.hx", "normal-open")
    s.open("big.txt", "large-open")
    return s, []


def selection():
    """Select all and deselect, then drag-select past the bottom edge (auto-scrolling) and back, in each file."""
    s = Session()
    for name, label in [("ExosuitApp.hx", "normal"), ("big.txt", "large")]:
        s.open(name, label + "-open")
        s.click(500, 300)
        s.wait(0.5)
        s.mark(label + "-selectall-start")
        for _ in range(3):
            s.key(A, CONTROL)
            s.wait(0.7)
            s.click(500, 300)
            s.wait(0.7)
        s.mark(label + "-selectall-end")
        s.wait(0.3)
        s.mark(label + "-drag-start")
        for _ in range(2):
            s.at("move", x=420, y=110)
            s.at("down", x=420, y=110)
            for step in range(1, 31):  # a fast flick past the bottom edge
                s.wait(0.008)
                s.at("move", x=420 + step * 15, y=110 + step * 25)
            for _ in range(60):  # held below the editor: edge auto-scroll
                s.wait(FRAME)
                s.at("move", x=870, y=865)
            for step in range(1, 31):  # and back up past the top
                s.wait(0.008)
                s.at("move", x=870 - step * 15, y=865 - step * 27)
            for _ in range(30):
                s.wait(FRAME)
                s.at("move", x=420, y=55)
            s.at("up", x=420, y=55)
            s.wait(0.3)
            s.click(500, 300)
            s.wait(0.6)
        s.mark(label + "-drag-end")
        s.wait(0.5)
    return s, []


def sustained():
    """Input every frame, as holding a key or a fast trackpad gives: typing and scrolling at 60 Hz in each file, so a
    phase shows whether the editor keeps up with a frame's worth of work per frame."""
    s = Session()
    for name, label in [("ExosuitApp.hx", "normal"), ("big.txt", "large")]:
        s.open(name, label + "-open")
        s.click(500, 300)
        s.wait(0.5)
        s.mark(label + "-type60-start")
        for index in range(180):  # three seconds of a character per frame
            s.at("text", text="abcdefghij"[index % 10])
            s.wait(FRAME)
        for _ in range(90):
            s.key(BACKSPACE)
            s.wait(FRAME)
        s.mark(label + "-type60-end")
        s.wait(0.5)
        s.at("move", x=700, y=450)
        s.wait(0.2)
        s.mark(label + "-scroll60-start")
        for direction in (-1, 1):
            for _ in range(180):
                s.at("scroll", dx=0, dy=direction)
                s.wait(FRAME)
        s.mark(label + "-scroll60-end")
        s.wait(0.5)
    return s, []


SCENARIOS = {"session": session, "open": open_files, "selection": selection, "sustained": sustained}

if __name__ == "__main__":
    name, out = sys.argv[1], sys.argv[2]
    if name not in SCENARIOS:
        sys.exit("unknown scenario " + name + "; one of " + ", ".join(SCENARIOS))
    built, startup = SCENARIOS[name]()
    json.dump({"version": 1, "events": built.events}, open(out, "w"))
    for path in startup:
        print(path)
