import unittest

import numpy as np

from onset_guard_probe import onset_mask


class OnsetGuardTests(unittest.TestCase):
    def test_prefix_transition_and_suffix(self):
        mask = onset_mask(2000, 1000, 1.390, .020)
        self.assertTrue(np.all(mask[:1391] == 0))
        self.assertTrue(np.all(mask[1410:] == 1))
        self.assertTrue(np.all(np.diff(mask) >= 0))
        self.assertAlmostEqual(mask[1400], .5)

    def test_mixing_keeps_both_protected_sides_exact(self):
        mask = onset_mask(2000, 1000, 1.390, .020)
        dry = np.arange(2000, dtype=np.float64)/10000
        wet = -dry
        result = dry + mask*(wet-dry)
        np.testing.assert_array_equal(result[mask == 0], dry[mask == 0])
        np.testing.assert_array_equal(result[mask == 1], wet[mask == 1])

    def test_rejects_invalid_windows(self):
        for start, fade in [(-1, .02), (1, 0), (1, -.1), (1.99, .02)]:
            with self.assertRaises(AssertionError):
                onset_mask(2000, 1000, start, fade)


if __name__ == '__main__':
    unittest.main()
