# Skribidi edit-window differential probe

This stand-alone C program tests the proposed cached-prefix / newly shaped
window / cached-suffix update against a fresh Skribidi layout. It loads the
same font set for all three layouts, aligns window edges to old cluster
boundaries, and compares cluster ranges, glyph IDs, advances, and vertical
offsets. An unchanged four-codepoint guard on each edge can reject a window
and request a wider one. Substitution, insertion, and deletion fixtures cover
repeated ASCII, Latin ligatures, Arabic joining, mixed Hebrew/Latin, and emoji
ZWJ sequences. Another 36 edit positions sweep the Latin, Arabic, and emoji
fixtures. The full-window case must match; an accepted short window that
differs from the fresh layout causes the probe to fail.

Build and run from the Exosuit root:

```sh
cmake -S experiments/skribidi_edit_window -B /tmp/exosuit-edit-window-build \
  -DSKRIBIDI_SOURCE="$(realpath ../uikit/vendor/skribidi)" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/exosuit-edit-window-build --target edit_window_probe -j 8
/tmp/exosuit-edit-window-build/edit_window_probe
```

The current fixtures and 36-position sweep pass. A four-codepoint window fails the full comparison
on Latin substitution/deletion and Arabic substitution/deletion; the guard
rejects each. After cluster alignment, emoji ZWJ cases pass at the sampled
positions. Arabic windows of 130 codepoints still fail at the left seam and
are rejected. These observations rule out a fixed-size shaping window for
the general path. The guard rejected every sampled mismatching window, but
that sample is too small to establish a general safety rule.

The guard is an experimental rejection check, **not a proof of safe reuse**.
The probe has sampled positions and fonts, compares glyph signatures rather
than final visual order or caret geometry, and scans all old clusters when
assembling a candidate. It does not yet meet the 50 ms edit budget or run in
UIKit. A production design needs indexed cluster storage, an explicit
fallback for contextual/bidi changes, and full-layout differential checks for
carets, line breaks, and visible glyph positions.
