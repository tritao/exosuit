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
./scripts/test-skribidi-layout.sh # required in composed CI

# Or build the probe directly:
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

Cluster and text-property candidates now use indexed references to old and
new layouts. Constructing a candidate no longer copies or sorts all cached
clusters. A 1 MiB smoke check makes three cluster pieces and four property
pieces; 100,000 paired random lookups took about 3 ms of CPU time on the
recorded host. A mutable fixture then applies 30 varied letter replacements
to both 4,096-codepoint and 1 MiB lines. Every resulting cluster and text
property stream matches a fresh Skribidi layout, and the final 1 MiB
character-wrap breaks match. For the 1 MiB fixture, the isolated nine-codepoint
shape plus piece splice measured p50/p95 about 0.03/0.03 ms CPU. Fresh full
layouts used for verification are excluded from that timing.

A second 30-edit fixture alternates insertion and deletion at the same caret.
Both the 4,096-codepoint and 1 MiB versions match fresh clusters and
properties after every edit, including shifted suffix offsets; the final
1 MiB character-wrap breaks match. The isolated 1 MiB text copy, shape and
splice measured p50/p95 about 0.10/0.12 ms CPU. A visible-row check starts
one row before a 1 MiB replacement, visits 288 clusters to generate 12 rows,
and matches fresh Skribidi break ranges among 43,691 total rows.

The guard is an experimental rejection check, **not a proof of safe reuse**.
The probe has sampled positions and fonts. It compares one-line caret geometry
and one character-wrap fixture, but does not implement general word wrapping,
incremental row metrics, or general mutable cluster edits: the current mutable
cluster splice covers one-codepoint clusters for replacement, insertion, and
deletion. The visible-row check covers an unbroken ASCII word, not general
word wrapping or changed line heights.
Oracle checks and glyph-position reconstruction still scan old layouts. The
measured path excludes UIKit event handling, row layout, rendering, and
publication, so those isolated timings do not establish the 50 ms typing budget.

## Production native snapshot regressions

The probe also exercises Skribidi's guarded native edit API. Supported ASCII
edits retain immutable shape blocks through indexed ranges, including edits
that change wrap boundaries. Reflow reads shared advances and stores positions
in row geometry. Truncation and other shape-mutating cases still materialize;
unsupported scripts use full layout.
Rendering and geometry read the same generation. These native checks are
separate from the experimental piece-splice timings above.

Repeated 4,096- and 1 MiB-codepoint fixtures compare accepted native edits with
fresh layouts, including cluster metadata, glyph positions, culling bounds and
sampled carets. The variable-advance sweep includes accepted edits and rejection.
A retained-generation fixture verifies source independence across subsequent
mutations and source destruction.

Two further sequences of 100 dispersed edits test shared production storage,
including variable-width replacements, insertions and deletions that move wrap
boundaries. Every generation
matches fresh codepoints, properties, glyphs, clusters, both caret affinities,
hit tests, selection rectangles, render callbacks and row bounds. The test checks
that unchanged prefixes retain the actual source block, and that geometry reads
leave all four bulk compatibility caches empty. Original-source ellipsis and
rebuild operations preserve descendants, which survive source destruction.
Explicit bulk array calls remain supported afterward.

Set `SKB_NATIVE_ONLY=1` to run the small native/lifetime fixtures without the
large contextual-script sweeps. The native subset is also run under AddressSanitizer
with leak detection. Real-window typing measurements and acceptance limits are
recorded in `docs/roadmap/STATUS.md`; shared shapes alone do not remove paragraph
scans, full row-index copying or general Unicode shaping.
