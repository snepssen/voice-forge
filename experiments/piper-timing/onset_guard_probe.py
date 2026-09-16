#!/usr/bin/env python3
"""Protect the consonant/onset in the saved original-duration pitch diagnostic.

Fixed-clip ablation: reuse the existing constant-shift output, preserving dry
samples through 1.390s and crossfading to it by 1.410s. Not a general consonant
detector. The protected interval includes some vowel onset deliberately.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import parselmouth

from fixed_pitch_probe import SOURCE_HASH, comparison_sequence
from pitch_contour import write_wav
from resynthesis_probe import assess_pitch


def onset_mask(count, rate, start=1.390, fade=.020):
    assert count > 0 and rate > 0 and 0 <= start < start+fade <= count/rate
    t = np.arange(count)/rate
    u = np.clip((t-start)/fade, 0, 1)
    return .5-.5*np.cos(np.pi*u)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input_manifest', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    prior = json.loads(a.input_manifest.read_text())
    source = Path(prior['source'])
    original = source.read_bytes()
    assert hashlib.sha256(original).hexdigest() == prior['sourceSHA256'] == SOURCE_HASH
    s = parselmouth.Sound(str(source))
    x = s.values[0]
    rate = int(s.sampling_frequency)
    assert s.n_channels == 1 and len(x) == 40704 and rate == 22050
    mask = onset_mask(len(x), rate)
    a.output.mkdir(parents=True, exist_ok=False)
    with (a.output/'dry.wav').open('xb') as f:
        f.write(original)
    rows = []
    candidates = [r for r in prior['clips'] if r['floorHz'] == 50]
    assert [r['shiftSemitones'] for r in candidates] == [0, 1, 4.450116003846203]
    for row in candidates:
        path = Path(row['path'])
        assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256']
        old_sound = parselmouth.Sound(str(path))
        assert old_sound.values.shape == s.values.shape and old_sound.sampling_frequency == rate
        old = old_sound.values[0]
        output = x + mask*(old-x)
        target = a.output/f"guard-shift-{row['shiftSemitones']:.2f}.wav"
        write_wav(target, output, rate)
        decoded = parselmouth.Sound(str(target)).values[0]
        assert np.array_equal(decoded[mask == 0], x[mask == 0])
        assert np.array_equal(decoded[mask == 1], old[mask == 1])
        core = [('later-vowel', 1.42, 1.48)]
        evidence = assess_pitch(source, target, core, lambda _: row['shiftSemitones'])
        measurement = evidence['regions'][0]
        eligible = measurement['pitchEvidenceConsistent'] and abs(measurement['medianResidualSemitones']) <= .35
        rows.append({'path': str(target.resolve()),
                     'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                     'inputPath': str(path), 'inputSHA256': row['sha256'],
                     'shiftSemitones': row['shiftSemitones'], 'sampleCount': len(decoded),
                     'prefixIdenticalToDry': True, 'laterAudioIdenticalToPrior': True,
                     'peakDBFS': float(20*np.log10(np.max(np.abs(decoded)))),
                     'pitchEvidence': evidence, 'fixedShiftEvidenceConsistent': eligible})
    report = {'inputManifest': str(a.input_manifest.resolve()), 'sourceSHA256': SOURCE_HASH,
              'sampleRate': rate, 'dryThroughSeconds': 1.390, 'fullyProcessedFromSeconds': 1.410,
              'crossfadeSeconds': .020, 'clips': rows, 'listenerApproval': False,
              'limitations': [
                  'Manual guard for this exact source; includes vowel onset, not an exact t boundary.',
                  'Retains existing renderer output and shift magnitude; no pitch re-analysis or synthesis.',
                  'New crossfade may itself introduce an audible transition and needs listening.',
                  'A clean result would implicate the protected region, not prove the precise crackle mechanism.',
              ]}
    if all(r['fixedShiftEvidenceConsistent'] for r in rows):
        report['comparison'] = comparison_sequence([a.output/'dry.wav']+[Path(r['path']) for r in rows],
                                                   a.output/'comparison.wav', rate)
    assert hashlib.sha256(source.read_bytes()).hexdigest() == SOURCE_HASH
    with (a.output/'manifest.json').open('x') as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
