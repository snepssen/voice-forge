#!/usr/bin/env python3
"""Extract reference takes and conservative pitch measurements, locally.

No source edits, normalization, resynthesis, word-boundary guesses, or training.
Requires numpy and praat-parselmouth; exports original PCM stereo take excerpts.
Usage: python reference_analysis.py REFERENCE.wav NEW_OUTPUT_DIRECTORY
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import wave

import numpy as np
import parselmouth


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--expected-takes', type=int, default=3)
    args = parser.parse_args()
    source_hash = sha(args.source)
    original = parselmouth.Sound(str(args.source))
    rate = int(original.sampling_frequency)
    with wave.open(str(args.source), 'rb') as wav:
        params = wav.getparams()
        pcm = wav.readframes(wav.getnframes())
    assert params.comptype == 'NONE' and params.nframes == original.n_samples
    stride = params.nchannels * params.sampwidth
    # Peak activity with long-gap grouping: preserve pauses inside a take.
    block = round(rate * .01)
    peaks = np.array([np.max(np.abs(original.values[:, i:i+block]))
                      for i in range(0, original.n_samples, block)])
    active = np.flatnonzero(peaks > 10 ** (-35 / 20))
    assert len(active), 'No speech-level activity found'
    groups = np.split(active, np.flatnonzero(np.diff(active) * block / rate > .8) + 1)
    assert len(groups) == args.expected_takes, f'Expected {args.expected_takes} takes; detected {len(groups)}. Inspect before proceeding.'
    mono = parselmouth.Sound(np.mean(original.values, axis=0), sampling_frequency=rate)
    config = dict(time_step=.005, pitch_floor=50, pitch_ceiling=450)
    ac, cc = mono.to_pitch_ac(**config), mono.to_pitch_cc(**config)
    times = ac.xs()
    f0 = ac.selected_array['frequency']
    fcc = np.array([cc.get_value_at_time(float(t)) for t in times])
    valid = (f0 > 0) & (fcc > 0) & np.isfinite(fcc)
    difference = np.full_like(f0, np.inf)
    difference[valid] = np.abs(12 * np.log2(f0[valid] / fcc[valid]))
    rms = np.array([20 * np.log10(max(1e-10, float(np.sqrt(np.mean(mono.values[0,
        max(0, int((t-.01)*rate)):min(original.n_samples, int((t+.01)*rate))] ** 2))))) for t in times])
    reliable = valid & (difference <= 1) & (rms > -40)
    args.output.mkdir(parents=True, exist_ok=False)
    takes = []
    for number, group in enumerate(groups, 1):
        active_start = int(group[0]) * block
        active_end = min(original.n_samples, (int(group[-1]) + 1) * block)
        start = max(0, active_start - round(.15 * rate))
        end = min(original.n_samples, active_end + round(.15 * rate))
        take_pcm = pcm[start*stride:end*stride]
        file = args.output / f'take-{number}.wav'
        with file.open('xb') as out:
            with wave.open(out, 'wb') as wav:
                wav.setparams(params)
                wav.writeframes(take_pcm)
        with wave.open(str(file), 'rb') as wav:
            assert wav.readframes(wav.getnframes()) == take_pcm
        sel = (times >= active_start/rate) & (times <= active_end/rate) & reliable
        assert sel.sum() >= 20, 'Insufficient agreed voiced frames for a take'
        median = float(np.median(f0[sel]))
        p5, p95 = np.percentile(f0[sel], [5, 95])
        indices = np.flatnonzero((times >= start/rate) & (times <= end/rate))
        csv_path = args.output / f'take-{number}-pitch.csv'
        with csv_path.open('x', newline='') as out:
            writer = csv.writer(out)
            writer.writerow(['take_seconds', 'source_seconds', 'pitch_hz', 'relative_semitones', 'rms_dbfs', 'reliable'])
            for i in indices:
                writer.writerow([round(float(times[i]-start/rate), 6), round(float(times[i]), 6),
                    float(f0[i]) if reliable[i] else '',
                    float(12*np.log2(f0[i]/median)) if reliable[i] else '', float(rms[i]), bool(reliable[i])])
        spans = np.split(np.flatnonzero(sel), np.flatnonzero(np.diff(np.flatnonzero(sel)) > 1) + 1)
        takes.append({'take': number, 'file': file.name, 'sha256': sha(file), 'pitchCSV': csv_path.name,
                      'excerptStart': start/rate, 'excerptEnd': end/rate,
                      'activityStart': active_start/rate, 'activityEnd': active_end/rate,
                      'activitySpanSeconds': (active_end-active_start)/rate,
                      'medianPitchHz': median, 'pitchP5Hz': float(p5), 'pitchP95Hz': float(p95),
                      'central90PercentPitchSpanSemitones': float(12*np.log2(p95/p5)),
                      'reliableVoicedFrames': int(sel.sum()),
                      'voicedSpans': [{'start': float(times[s[0]]), 'end': float(times[s[-1]])}
                                      for s in spans if len(s) >= 3],
                      'excerptPCMVerifiedIdentical': True})
    assert sha(args.source) == source_hash
    report = {'source': str(args.source), 'sourceSHA256': source_hash,
              'rate': rate, 'channels': params.nchannels, 'bits': params.sampwidth*8,
              'analysisChannel': 'mean of channels; excerpt channels remain original',
              'channelCorrelation': float(np.corrcoef(original.values)[0, 1]) if params.nchannels == 2 else None,
              'peakDBFS': float(20*np.log10(np.max(np.abs(original.values)))),
              'method': {'pitch': 'Praat AC/CC agreement within 1 semitone; RMS above -40dBFS',
                         'settings': config, 'split': 'activity above -35dBFS; gaps over 0.8s; 0.15s margins'},
              'takes': takes, 'limitations': [
                  'No transcription, phonetic word alignment, or emotion labels inferred.',
                  'Pitch estimators can agree on the wrong octave, especially with vocal fry.',
                  'Pitch gaps remain missing; no invented melody across unvoiced consonants or pauses.',
                  'These reference measurements are not yet transferred to the synthetic voice.']}
    with (args.output/'manifest.json').open('x') as out:
        json.dump(report, out, indent=2)
    print(json.dumps([{k: v for k, v in take.items() if k != 'voicedSpans'} for take in takes], indent=2))


if __name__ == '__main__':
    main()
