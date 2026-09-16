#!/usr/bin/env python3
"""Measure paired speech F0 with two Praat estimators; never infer quality from F0.
Usage: python pitch_report.py REFERENCE.wav CANDIDATE.wav NEW_REPORT.json
Requires praat-parselmouth and numpy in the isolated experiment environment.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import parselmouth


def analyze(path):
    sound = parselmouth.Sound(str(path))
    kwargs = dict(time_step=0.005, pitch_floor=40, pitch_ceiling=350)
    ac, cc = sound.to_pitch_ac(**kwargs), sound.to_pitch_cc(**kwargs)
    times = ac.xs()
    ac_hz = ac.selected_array['frequency']
    cc_hz = np.array([cc.get_value_at_time(float(t)) for t in times])
    rms = []
    for t in times:
        start = max(0, int((t - 0.01) * sound.sampling_frequency))
        end = min(sound.n_samples, int((t + 0.01) * sound.sampling_frequency))
        rms.append(20 * np.log10(max(1e-10, float(np.sqrt(np.mean(sound.values[0, start:end] ** 2))))))
    valid = (ac_hz > 0) & (cc_hz > 0) & np.isfinite(cc_hz)
    agreement = np.full_like(ac_hz, np.inf)
    agreement[valid] = np.abs(12 * np.log2(ac_hz[valid] / cc_hz[valid]))
    reliable = valid & (agreement < 1.0) & (np.array(rms) > -40)
    return sound, times, ac_hz, reliable, np.array(rms)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--expect-voiced-rise', action='store_true',
                        help='Check the fixed revised fixture; this does not certify perceived quality')
    args = parser.parse_args()
    a, t, f0, good, energy = analyze(args.reference)
    b, tb, f1, good1, energy1 = analyze(args.candidate)
    assert a.n_samples == b.n_samples and a.sampling_frequency == b.sampling_frequency
    assert np.array_equal(t, tb)
    both = good & good1
    shift = np.zeros_like(f0)
    shift[both] = 12 * np.log2(f1[both] / f0[both])
    windows = []
    for name, lo, hi in [('first-lift', 1.40, 1.48), ('dip', 1.50, 1.57),
                         ('final-voiced-rise', 1.60, 1.665), ('old-second-peak', 1.75, 1.82)]:
        sel = (t >= lo) & (t <= hi) & both
        windows.append({'region': name, 'start': lo, 'end': hi,
                        'pairedReliableFrames': int(sel.sum()),
                        'medianShiftSemitones': float(np.median(shift[sel])) if sel.any() else None,
                        'referenceMedianHz': float(np.median(f0[sel])) if sel.any() else None,
                        'candidateMedianHz': float(np.median(f1[sel])) if sel.any() else None})
    if args.expect_voiced_rise:
        assert hashlib.sha256(args.reference.read_bytes()).hexdigest() == '37b5f22bce3b6ffa8216cde76bd79db9b32c749aebfabcb480c5802669e7184d'
        for index in [0, 2]:
            assert windows[index]['pairedReliableFrames'] >= 5, 'Insufficient paired voiced frames'
            assert 3.5 <= windows[index]['medianShiftSemitones'] <= 5.5, 'Lift missed the voiced region'
        assert windows[1]['pairedReliableFrames'] >= 5
        assert windows[1]['medianShiftSemitones'] < 0.75, 'No relative drop between lifts'
    report = {'reference': str(args.reference), 'candidate': str(args.candidate),
              'referenceSHA256': hashlib.sha256(args.reference.read_bytes()).hexdigest(),
              'candidateSHA256': hashlib.sha256(args.candidate.read_bytes()).hexdigest(),
              'parselmouthVersion': parselmouth.__version__,
              'voicedRiseRegressionChecked': args.expect_voiced_rise,
              'method': 'Praat AC and CC, 40–350 Hz, 5ms step; agreement within 1 semitone and RMS above -40dBFS',
              'windows': windows,
              'frames': [{'time': float(t[i]), 'referenceHz': float(f0[i]) if good[i] else None,
                          'candidateHz': float(f1[i]) if good1[i] else None,
                          'shiftSemitones': float(shift[i]) if both[i] else None,
                          'referenceRMSDBFS': float(energy[i]), 'candidateRMSDBFS': float(energy1[i])}
                         for i in range(len(t)) if t[i] >= 1.2],
              'limitations': ['Pitch estimators can agree on the wrong octave; these are estimates.',
                              'Time windows are manually inspected regions, not confirmed word boundaries.',
                              'No estimator establishes naturalness or perceived emotion.']}
    with args.output.open('x') as out:
        json.dump(report, out, indent=2)
    print(json.dumps(windows, indent=2))


if __name__ == '__main__':
    main()
