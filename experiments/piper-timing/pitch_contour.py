#!/usr/bin/env python3
"""Isolated pitch-only audition on the exact preferred vowel-timing WAV.

LISTENING STATUS: token profile was too subtle; voiced profile was rejected
as an oscillating/warbling delivery. Retained for diagnosis, not integration.
Uses installed Rubber Band 4 Live C API via ctypes; numpy and ffmpeg required.
No model, app, duration, EQ, or gain-envelope edits. Not a general word aligner.
Usage: python pitch_contour.py ALIGNMENT_JSON NEW_OUTPUT_DIRECTORY
"""
import argparse
import ctypes as C
import hashlib
import json
import math
from pathlib import Path
import subprocess
import wave

import numpy as np


def resample(x, source_rate, target_rate):
    result = subprocess.run([
        "ffmpeg", "-v", "error", "-f", "f32le", "-ar", str(source_rate),
        "-ac", "1", "-i", "pipe:0", "-ar", str(target_rate), "-f", "f32le", "pipe:1"
    ], input=np.asarray(x, dtype='<f4').tobytes(), capture_output=True, check=True)
    return np.frombuffer(result.stdout, dtype='<f4').copy()


class PitchOnly:
    def __init__(self, path, formant_preserved=True):
        self.lib = C.CDLL(str(path))
        self.options = 0x01000000 if formant_preserved else 0
        self.ptr = C.POINTER(C.c_float)
        for name, args, result in [
            ('new', [C.c_uint, C.c_uint, C.c_int], C.c_void_p),
            ('delete', [C.c_void_p], None),
            ('set_pitch_scale', [C.c_void_p, C.c_double], None),
            ('get_start_delay', [C.c_void_p], C.c_uint),
            ('get_block_size', [C.c_void_p], C.c_uint),
            ('shift', [C.c_void_p, C.POINTER(self.ptr), C.POINTER(self.ptr)], None),
        ]:
            fn = getattr(self.lib, 'rubberband_live_' + name)
            fn.argtypes, fn.restype = args, result
            setattr(self, name, fn)

    def run(self, x, rate, envelope):
        state = self.new(rate, 1, self.options)  # Short window; optional formant preservation
        if not state:
            raise RuntimeError('Rubber Band Live allocation failed')
        try:
            self.set_pitch_scale(state, 2 ** (envelope(0) / 12))
            delay, block = self.get_start_delay(state), self.get_block_size(state)
            # Flush delayed audio into explicit zero padding, then discard only
            # the documented delay. Never trim speech to force duration parity.
            size = math.ceil((len(x) + delay + 2 * block) / block) * block
            padded = np.zeros(size, dtype=np.float32)
            padded[:len(x)] = x
            output = np.zeros_like(padded)
            for start in range(0, size, block):
                # Schedule against input time; compensate the output latency
                # once when slicing below, not again in the control timeline.
                time = (start + block / 2) / rate
                semitones = envelope(time)
                assert np.isfinite(semitones) and abs(semitones) <= 6
                self.set_pitch_scale(state, 2 ** (semitones / 12))
                src = (self.ptr * 1)(padded[start:start+block].ctypes.data_as(self.ptr))
                dst = (self.ptr * 1)(output[start:start+block].ctypes.data_as(self.ptr))
                self.shift(state, src, dst)
            return output[delay:delay+len(x)].copy(), {'delaySamples': delay, 'blockSamples': block}
        finally:
            self.delete(state)


def smooth_curve(points):
    def value(time):
        if time <= points[0][0]:
            return points[0][1]
        for (a, x), (b, y) in zip(points, points[1:]):
            if time <= b:
                u = (time - a) / (b - a)
                return x + (y - x) * (0.5 - 0.5 * math.cos(math.pi * u))
        return points[-1][1]
    return value


