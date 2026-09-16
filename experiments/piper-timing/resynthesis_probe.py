#!/usr/bin/env python3
"""Compare Praat TD-PSOLA with the rejected R7 pitch-processing path.

Same source, pitch instructions, duration and outer wet/dry mask. No new TTS,
EQ, gain matching or model edits. The neutral control is actually resynthesized,
not bypassed. Signal checks cannot establish perceptual quality.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import parselmouth
from parselmouth.praat import call

from pitch_contour import smooth_curve, write_wav
from pitch_report import analyze
from voice_integrity import summarize


def assess_pitch(source, candidate, regions, envelope):
    """Retain raw octave disagreements; never fold them to fit the instruction."""
    _, times, before, source_good, _ = analyze(source)
    _, target_times, after, target_good, _ = analyze(candidate)
    assert np.array_equal(times, target_times)
    rows = []
    for word, lo, hi in regions:
        available = (times >= lo) & (times <= hi) & source_good
        paired = available & target_good
        count, source_count = int(paired.sum()), int(available.sum())
        actual = 12*np.log2(after[paired]/before[paired])
        expected = np.array([envelope(t) for t in times[paired]])
        residual = float(np.median(actual-expected)) if count else None
        sufficient = count >= 5 and count >= source_count*.5
        rows.append({'word': word, 'sourceReliableFrames': source_count,
                     'pairedReliableFrames': count,
                     'medianMeasuredShiftSemitones': float(np.median(actual)) if count else None,
                     'medianExpectedShiftSemitones': float(np.median(expected)) if count else None,
                     'medianResidualSemitones': residual,
                     'pitchEvidenceConsistent': sufficient and abs(residual) <= 1.5})
    return {'regions': rows, 'allWordsConsistent': all(r['pitchEvidenceConsistent'] for r in rows),
            'limitation': 'Two agreeing estimators can still share an octave error. This is not a quality score.'}


def render(sound, envelope):
    manipulation = call(sound, 'To Manipulation', .005, 50, 350)
    original = call(manipulation, 'Extract pitch tier')
    tier = call('Create PitchTier', 'reference-probe', sound.xmin, sound.xmax)
    rows = []
    for i in range(1, call(original, 'Get number of points') + 1):
        time = call(original, 'Get time from index', i)
        frequency = call(original, 'Get value at index', i)
        offset = envelope(time)
        assert np.isfinite(offset) and abs(offset) <= 6
        target = frequency * 2 ** (offset / 12)
        call(tier, 'Add point', time, target)
        rows.append({'time': time, 'sourceHz': frequency, 'targetHz': target,
                     'semitones': offset})
    call([tier, manipulation], 'Replace pitch tier')
    output = call(manipulation, 'Get resynthesis (overlap-add)')
    assert output.sampling_frequency == sound.sampling_frequency
    assert output.x1 == sound.x1 and output.values.shape == sound.values.shape
    return output.values[0].copy(), rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    source = Path(manifest['synthetic']['path'])
    source_bytes = source.read_bytes()
    assert hashlib.sha256(source_bytes).hexdigest() == manifest['synthetic']['sha256']
    sound = parselmouth.Sound(str(source))
    assert sound.n_channels == 1
    rate = int(sound.sampling_frequency)
    x = sound.values[0]
    points = manifest['semitoneOffsetPoints']
    envelope = smooth_curve(points)
    times = np.arange(len(x)) / rate
    wet = np.minimum(np.clip((times-points[1][0])/.03, 0, 1),
                     np.clip((points[-2][0]-times)/.03, 0, 1))
    wet = .5-.5*np.cos(np.pi*wet)
    regions = [(r['word'], *r['sourceVoicedWindow']) for r in manifest['wordTargets']]
    clips = {'dry': x}
    tiers = {}
    for name, curve in [('neutral', lambda _: 0), ('pitch-shifted', envelope)]:
        processed, tiers[name] = render(sound, curve)
        clips[name] = x + wet * (processed-x)
        assert len(clips[name]) == len(x) and np.isfinite(clips[name]).all()
        assert np.array_equal(clips[name][wet == 0], x[wet == 0])
        assert np.max(np.abs(clips[name])) < .98
    # Equal weighting on the protected dry regions must survive WAV quantization.
    for data in clips.values():
        assert np.array_equal(np.rint(data[wet == 0]*32768),
                              np.rint(x[wet == 0]*32768))
    assert all(r['sourceHz'] == r['targetHz'] for r in tiers['neutral'])
    args.output.mkdir(parents=True, exist_ok=False)
    with (args.output/'dry.wav').open('xb') as f:
        f.write(source_bytes)
    for name in ('neutral', 'pitch-shifted'):
        write_wav(args.output/f'{name}.wav', clips[name], rate)
    report = {
        'source': manifest['synthetic'], 'inputManifest': str(args.manifest.resolve()),
        'renderer': 'Praat TD-PSOLA via praat-parselmouth',
        'parselmouthVersion': parselmouth.__version__,
        'praatVersion': parselmouth.PRAAT_VERSION,
        'analysis': {'stepSeconds': .005, 'pitchFloorHz': 50, 'pitchCeilingHz': 350},
        'semitoneOffsetPoints': points, 'pitchTiers': tiers,
        'sampleRate': rate, 'sampleCount': len(x),
        'paths': {name: {'file': str((args.output/f'{name}.wav').resolve()),
                         'sha256': hashlib.sha256((args.output/f'{name}.wav').read_bytes()).hexdigest(),
                         'regions': summarize(data, rate, regions),
                         'peakDBFS': float(20*np.log10(np.max(np.abs(data)))),
                         'correlationWithDry': float(np.corrcoef(x, data)[0, 1]),
                         'rmsErrorAgainstDry': float(np.sqrt(np.mean((data-x)**2)))}
                  for name, data in clips.items()},
        'pitchEvidence': {
            name: assess_pitch(source, args.output/f'{name}.wav', regions, curve)
            for name, curve in [('neutral', lambda _: 0), ('pitch-shifted', envelope)]},
        'listenerApproval': False,
        'limitations': [
            'Not a full reference performance match; same coarse R7 word-register curve.',
            'Pitch detection and pulse placement may be unreliable in vocal fry.',
            'Neutral PSOLA repositions pulses, so waveform correlation is not a quality score.',
            'No loudness matching, EQ, source re-synthesis or app changes.',
            'Duration, finite samples and intact text do not certify voice coherence.',
        ],
    }
    assert hashlib.sha256(source.read_bytes()).hexdigest() == manifest['synthetic']['sha256']
    with (args.output/'manifest.json').open('x') as f:
        json.dump(report, f, indent=2)
    print(json.dumps({k: report[k] for k in ('renderer', 'sampleCount', 'paths', 'limitations')}, indent=2))


if __name__ == '__main__':
    main()
