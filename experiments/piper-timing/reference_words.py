#!/usr/bin/env python3
"""Local ASR timing landmarks for the two versions of the fixed sentence.
Token emission times are approximate landmarks, not forced word alignment.
Requires an existing onnx-asr runtime and explicitly supplied local model path.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import numpy as np
import onnx_asr
import onnxruntime as ort


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('model', type=Path)
    p.add_argument('reference', type=Path)
    p.add_argument('synthetic', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    model = onnx_asr.load_model('nemo-parakeet-tdt-0.6b-v2', path=a.model,
                               sess_options=options, providers=['CPUExecutionProvider']).with_timestamps()
    report = {'model': str(a.model), 'clips': [], 'limitation': 'ASR emission timestamps; not exact word or phoneme boundaries.'}
    for file in [a.reference, a.synthetic]:
        decoded = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(file), '-ar', '16000',
                                  '-ac', '1', '-f', 'f32le', 'pipe:1'], capture_output=True, check=True)
        samples = np.frombuffer(decoded.stdout, '<f4').copy()
        result = model.recognize(samples, sample_rate=16000)
        assert result.tokens and len(result.tokens) == len(result.timestamps), 'No usable token timestamps'
        clip = {'path': str(file), 'sha256': hashlib.sha256(file.read_bytes()).hexdigest(),
                'text': result.text, 'tokens': list(result.tokens), 'timestamps': list(result.timestamps)}
        report['clips'].append(clip)
        print(json.dumps(clip, indent=2), flush=True)
    with a.output.open('x') as out:
        json.dump(report, out, indent=2)


if __name__ == '__main__':
    main()
