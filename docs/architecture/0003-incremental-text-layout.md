# ADR 0003: Indexed edit-range text layout

Status: partially implemented, 2026-10-02. A guarded ASCII reuse path is
active; indexed shared shape storage supports validated ASCII edits, including
changed-wrap reflow without truncation.

## Implemented slice

Skribidi now accepts a bounded lowercase ASCII insertion, deletion, or
replacement when the existing layout has one LTR run, one glyph per codepoint,
and simple glyph positions. It reshapes a 16-codepoint context, verifies
unchanged glyph and text-property guards at both seams, reuses the shaped
prefix and suffix, and publishes one native generation. Validated stable-row
edits retain indexed ranges into immutable shape blocks. Supported full line
reflow also reads those blocks directly; shape-mutating overflow paths still
materialize the arrays. UIKit serves rendering, carets,
hit tests, and selections from that same generation. Unsupported edits use the existing complete-layout path. This
avoids whole-paragraph decoding, itemization, and shaping for the measured
case. Supported edits avoid full shaped-array copies, but row verification,
reflow and row-index copying still cost O(n).

The guarded path can also reuse wrapped row geometry. An equal-length edit
retains it when the local shaped window has identical advances and break
properties; glyph bounds in the local shaping context are recalculated. A
one-letter insertion or deletion in an ASCII word also retains row geometry
when the existing wrap boundaries remain valid under the new glyph advances.
It recalculates glyph bounds only for rows whose glyph IDs or positions change.
Moved wrap boundaries still use full line reflow. The splice repairs cluster
indexes only when a copied span changes its offset. Successful geometry reuse
avoids clearing all glyph origins beforehand; equal-length reuse restores only
the contextual window's origins. A failed geometry guard can reflow directly
from indexed shape data; materialized overflow paths clear shaping-local origins
before complete line reflow. Successful row guards retain indexed shape
pieces instead of materializing full shape arrays. Shifted glyph and cluster
indexes are calculated at read time. Row geometry remains per generation,
and supported full reflow keeps shared shape pieces.

The guarded constructor now returns a new owned generation without mutating
its source. UIKit retains each native generation through a read-only shared
owner that also retains the font collection for native destruction. Legacy
mutable source rebuilds and edits cannot change descendants, and descendants
remain usable after their sources are destroyed. All geometry queries read
one native generation. Indexed snapshots retain shape blocks
directly, including small contextual windows, rather than retaining ancestors.
Legacy rebuilds detach shared buffers before writes. Ellipsis preserves existing
content by copying shared flat buffers before mutation; discarded-content
rebuilds simply release their references. Bulk array getters populate separate
compatibility caches on explicit request. Editor rendering and geometry queries
do not populate those caches.

Whole-line background decorations now query visible row rectangles directly
from UIKit's retained line index. This avoids per-grapheme caret geometry for
the 1 MiB line; other decorations continue to use selection-range geometry.
The edit API locates its UTF-8 byte range with constant extra memory.

Per-visual-row glyph publications now retain revisions across verified edits.
Single-row publication identity does not depend on layout ID, row index, or
absolute source offset. Foreground ranges enter the key relative to their row.
Cache hits republish immutable metadata for the new layout, row index and source
range. Whole-layout Unicode fallback maps unchanged prefix/suffix source ranges
and compares text, runs, fonts, glyphs and row-local geometry before retaining a
revision. Exact geometry comparison conservatively rejects floating-point
cancellation after some fractional row movements.

Frame bindings carry persistent text source identity separately from temporary
prepared-resource slots. Row raster commands canonicalize local vertical
translation; verified whole-pixel movement can reuse the raster while parent
composition moves it. Font/atlas generations and foreground coverage remain
part of validity. The containing pass still recomposites rows. Rebased prepared
snapshots currently copy CPU vectors; this publication reuse does not implement
zero-copy composite text storage.

Haxe ordinary and newline edits use one source-mapped chunk window. Unaffected
chunks keep their existing boundaries. Initial chunks target 64 paragraphs;
local edits may grow one to 128 before splitting the affected window. This keeps
local newlines from redistributing neighboring chunks and keeps subsequent
ordinary typing from reconstructing fixed global chunk groups. Splits still move
some rows between native layouts, and one giant paragraph is not byte-bounded.
Width/style changes retain the full-update boundary.

The guarded ASCII layout builder also carries forward culling and common
glyph bounds for visual rows strictly before an edit, and for rows after an
equal-length edit, when their source range, baseline, and box geometry match.
The fresh-layout differential probe compares those bounds after insertion,
deletion, and replacement. Changed and shifted rows still calculate their
bounds from glyphs.

