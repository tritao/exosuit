# TODO

- [ ] Add responsive file loading and deliberate large-file handling.
  Use one file-opening pipeline for tree clicks, commands, and session restoration,
  with loading, ready, failed, and cancelled states. Show the filename tab immediately
  and reveal a spinner with “Opening file…” after about 150 ms to avoid flicker for
  fast opens. Move file reading and text validation off the UI thread; closing a
  loading tab cancels its request, and stale results must not replace newer selections.
  Inspect file size and sample bytes before reading the entire file, allowing binary
  files to show the warning and bounded byte preview without a full read. For large
  text files, show the size and offer “Open Text” or “View Bytes”; define a large-file
  mode that reduces expensive features such as the minimap and syntax analysis.
  Show progress only when measurable, and provide clear read errors with retry.
  Check slow reads, large text and binary files, cancellation, rapid selection changes,
  session restoration, and loading failures.

- [ ] Add stepped minimap scaling at higher zoom levels.
  Preserve the dense appearance at normal zoom, then increase visual row pitch
  and mark size together at thresholds derived from the rendered scale. Use
  separate thresholds when increasing and decreasing scale to prevent oscillation
  near boundaries. Keep panel width stable initially and retain the shared visual
  row mapping for painting, viewport indication, clicking, and dragging. Check
  appearance across zoom levels, word wrap, short and long files, and dragging
  across a scale change.

- [ ] Introduce shared canonical file identity handling for symlink aliases.
  Ctrl-P currently deduplicates normalized paths across overlapping project
  indexes, but aliases through symlinked directories or files can still appear
  as separate candidates. Resolve and cache identities during workspace indexing
  and reuse them for candidate merging and document lookup, without filesystem
  lookups on every picker open or keystroke. Preserve distinct files in separate
  checkouts and scope remote identities by workspace. Cover symlinked roots,
  directories, and files, including retargeted or broken links.