def write_wav(path, samples, rate):
    assert np.isfinite(samples).all() and np.max(np.abs(samples)) < 0.98
    with path.open('xb') as file:
        with wave.open(file, 'wb') as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(rate)
            wav.writeframes(np.rint(samples * 32768).astype('<i2').tobytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('alignment', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--library', type=Path, default=Path('/opt/homebrew/lib/librubberband.dylib'))
    parser.add_argument('--profile', choices=['token', 'voiced'], default='token')
    args = parser.parse_args()
    alignment = json.loads(args.alignment.read_text())
    source = Path(alignment['sourceAudio'])
    source_bytes = source.read_bytes()
    assert hashlib.sha256(source_bytes).hexdigest() == alignment['sourceSHA256']
    with wave.open(str(source), 'rb') as wav:
        assert wav.getnchannels() == 1 and wav.getsampwidth() == 2
        rate = wav.getframerate()
        x = np.frombuffer(wav.readframes(wav.getnframes()), '<i2').astype(np.float32) / 32768
    assert rate == alignment['rate'] and len(x) == alignment['sampleCount']
    tokens = {s['index']: s for s in alignment['tokens']}
    assert [tokens[i]['symbol'] for i in [40, 46, 48, 50, 54, 56]] == ['s', 'o', 'ʊ', 'l', 'ɪ', 't']
    # Relative pitch offsets around the existing delivery, not invented emotion labels.
    points = [(0.0, 0.0), (tokens[43]['start'], 0.0),
              (tokens[47]['start'], 3.0), (tokens[51]['end'], -1.5),
              (tokens[55]['end'] - 0.015, 3.0), (tokens[57]['end'], 0.0),
              (len(x) / rate, 0.0)]
    windows = [('stole-rise', tokens[46]['start'], tokens[49]['end'], np.argmax),
               ('drop', tokens[49]['start'], tokens[54]['start'], np.argmin),
               ('it-rise', tokens[54]['start'], tokens[56]['start'], np.argmax)]
    if args.profile == 'voiced':
        # Manually placed against measured voicing in this exact audition.
        # These are not general-purpose word boundaries or forced alignment.
        assert alignment['sourceSHA256'] == '37b5f22bce3b6ffa8216cde76bd79db9b32c749aebfabcb480c5802669e7184d'
        points = [(0.0, 0.0), (1.31, 0.0), (1.42, 4.5), (1.47, 4.5),
                  (1.56, -2.0), (1.63, 4.5), (1.72, 0.0), (len(x)/rate, 0.0)]
        windows = [('stole-rise', 1.37, 1.50, np.argmax),
                   ('drop', 1.49, 1.60, np.argmin), ('it-rise', 1.60, 1.69, np.argmax)]
    assert all(a[0] < b[0] for a, b in zip(points, points[1:]))
    processor = PitchOnly(args.library)
    work_rate = 44100
    up = resample(x, rate, work_rate)
    assert len(up) == len(x) * 2
    # Synthetic calibration: the neutral path's time alignment and a +3st shift.
    t = np.arange(work_rate * 2) / work_rate
    sine = (0.2 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    shifted, _ = processor.run(sine, work_rate, lambda _: 3.0)
    segment = shifted[work_rate//2:3*work_rate//2]
    spectrum = np.abs(np.fft.rfft(segment * np.hanning(len(segment))))
    measured = float(np.argmax(spectrum))
    expected = 220 * 2 ** (3 / 12)
    assert abs(12 * math.log2(measured / expected)) < 0.1
    # Probe the moving contour on a known sine. This detects late accents that
    # would land on the final consonant instead of the vowel in this fixture.
    dynamic, _ = processor.run(sine, work_rate, smooth_curve(points))
    crossings = np.flatnonzero((dynamic[:-1] <= 0) & (dynamic[1:] > 0))
    zeros = (crossings - dynamic[crossings] / (dynamic[crossings+1] - dynamic[crossings])) / work_rate
    mids = (zeros[1:] + zeros[:-1]) / 2
    semitones = 12 * np.log2(1 / np.diff(zeros) / 220)
    extrema = []
    for label, lo, hi, operation in windows:
        select = (mids >= lo) & (mids < hi)
        index = operation(semitones[select])
        level = float(semitones[select][index])
        assert level < -0.75 if label == 'drop' else level > 2.5
        extrema.append({'event': label, 'time': float(mids[select][index]), 'semitones': level})
    neutral, delay = processor.run(up, work_rate, lambda _: 0.0)
    altered, same_delay = processor.run(up, work_rate, smooth_curve(points))
    assert delay == same_delay
    neutral, altered = [resample(a, work_rate, rate) for a in [neutral, altered]]
    assert len(neutral) == len(altered) == len(x)
    # Limit changes to the target phrase, with a 30ms cosine wet/dry transition.
    # Matching complementary weights avoids gain boosts at the boundaries.
    start = tokens[40]['start']
    end = tokens[57]['end']
    times = np.arange(len(x)) / rate
    ramp = 0.03
    wet = np.minimum(np.clip((times - start) / ramp, 0, 1), np.clip((end - times) / ramp, 0, 1))
    wet = 0.5 - 0.5 * np.cos(np.pi * wet)
    clips = {'reference.wav': x, 'processor-control.wav': x + wet * (neutral - x),
             'rise-fall-rise.wav': x + wet * (altered - x)}
    args.output.mkdir(parents=True, exist_ok=False)
    measurements = []
    for name, samples in clips.items():
        assert np.array_equal(samples[wet == 0], x[wet == 0])
        write_wav(args.output / name, samples, rate)
        measurements.append({'file': name, 'samples': len(samples), 'seconds': len(samples) / rate,
                             'samplePeakDBFS': float(20 * np.log10(np.max(np.abs(samples)))),
                             'unchangedOutsideTargetRegion': True})
    assert hashlib.sha256(source.read_bytes()).hexdigest() == alignment['sourceSHA256']
    manifest = {'source': str(source), 'sourceSHA256': alignment['sourceSHA256'],
                'profile': args.profile,
                'processor': str(args.library.resolve()), 'formantPreservation': True,
                'workRate': work_rate, 'rate': rate, 'latency': delay,
                'semitoneOffsetPoints': points, 'calibration': {'expectedHz': expected, 'measuredHz': measured,
                                                              'sineContourExtrema': extrema},
                'clips': measurements, 'limitations': [
                    'Relative pitch offsets; not an absolute measured F0 trajectory.',
                    'Model token alignment is approximate acoustic timing.',
                    'Equal sample count is not a perceptual-quality guarantee.',
                    'One fixed fixture; listening approval and broader validation pending.',
                    'Rubber Band licensing must be reviewed before distributing any integration.']}
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
