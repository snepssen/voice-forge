/**
 * WAV writing and resampling, in plain TypeScript.
 *
 * The Swift build leans on AVFoundation for both. There is no equivalent here
 * and no reason to want one: a RIFF header is thirteen fields, and the
 * resampler only ever runs between two known rates on a finished take, where
 * being correct matters far more than being fast.
 */

/**
 * A windowed-sinc resampler.
 *
 * Upsampling needs no anti-alias filter — the input is already band-limited —
 * so the cutoff is only pulled in when going down. 32 taps with a Lanczos
 * window; the cost is a few milliseconds on a two-minute take.
 */
export function resample(x: Float32Array, from: number, to: number, taps = 32): Float32Array {
  if (from === to || !x.length) return x;
  const ratio = to / from;
  const outCount = Math.floor(x.length * ratio);
  const cutoff = Math.min(1, ratio);
  const a = taps / 2;
  const out = new Float32Array(outCount);
  for (let n = 0; n < outCount; n++) {
    const center = n / ratio;
    const i0 = Math.floor(center) - taps / 2 + 1;
    let acc = 0;
    for (let k = 0; k < taps; k++) {
      const i = i0 + k;
      if (i < 0 || i >= x.length) continue;
      const t = center - i;
      if (Math.abs(t) >= a) continue;
      const s = t === 0 ? cutoff : Math.sin(Math.PI * cutoff * t) / (Math.PI * t);
      const w = t === 0 ? 1
        : (a * Math.sin(Math.PI * t / a) * Math.sin(Math.PI * t)) / (Math.PI * Math.PI * t * t);
      acc += x[i]! * s * w;
    }
    out[n] = acc;
  }
  return out;
}

/**
 * A plain RIFF/WAVE writer. 24-bit is packed three bytes a sample, which is the
 * depth a further-editing workflow actually wants and the one most convenience
 * APIs will not give you.
 */
export function writeWav(samples: Float32Array, rate: number, bits: 16 | 24): Uint8Array {
  const bytesPerSample = bits / 8;
  const dataBytes = samples.length * bytesPerSample;
  const buf = new Uint8Array(44 + dataBytes);
  const view = new DataView(buf.buffer);
  const ascii = (at: number, s: string) => { for (let i = 0; i < s.length; i++) buf[at + i] = s.charCodeAt(i); };

  ascii(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);                       // PCM
  view.setUint16(22, 1, true);                       // mono
  view.setUint32(24, rate, true);
  view.setUint32(28, rate * bytesPerSample, true);
  view.setUint16(32, bytesPerSample, true);
  view.setUint16(34, bits, true);
  ascii(36, "data");
  view.setUint32(40, dataBytes, true);

  let at = 44;
  for (const v of samples) {
    const clamped = Math.max(-1, Math.min(1, v));
    if (bits === 16) {
      // Full scale negative is -32768 and positive is 32767, so scaling both by
      // 32767 is the conversion that cannot wrap.
      view.setInt16(at, Math.round(clamped * 32767), true); at += 2;
    } else {
      const s = Math.round(clamped * 8388607);
      buf[at] = s & 0xff; buf[at + 1] = (s >> 8) & 0xff; buf[at + 2] = (s >> 16) & 0xff;
      at += 3;
    }
  }
  return buf;
}
