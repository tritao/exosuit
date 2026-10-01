# Incremental layout experiment

`incremental_wrap.py` isolates the row-reflow half of an incremental layout.
It accepts already shaped, indivisible clusters and an edited cluster index.
`begin_edit` finds the affected row with a binary search, backs up one row so
deletions at a wrap boundary can pull text left, and yields new rows lazily.
The caller can publish rows near the edit before consuming the suffix.

Run `python3 -m unittest discover -s tests/experiments -v` from the Exosuit
root. Differential tests compare the incremental result with a complete wrap
over the same shaped clusters, including varied widths, long lines, ligatures,
emoji, Arabic, row-boundary edits, and randomized edits.

This is **not** a UIKit or Skribidi implementation. It does not shape text,
prove that cached clusters survive an edit, implement word or bidirectional
line breaks, or converge with a cached suffix. Its synthetic cluster widths
do not establish equivalence with Skribidi. Those are required before the
production path or the 50 ms typing budget can be claimed.
