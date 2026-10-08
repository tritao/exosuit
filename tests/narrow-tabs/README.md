Run the headless regression from the repository root:

```sh
haxeon/scripts/haxeon run --project tests/narrow-tabs/haxeon.json
```

The fixture uses the application's light and dark themes and terminal session tab
labels at pane widths of 90, 120, 180, 320, and 700 logical pixels. It checks that
headers retain their label widths, adjacent labels cannot overlap, and paint is
clipped to the pane. Selecting a tab or resizing reveals the active header,
including titles wider than the viewport. It also exercises keyboard selection,
mouse-wheel scrolling, retained headers, and clicking a tab after scrolling.
