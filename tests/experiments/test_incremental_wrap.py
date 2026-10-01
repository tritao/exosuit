import random
import unittest

from experiments.incremental_wrap import Cluster, Row, begin_edit, edit_rows, full_wrap


class IncrementalWrapTest(unittest.TestCase):
    def check_edit(self, before, start, delete, inserted, width):
        after = before[:start] + inserted + before[start + delete :]
        old = full_wrap(before, width)
        actual = list(edit_rows(old, after, width, start))
        self.assertEqual(actual, full_wrap(after, width))

    def test_contextual_cluster_boundaries(self):
        # Ligature, emoji ZWJ sequence, and Arabic joining are supplied as
        # indivisible shaped clusters; no text byte boundary is assumed.
        before = [
            Cluster("office", 5),
            Cluster("fi", 1.3),
            Cluster("👩‍💻", 2),
            Cluster("لام", 2.7),
            Cluster("x", 1),
        ]
        self.check_edit(before, 2, 1, [Cluster("👨‍👩‍👧", 2.2)], 4)
        self.check_edit(before, 1, 2, [], 4)

    def test_edit_at_row_boundary_and_oversize_cluster(self):
        before = [Cluster("a", 1)] * 30
        self.check_edit(before, 10, 0, [Cluster("W", 7)], 5)
        self.check_edit(before, 10, 10, [], 5)

    def test_visible_rows_are_yielded_before_suffix(self):
        before = [Cluster("a", 1)] * 1_000_000
        old = full_wrap(before, 80)
        after = before[:80] + [Cluster("a", 1)] + before[80:]
        stream = edit_rows(old, after, 80, 80)
        self.assertEqual(next(stream), Row(0, 80))
        self.assertEqual(next(stream), Row(80, 160))
        self.assertEqual(next(stream), Row(160, 240))
        self.assertEqual(list(stream)[-1], full_wrap(after, 80)[-1])

        deep_edit = 500_000
        deep_after = before[:deep_edit] + [Cluster("a", 1)] + before[deep_edit:]
        prefix_count, changed = begin_edit(old, deep_after, 80, deep_edit)
        self.assertGreater(prefix_count, 6000)
        self.assertLessEqual(next(changed).start, deep_edit)

    def test_random_differential_edits(self):
        randomizer = random.Random(811)
        choices = [Cluster("a", 1), Cluster("W", 2.4), Cluster("fi", 1.2), Cluster("🙂", 2)]
        for _ in range(200):
            before = [randomizer.choice(choices) for _ in range(randomizer.randrange(1, 200))]
            start = randomizer.randrange(len(before) + 1)
            delete = randomizer.randrange(min(8, len(before) - start) + 1)
            inserted = [randomizer.choice(choices) for _ in range(randomizer.randrange(8))]
            self.check_edit(before, start, delete, inserted, randomizer.uniform(2, 20))


if __name__ == "__main__":
    unittest.main()