The real 1 MiB varied-key fixture delivered 30 input frames at p50 37.66 ms,
p95 41.67 ms, and max 43.44 ms, below its 50 ms typing budget. The isolated
native differential probe checks repeated edits, glyphs, line breaks and
sampled carets against fresh layouts. This supports the narrow ASCII path,
not general incremental Unicode layout. Strict changed-row invalidation and
the broader M9.1 acceptance gate remain open.

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

Introduce an edit-range update boundary and a composite native layout in
Skribidi, retained by UIKit. The editor supplies the changed UTF-8 byte range and replacement bytes;
the native side translates it to codepoint boundaries using its indexed text
storage. A composite snapshot owns immutable text/property pieces, shaped
cluster pieces, a visual-row index, and the immutable blocks that back those
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

The first production slice adds `nkui_text_layout_edit` and routes ordinary
same-chunk editor replacements to it with chunk-relative codepoint offsets.
It currently splices the retained UTF-8 text and calls the existing complete
Skribidi layout path. The old full-update path handles chunk repartitioning
and other nonlocal changes. This preserves one authoritative geometry
generation while the composite snapshot is built and verified.

Composite geometry will be owned inside Skribidi, with UIKit retaining the
immutable native generation. Skribidi already implements contextual caret
iteration, hit tests, selections and navigation; retaining that implementation
avoids duplicating those semantics in a second UIKit geometry engine. Rendering
and those queries now read glyphs, clusters and text properties through one
internal indexed boundary. Public value-returning indexed reads serve UIKit's
row equivalence checks, navigation and diagnostics without borrowing array
elements. Line and run geometry remain owned by the same native generation.

The boundary reads either materialized arrays or indexed immutable shape blocks.
Supported ASCII edits use indexed pieces; mutable legacy rebuilds detach from
shared blocks before writes. Changed-wrap reflow reads immutable advances and
publishes positions in row geometry. Truncation retains the materialized path.
The existing bulk array getters
remain compatibility operations, and the UIKit text engine no longer uses them
for text, properties, glyphs or clusters. Do not activate pieces through only
the glyph-render path or retain a complete previous layout for each row.

## Shared storage implementation boundary

Shape blocks own decoded codepoints, text properties, glyphs and clusters.
An indexed ASCII snapshot holds retained ranges into those blocks rather than
retaining complete ancestor layouts. Adjacent ranges into the same block
coalesce. Mutable legacy rebuilds detach shared buffers before writing;
reference counts release blocks when no snapshot needs them. The validated
one-glyph-per-codepoint case rebases logical cluster indexes during reads.

Row geometry remains per generation. Unchanged advances or verified stable
wrap boundaries reuse geometry. Changed wrapping now uses the existing line
builder with indexed cluster/property/advance reads; it does not write
positions into retained glyph blocks. Shape-mutating overflow modes still
materialize before invoking that builder.
Unsupported Unicode continues through full layout. Indexed glyph positions
come from the snapshot's row index and advances, not a previous generation's
absolute glyph origins. Bulk array compatibility reads may populate a separate
cache; rendering and geometry must not request that cache. Differential tests
must prove both answers and absence of full shape arrays on indexed queries.
This does not implement bounded pending-row reflow or complete M9.1.
For the guarded lowercase ASCII, left-aligned character-wrapping case, snapshot
installation records shape and row eligibility. Edits reuse that immutable
metadata instead of rescanning the original paragraph. Reflow starts at the
first affected row and can reuse a suffix when its source boundary and row
number recover. Matching row numbers preserve exact vertical geometry; a row
count shift currently continues reflow through the remaining tail. Lookahead
is limited to a small multiple of the row width on this path.

Unchanged row and run metadata are still copied into each generation, and final
alignment/publication still visit rows. Reflow counters measure wrapping work,
not total edit work. Sharing row metadata and bounding pending-row reflow and
publication remain open.

Row and layout-run value reads now have the same indexed boundary as shape
reads. UIKit uses `skb_layout_get_line_at` and
`skb_layout_get_layout_run_at` for intrinsic metrics, layout publication and
row equivalence, rather than borrowing complete arrays. Skribidi editor
navigation and rich-layout hit testing use indexed rows as well. The bulk
getters remain compatibility APIs. This migration does not yet share row
storage: the builder and internal native geometry queries still use owned
contiguous rows. Move those internal readers behind the boundary before
installing retained row blocks, so caret, selection, culling and rendering
cannot silently force whole-row materialization.

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

The original probe timings cover only local shaping, piece splicing, and index
access. The later real-window benchmark above includes UIKit dispatch,
rendering, and publication for the guarded ASCII case. General incremental
Unicode geometry and changed-row publication remain open.
