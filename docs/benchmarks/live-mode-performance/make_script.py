import json, sys
# Same interaction for every run; `offset` delays it (seconds after the first frame) so live patches can land first.
def build(offset):
    ev = []; t = offset
    ev.append({"at": t, "kind": "checkpoint", "label": "interaction-start"})
    t += 1.0
    ev.append({"at": round(t,3), "kind": "checkpoint", "label": "hover-start"})
    ys = list(range(60, 275, 5))
    for p in range(10):                       # ~14 s of sweeps over the activity-bar icons
        for y in (ys if p % 2 == 0 else ys[::-1]):
            ev.append({"at": round(t,3), "kind": "move", "x": 28, "y": y}); t += 0.033
    ev.append({"at": round(t,3), "kind": "checkpoint", "label": "hover-end"})
    t += 1.0
    ev.append({"at": round(t,3), "kind": "move", "x": 700, "y": 350}); t += 0.5
    ev.append({"at": round(t,3), "kind": "checkpoint", "label": "scroll-start"})
    for direction in (-1, 1, -1, 1):          # down, up, down, up through TextBuffer.hx, 6 s each
        for _ in range(120):
            ev.append({"at": round(t,3), "kind": "scroll", "dx": 0, "dy": direction}); t += 0.05
    ev.append({"at": round(t,3), "kind": "checkpoint", "label": "scroll-end"})
    t += 1.0
    ev.append({"at": round(t,3), "kind": "checkpoint", "label": "interaction-end"})
    return {"version": 1, "events": ev}, t
offset = float(sys.argv[1]); out = sys.argv[2]
script, end = build(offset)
json.dump(script, open(out, "w"))
print(f"{out}: {len(script['events'])} events, ends at {end:.1f}s")
