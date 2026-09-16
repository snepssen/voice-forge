#!/usr/bin/env python3
"""Original-duration, constant-shift diagnostic for the saved Suno fixture.

Audits analysis-floor sensitivity before testing pitch movement. Not an emotion
preset or a general aligner. All outputs are new files; original media is read-only.
"""
import argparse
import hashlib
import json
import wave
from pathlib import Path

import numpy as np
import parselmouth
from parselmouth.praat import call

from pitch_contour import write_wav
from resynthesis_probe import assess_pitch
from voice_integrity import summarize
from word_isolation import region_mask

SOURCE_HASH = 'ba08fae0b57a776dbd3036eb58d61057a2114a43f4f76adfef8ac68288b1cfdf'
WORD_WINDOW = (1.12, 1.52)  # Original-duration ASR landmarks, not the stretched clip.
CORE_WINDOW = (1.40, 1.48)  # Excludes the onset where trackers disagree.


def analyze_source(sound, floor):
    manipulation = call(sound, 'To Manipulation', .005, floor, 350)
    points = call(manipulation, 'Extract pulses')
    pulses = [call(points, 'Get time from index', i)
              for i in range(1, call(points, 'Get number of points')+1)]
    tier = call(manipulation, 'Extract pitch tier')
    pitch = [{'time': call(tier, 'Get time from index', i),
              'hz': call(tier, 'Get value at index', i)}
             for i in range(1, call(tier, 'Get number of points')+1)]
    return manipulation, {'floorHz': floor, 'pulseTimes': pulses, 'pitchTier': pitch}


def render_constant(manipulation, offset):
    assert np.isfinite(offset) and abs(offset) <= 6
    tier = call(manipulation, 'Extract pitch tier')
    indices = range(1, call(tier, 'Get number of points')+1)
    before = np.array([call(tier, 'Get value at index', i) for i in indices])
    # An empty [0, 0] range is a no-op for this command, not "all time".
    call(tier, 'Multiply frequencies', call(tier, 'Get start time'),
         call(tier, 'Get end time'), 2**(offset/12))
    after = np.array([call(tier, 'Get value at index', i) for i in indices])
    assert len(before) and np.allclose(after, before*2**(offset/12), rtol=1e-12)
    call([tier, manipulation], 'Replace pitch tier')
    return call(manipulation, 'Get resynthesis (overlap-add)')


def plot_audit(sound, analyses, path):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(3, 1, figsize=(12, 8), sharex=True,
                             gridspec_kw={'height_ratios': [1, 1, 1.2]})
    times = sound.xs()
    selected = (times >= 1.32) & (times <= 1.54)
    for ax, data, color in zip(axes[:2], analyses, ['#0072B2', '#D55E00']):
        ax.plot(times[selected], sound.values[0, selected], color='#333333', linewidth=.8)
        for t in data['pulseTimes']:
            if 1.32 <= t <= 1.54:
                ax.axvline(t, color=color, alpha=.7, linewidth=1)
        ax.set_title(f"Same source waveform; pulse detection with {data['floorHz']} Hz floor", loc='left')
        ax.set_ylabel('Amplitude (FS)')
        limit = float(np.max(np.abs(sound.values[0, selected])))*1.05
        ax.set_ylim(-limit, limit)
    for data, color, style in zip(analyses, ['#0072B2', '#D55E00'], ['-', '--']):
        pitch = sound.to_pitch_ac(time_step=.005, pitch_floor=data['floorHz'], pitch_ceiling=350)
        values = pitch.selected_array['frequency'].copy()
        values[values == 0] = np.nan
        axes[2].plot(pitch.xs(), values, style, color=color, label=f"AC, {data['floorHz']} Hz floor")
    cc = sound.to_pitch_cc(time_step=.005, pitch_floor=40, pitch_ceiling=350)
    vals = cc.selected_array['frequency'].copy()
    vals[vals == 0] = np.nan
    axes[2].plot(cc.xs(), vals, ':', color='#333333', label='CC, 40 Hz floor')
    axes[2].set_ylim(40, 130)
    axes[2].set_ylabel('Estimated pitch (Hz)')
    axes[2].set_xlabel('Time in original-duration recording (seconds)')
    axes[2].legend(loc='upper right')
    axes[2].set_xlim(1.32, 1.54)
    for ax in axes:
        ax.axvspan(*CORE_WINDOW, color='#999999', alpha=.13)
        ax.spines[['top', 'right']].set_visible(False)
    fig.suptitle('Pitch tracking differs at the onset; shaded core is the fixed-shift test region', fontsize=13)
    fig.text(.08, .012, f'Saved Suno baseline; SHA-256 {SOURCE_HASH[:16]}… | Missing pitch estimates shown as gaps.', fontsize=10)
    fig.tight_layout(rect=[0, .035, 1, .96])
    fig.savefig(path, dpi=150)
    plt.close(fig)


