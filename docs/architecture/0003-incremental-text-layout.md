# ADR 0003: Indexed edit-range text layout

Status: proposed, 2026-10-01.

## Context

UIKit currently stores one `skb_layout_t` in each `TextEngine::RetainedLayout`.
`layout_utf8` rebuilds that object after a text change, and the renderer,
caret, hit-test, selection, and line APIs all read it. On the real 1 MiB
single-line typing fixture, varied-key input measured p95 292.04 ms against
the 50 ms budget. Native phase measurements put median decoding/properties at
41.5 ms, itemization at 16.4 ms, shaping/clusters at 122.3 ms, and line layout
at 12.0 ms. Whole-paragraph work must leave the foreground edit path.

The Haxe editor already knows the edit range:
`TextEditorLayout.setTextAfterEdit` receives old and new document offsets.
When a chunk changes, it currently calls `record.layout.update` with the
entire chunk, which reaches `nkui_text_layout_update` and rebuilds the one
native layout. The new native edit call can receive chunk-relative offsets
from that existing path; it does not need to rediscover a diff.

The isolated `experiments/skribidi_edit_window/` probe retains old shaped
cluster and text-property pieces, shapes a small changed window, and compares
their composition against fresh Skribidi layouts. In a 1 MiB repeated-`a`
fixture, 30 consecutive varied replacements matched fresh cluster and
property streams after every edit and matched final character-wrap breaks.
Thirty alternating insertions/deletions also matched after every edit,
including shifted suffix offsets. A 12-row visible reflow visited 288 clusters
among 43,691 wrapped rows and matched the fresh break ranges.
This establishes a narrow candidate for reuse, not product acceptance.
Latin ligature seams sometimes require a wider window; Arabic joining can
reject even 130 codepoints of context. Mixed bidi can change visual order
without changing cluster glyphs. Emoji windows can change caret geometry.

## Decision

Introduce an edit-range update boundary and a composite retained layout in
UIKit. The editor supplies the changed UTF-8 byte range and replacement bytes;
the native side translates it to codepoint boundaries using its indexed text
storage. A composite snapshot owns immutable text/property pieces, shaped
cluster pieces, a visual-row index, and the Skribidi layouts that back those
pieces. All rendering and geometry methods read the same snapshot generation.

An edit first splices the text and shapes a contextual window. The fast path
aligns window edges to old cluster boundaries and checks unchanged glyph and
text-property guards on both sides. It applies only when the old paragraph and
new window satisfy the validated LTR, non-emoji case. A failed guard or an
unsupported script/direction uses the complete Skribidi layout path. The
last unchanged codepoint at an artificial local-layout end keeps its cached
property; the local end-of-input break must not enter the document snapshot.

The row index reflows from the row before the edit and exposes affected visible
rows before processing the distant suffix. It carries exact cluster-to-text
offsets, line metrics, and caret/hit-test geometry for every published row.
Glyph snapshots retain their piece layouts and atlas generations so a later
edit cannot invalidate geometry already bound to a frame. Queries for a row
whose geometry is pending finish that row's reflow before returning. Cached
suffix rows are reused only when their text ranges and geometry converge
under the edit's offset shift.

The current `nkui_text_layout_set_text` and `nkui_text_layout_update` entry
points remain valid full-layout operations. An explicit edit-range API carries
the new fast path; guessing the edit range by comparing two 1 MiB strings
would put an unbounded scan back on every keypress. `TextEngine` dispatches
rendering, caret, hit-test, selection, and line-range requests through the
composite snapshot rather than directly through one `skb_layout_t`.

## Verification before activation

1. Extend the one-codepoint replacement/insertion/deletion and repeated-edit
   harness to mutable multi-codepoint clusters and contextual scripts.
2. Compare visible row breaks, line metrics, glyph positions, both caret
   affinities, hit tests, and selections against fresh Skribidi layouts across
   Latin, combining marks, ligatures, emoji, Arabic, and mixed bidi text.
3. Verify immutable snapshot lifetime and atlas generation behavior through
   the UIKit renderer tests and the real decoration window.
4. Enable the fast path on the real varied-key 1 MiB fixture only after those
   checks pass. Measure delivered input frames, p50/p95 and fallback rate;
   accept M9.1's typing budget only when p95 is below 50 ms.

The current probe timings cover only local shaping, piece splicing, and index
access. They exclude row geometry, UIKit event dispatch, rendering, and
publication. The 50 ms goal remains open.
