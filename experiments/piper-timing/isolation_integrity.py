#!/usr/bin/env python3
"""Check rejected word isolation for added time, sample clipping and splice scope.

Read-only audio diagnosis. No new audition and no perceptual-quality score.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import parselmouth

from word_isolation import region_mask


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('isolation_manifest', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    isolated = json.loads(a.isolation_manifest.read_text())
    probe = json.loads(Path(isolated['inputManifest']).read_text())
    clips = {}
    paths = {}
    for label, row in [('dry', probe['paths']['dry']),
                       ('full-shift', probe['paths']['pitch-shifted']),
                       ('isolated-shift', isolated['paths']['pitch-shifted'])]:
        path = Path(row.get('file', row.get('path')))
        assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256']
        sound = parselmouth.Sound(str(path))
        assert sound.n_channels == 1
        assert sound.n_samples == isolated['sampleCount']
        assert sound.sampling_frequency == isolated['sampleRate']
        clips[label] = sound.values[0]
        paths[label] = {'path': str(path), 'sha256': row['sha256']}
    rate = isolated['sampleRate']
    mask = region_mask(isolated['sampleCount'], rate,
                       *isolated['processingWindow'], isolated['fadeSeconds'])
    dry, full, selected = (clips[k] for k in ('dry', 'full-shift', 'isolated-shift'))
    assert np.array_equal(selected[mask == 0], dry[mask == 0])
    assert np.array_equal(selected[mask == 1], full[mask == 1])
    start, end = isolated['processingWindow']
    fade = isolated['fadeSeconds']
    report = {
        'inputs': paths, 'sampleCount': len(dry), 'sampleRate': rate,
        'addedSamples': len(selected)-len(dry),
        'middleIntervalSeconds': [start+fade, end-fade],
        'middleMatchesPriorShiftExactly': True,
        'outsideWindowMatchesDryExactly': True,
        'partiallyMixedSamples': int(np.sum((mask > 0) & (mask < 1))),
        'signals': {label: {'peakDBFS': float(20*np.log10(np.max(np.abs(x)))),
                            'samplesAtPCM16Rail': int(np.sum((x >= 32767/32768) | (x <= -1)))}
                    for label, x in clips.items()},
        'limitations': [
            'No added samples does not rule out perceived stretching or local time redistribution.',
            'Absence of sample clipping does not rule out resynthesis distortion.',
            'Interior equality excludes new splice changes there, not audible edge artifacts.',
            'This check does not identify the mechanism of the reported crackle.',
        ],
    }
    with a.output.open('x') as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
