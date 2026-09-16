"""Calibration checks for the isolated constant-shift diagnostic, not voice quality."""
import unittest
import tempfile
import wave
from pathlib import Path

import numpy as np
import parselmouth
from parselmouth.praat import call

from fixed_pitch_probe import analyze_source, render_constant, comparison_sequence


class FixedPitchTests(unittest.TestCase):
    def setUp(self):
        self.rate = 22050
        t = np.arange(self.rate)/self.rate
        self.sound = parselmouth.Sound(.2*np.sin(2*np.pi*90*t), sampling_frequency=self.rate)

    def test_constant_offsets_reach_the_tier_and_audio(self):
        for offset in (0, 1, 4.450116003846203):
            with self.subTest(offset=offset):
                m, _ = analyze_source(self.sound, 50)
                result = render_constant(m, offset)
                tier = call(m, 'Extract pitch tier')
                hz = call(tier, 'Get value at time', .5)
                self.assertAlmostEqual(12*np.log2(hz/90), offset, delta=.01)
                f = result.to_pitch_ac(pitch_floor=50, pitch_ceiling=350).selected_array['frequency']
                self.assertAlmostEqual(12*np.log2(np.median(f[f>0])/90), offset, delta=.05)
                self.assertEqual(result.values.shape, self.sound.values.shape)
                self.assertEqual(result.x1, self.sound.x1)
                self.assertTrue(np.isfinite(result.values).all())

    def test_outputs_are_not_identical_across_offsets(self):
        outputs = [render_constant(analyze_source(self.sound, 50)[0], n).values.copy() for n in (0, 1, 4.45)]
        for before, after in zip(outputs, outputs[1:]):
            self.assertFalse(np.array_equal(before, after))

    def test_invalid_offsets_rejected(self):
        for n in (float('nan'), float('inf'), 7):
            with self.assertRaises(AssertionError):
                render_constant(analyze_source(self.sound, 50)[0], n)

    def test_comparison_preserves_every_source_sample(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = []
            for i in range(4):
                path = root/f'{i}.wav'
                with wave.open(str(path), 'wb') as w:
                    w.setparams((1, 2, self.rate, 0, 'NONE', 'not compressed'))
                    w.writeframes(np.arange(i*20, i*20+10, dtype='<i2').tobytes())
                paths.append(path)
            result = comparison_sequence(paths, root/'comparison.wav', self.rate)
            self.assertTrue(result['individualPCMUnchanged'])
            self.assertEqual(len(result['segments']), 4)


if __name__ == '__main__':
    unittest.main()