def comparison_sequence(paths, output, rate):
    """Concatenate exact PCM controls with silence; no fades or level changes."""
    pieces, segments, cursor = [], [], 0
    for index, path in enumerate(paths):
        with wave.open(str(path)) as w:
            assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, rate)
            raw = w.readframes(w.getnframes())
        count = len(raw)//2
        segments.append({'path': str(path.resolve()), 'startSample': cursor, 'sampleCount': count})
        pieces.append(raw)
        cursor += count
        if index < len(paths)-1:
            gap = round(.65*rate)
            pieces.append(bytes(2*gap))
            cursor += gap
    with output.open('xb') as f:
        with wave.open(f, 'wb') as w:
            w.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
            w.writeframes(b''.join(pieces))
    with wave.open(str(output)) as w:
        data = w.readframes(w.getnframes())
    for row, original in zip(segments, pieces[::2]):
        start = row['startSample']*2
        assert data[start:start+len(original)] == original
    return {'path': str(output.resolve()), 'gapSeconds': round(.65*rate)/rate,
            'segments': segments, 'individualPCMUnchanged': True}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--audit-only', action='store_true')
    a = p.parse_args()
    original = a.source.read_bytes()
    assert hashlib.sha256(original).hexdigest() == SOURCE_HASH
    sound = parselmouth.Sound(str(a.source))
    rate = int(sound.sampling_frequency)
    assert sound.n_channels == 1 and sound.n_samples == 40704 and rate == 22050
    a.output.mkdir(parents=True, exist_ok=False)
    analyses = [analyze_source(sound, floor)[1] for floor in (50, 40)]
    plot_audit(sound, analyses, a.output/'pulse-audit.png')
    report = {'source': str(a.source.resolve()), 'sourceSHA256': SOURCE_HASH,
              'sampleCount': sound.n_samples, 'sampleRate': rate,
              'wordWindow': WORD_WINDOW, 'measurementCore': CORE_WINDOW,
              'analysis': analyses, 'clips': [], 'listenerApproval': False,
              'limitations': [
                  'Floor 40 and floor 50 are sensitivity tests, not proven-correct pulse tracks.',
                  'Word window uses approximate recognizer landmarks, not forced alignment.',
                  'Measured core excludes the disputed onset, but the audible word still includes it.',
                  'Only one saved Suno sentence; no Rode or multi-sentence validation yet.',
                  'New source has its own acoustic noise draw; compare only within this test.',
                  'Finite output and measured pitch do not establish naturalness.',
              ]}
    if not a.audit_only:
        with (a.output/'dry.wav').open('xb') as f:
            f.write(original)
        x = sound.values[0]
        mask = region_mask(len(x), rate, *WORD_WINDOW)
        for floor in (50, 40):
            for offset in (0, 1, 4.450116003846203):
                manipulation, _ = analyze_source(sound, floor)  # Never accumulate shifts.
                rendered = render_constant(manipulation, offset)
                assert rendered.x1 == sound.x1 and rendered.values.shape == sound.values.shape
                assert rendered.sampling_frequency == rate
                output = x + mask*(rendered.values[0]-x)
                path = a.output/f'floor-{floor}-shift-{offset:.2f}.wav'
                write_wav(path, output, rate)
                decoded = parselmouth.Sound(str(path)).values[0]
                assert np.array_equal(decoded[mask == 0], x[mask == 0])
                regions = [('stole-core', *CORE_WINDOW)]
                evidence = assess_pitch(a.source, path, regions, lambda _: offset)
                core = evidence['regions'][0]
                # A 1.5-semitone exploratory tolerance can falsely pass a no-op
                # when the command itself is only one semitone. Be stricter here.
                strict = (core['pitchEvidenceConsistent'] and
                          abs(core['medianResidualSemitones']) <= .35)
                report['clips'].append({
                    'path': str(path.resolve()), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                    'floorHz': floor, 'shiftSemitones': offset,
                    'sampleCount': len(decoded), 'peakDBFS': float(20*np.log10(np.max(np.abs(decoded)))),
                    'regions': summarize(decoded, rate, regions),
                    'pitchEvidence': evidence, 'fixedShiftEvidenceConsistent': strict,
                    'outsideWordIdentical': True,
                })
        if all(r['fixedShiftEvidenceConsistent'] for r in report['clips'] if r['floorHz'] == 50):
            report['comparison'] = comparison_sequence(
                [a.output/'dry.wav'] + [Path(r['path']) for r in report['clips'] if r['floorHz'] == 50],
                a.output/'comparison.wav', rate)
    assert hashlib.sha256(a.source.read_bytes()).hexdigest() == SOURCE_HASH
    with (a.output/'manifest.json').open('x') as f:
        json.dump(report, f, indent=2)
    print(json.dumps({'output': str(a.output), 'clips': report['clips']}, indent=2))


if __name__ == '__main__':
    main()
