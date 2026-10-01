"""Isolated, character-wrap prototype over already shaped cluster advances.

The caller supplies *correctly shaped* clusters. This experiment deliberately
does not decide which shaping spans can be reused after a text edit.
"""

from dataclasses import dataclass
from typing import Iterator, Sequence


@dataclass(frozen=True)
class Cluster:
    text: str
    advance: float


@dataclass(frozen=True)
class Row:
    start: int
    end: int


def rows(clusters: Sequence[Cluster], width: float, start: int = 0) -> Iterator[Row]:
    if width <= 0:
        raise ValueError("width must be positive")
    pos = start
    while pos < len(clusters):
        end = pos
        used = 0.0
        while end < len(clusters):
            advance = clusters[end].advance
            if advance < 0:
                raise ValueError("negative cluster advance")
            if end > pos and used + advance > width:
                break
            used += advance
            end += 1
        yield Row(pos, end)
        pos = end
    if start == 0 and not clusters:
        yield Row(0, 0)


def full_wrap(clusters: Sequence[Cluster], width: float) -> list[Row]:
    return list(rows(clusters, width))


def begin_edit(
    old_rows: Sequence[Row],
    new_clusters: Sequence[Cluster],
    width: float,
    edited_cluster: int,
) -> tuple[int, Iterator[Row]]:
    """Return retained-prefix length and lazy rows beginning near the edit.

    The caller can read visible changed rows before processing the suffix.
    It must provide shaping for the new clusters before calling this.
    """
    if not 0 <= edited_cluster <= len(new_clusters):
        raise ValueError("edit outside new clusters")
    low, high = 0, len(old_rows)
    while low < high:
        middle = (low + high) // 2
        if old_rows[middle].end <= edited_cluster:
            low = middle + 1
        else:
            high = middle
    # Deleting at a row boundary can pull the next cluster into the prior row.
    first = max(0, min(low, len(old_rows) - 1) - 1)
    return first, rows(new_clusters, width, old_rows[first].start if old_rows else 0)


def edit_rows(
    old_rows: Sequence[Row],
    new_clusters: Sequence[Cluster],
    width: float,
    edited_cluster: int,
) -> Iterator[Row]:
    prefix_count, changed = begin_edit(old_rows, new_clusters, width, edited_cluster)
    yield from old_rows[:prefix_count]
    yield from changed
