# Skribidi edit-window differential probe

This stand-alone C program tests the proposed cached-prefix / newly shaped
window / cached-suffix update against a fresh Skribidi layout. It loads the
same font set for all three layouts, aligns window edges to old cluster
boundaries, and compares cluster ranges, glyph IDs, advances, and vertical
offsets. It also compares per-codepoint text properties and the logical
ranges, IDs, directions, bidi levels, and positions of glyphs in visual render
order. It compares leading and trailing caret positions against the fresh
layout, and checks real Skribidi character-wrap breaks for an unbroken ASCII
word. An unchanged four-codepoint glyph/property guard on each edge can
reject a window and request a wider one; RTL or emoji content conservatively
rejects short-window reuse.
Substitution, insertion, and deletion fixtures cover repeated ASCII, Latin
ligatures, Arabic joining, mixed Hebrew/Latin, and emoji
ZWJ sequences. Another 36 edit positions sweep the Latin, Arabic, and emoji
fixtures, and 96 deterministic mixed-script edits try to falsify the gates.
The full-window case must match; an accepted short window that
differs from the fresh layout causes the probe to fail.

Build and run from the Exosuit root:

```sh
cmake -S experiments/skribidi_edit_window -B /tmp/exosuit-edit-window-build \
  -DSKRIBIDI_SOURCE="$(realpath ../uikit/vendor/skribidi)" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/exosuit-edit-window-build --target edit_window_probe -j 8
/tmp/exosuit-edit-window-build/edit_window_probe
```

The current fixtures and both sweeps pass: 25 short windows were accepted and
398 were rejected. A four-codepoint window fails the full comparison
on Latin substitution/deletion and Arabic substitution/deletion; the guard
rejects each. After cluster alignment, emoji ZWJ glyphs match at the sampled
positions, but their caret geometry differs, so they fall back. Arabic
windows of 130 codepoints still fail at the left seam and
are rejected. These observations rule out a fixed-size shaping window for
the general path. A mixed Hebrew/Latin window had equal cluster signatures
but different visual order, so the edge guard alone is insufficient. Some
glyph-equivalent Latin/emoji windows changed text properties at their seams;
the property guard rejects those as well. The local layout adds a break after
its artificial final codepoint, so the candidate retains that unchanged
codepoint's cached property. On the 4,096-character `a` fixture, the
candidate's character-wrap breaks match fresh Skribidi at all tested radii.
The gates rejected every sampled mismatching window, but that sample is too
small to establish a general safety rule.

The guard is an experimental rejection check, **not a proof of safe reuse**.
The probe has sampled positions and fonts. It compares one-line caret geometry
and one character-wrap fixture, but does not implement general word wrapping,
incremental row metrics, or indexed storage; candidate assembly still scans
and sorts all old clusters. It does not yet meet the 50 ms edit budget or run
in UIKit. A production design needs indexed cluster/text-property storage,
retained row geometry with a safe fallback, and broader differential coverage.
