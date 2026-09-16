#!/usr/bin/env python3
"""Isolate one word region from the existing R7 TD-PSOLA diagnostic.

No new rendering or stronger pitch instruction. Preserve the dry source outside
the approximate ASR word window; crossfade inside its edges for 15 ms. This is
a fixed-clip localization test, not a general word aligner or prosody preset.

Listener verdict for the stole fixture: rejected as stretched and lightly
crackling, with high/low static embedded in the word. Not for app integration.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import parselmouth

from pitch_contour import smooth_curve, write_wav
from resynthesis_probe import assess_pitch
from voice_integrity import summarize


def region_mask(count, rate, start, end, fade=.015):
    assert 0 <= start < end <= count/rate
    assert 0 < fade <= (end-start)/2
    t = np.arange(count)/rate
    ramp = np.minimum(np.clip((t-start)/fade, 0, 1),
                      np.clip((end-t)/fade, 0, 1))
    return .5-.5*np.cos(np.pi*ramp)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('probe_manifest', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--word', choices=['you', 'stole', 'it'], default='stole')
    a = p.parse_args()
    probe = json.loads(a.probe_manifest.read_text())
    transfer = json.loads(Path(probe['inputManifest']).read_text())
    target = next(r for r in transfer['wordTargets'] if r['word'] == a.word)
    clips = {}
    for name in ('dry', 'neutral', 'pitch-shifted'):
        row = probe['paths'][name]
        path = Path(row['file'])
        assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256']
        sound = parselmouth.Sound(str(path))
        assert sound.n_channels == 1 and sound.n_samples == probe['sampleCount']
        assert sound.sampling_frequency == probe['sampleRate']
        clips[name] = sound.values[0]
    dry = clips['dry']
    rate = probe['sampleRate']
    mask = region_mask(len(dry), rate, *target['sourceASRWindow'])
    a.output.mkdir(parents=True, exist_ok=False)
    reports = {}
    regions = [(a.word, *target['sourceVoicedWindow'])]
    for name in ('neutral', 'pitch-shifted'):
        result = dry + mask*(clips[name]-dry)
        path = a.output/f'{a.word}-{name}.wav'
        write_wav(path, result, rate)
        decoded = parselmouth.Sound(str(path)).values[0]
        assert np.array_equal(decoded[mask == 0], dry[mask == 0])
        assert len(decoded) == len(dry) and np.isfinite(decoded).all()
        curve = (lambda _: 0) if name == 'neutral' else smooth_curve(probe['semitoneOffsetPoints'])
        reports[name] = {
            'path': str(path.resolve()),
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'regions': summarize(decoded, rate, regions),
            'pitchEvidence': assess_pitch(probe['paths']['dry']['file'], path, regions, curve),
            'protectedSamplesIdentical': True,
            'peakDBFS': float(20*np.log10(np.max(np.abs(decoded)))),
        }
    report = {
        'inputManifest': str(a.probe_manifest.resolve()), 'word': a.word,
        'source': probe['source'], 'sampleCount': len(dry), 'sampleRate': rate,
        'processingWindow': target['sourceASRWindow'], 'fadeSeconds': .015,
        'paths': reports, 'listenerApproval': False,
        'limitations': [
            'Approximate ASR region, not forced phonetic alignment.',
            'Reuses the earlier full-phrase renderer output within this region.',
            'Localized neutral control must be judged separately if a boundary artifact is heard.',
            'Pitch evidence is not naturalness, vocal-body or emotion approval.',
        ],
    }
    with (a.output/'manifest.json').open('x') as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
