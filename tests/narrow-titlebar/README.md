Run from the repository root:

```sh
xvfb-run -a haxeon/scripts/haxeon run --project tests/narrow-titlebar/haxeon.json -- /tmp/titlebar-light
xvfb-run -a haxeon/scripts/haxeon run --project tests/narrow-titlebar/haxeon.json -- /tmp/titlebar-dark dark
```

Checks the real app titlebar at widths from 320 to 1280 layout pixels,
including shrinking, expanding, maximized/restored controls and application zoom.
Window controls retain their full width and native client hit regions; Commands
remains visible while optional shortcuts collapse and return.
