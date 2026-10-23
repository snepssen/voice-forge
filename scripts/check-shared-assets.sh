#!/usr/bin/env bash
# The two builds must ship byte-identical espeak-ng data and the same model.
#
# This is not tidiness. `piper-phonemize` bundles a newer espeak-ng whose
# American English rules moved the NORTH/FORCE vowel from ɔːɹ to oːɹ; measured
# across 35 ordinary words, 8 differed -- four, before, more, door, important,
# course, report, support -- and the model was trained on the first. The
# cross-platform build ships the macOS build's espeak data for that reason
# alone, and if the two ever drift the platforms stop sounding alike in some of
# the commonest words in English.
#
# It fails open, too: point the phonemizer at the wrong directory and nothing
# errors, so nothing downstream would notice. Hence a check.
set -euo pipefail
cd "$(dirname "$0")/.."

# The macOS build reads voice-core's copy, the one every snepssen app shares.
[ -d macos/.build/checkouts/voice-core ] || (cd macos && swift package resolve >/dev/null)
MAC_DATA=macos/.build/checkouts/voice-core/Sources/VoiceCore/Resources/espeak-ng-data
XP_DATA=cross-platform/resources/espeak-ng-data
MAC_MODEL=macos/Sources/VoiceForgeTTS/Resources/en_US-snepssen-medium.onnx
XP_MODEL=cross-platform/resources/voices/en_US-snepssen-medium.onnx

fail=0
if diff -rq "$MAC_DATA" "$XP_DATA" >/dev/null 2>&1; then
  echo "espeak-ng-data: identical across both builds ($(find "$MAC_DATA" -type f | wc -l | tr -d ' ') files)"
else
  echo "espeak-ng-data DIFFERS between the two builds:" >&2
  diff -rq "$MAC_DATA" "$XP_DATA" 2>&1 | head -20 >&2
  fail=1
fi

if cmp -s "$MAC_MODEL" "$XP_MODEL"; then
  echo "voice model:    identical across both builds"
else
  echo "voice model DIFFERS between the two builds" >&2
  fail=1
fi

# The Electron build's phonemizer is voice-core's WebAssembly espeak-ng 724808c
# (scripts/sync-voice-core-js.sh). A stale copy fails open too: piper-phonemize's
# older espeak-ng dropped the U+02B2 glide on 255 of 923 real lines, silently.
MAC_JS="${VOICE_CORE:-macos/.build/checkouts/voice-core}/js"
XP_JS=cross-platform/vendor/voice-core
same_js() {
  for f in espeak.cjs espeak.wasm phonemizer.mjs phonemizer.d.mts; do cmp -s "$MAC_JS/$f" "$XP_JS/$f" || return 1; done
}
if [ ! -f "$MAC_JS/phonemizer.mjs" ]; then
  echo "phonemizer:     the voice-core macOS resolves has no js/ (1.2.0 or later has it)" >&2
  fail=1
elif same_js; then
  echo "phonemizer:     identical to voice-core's (espeak-ng 724808c as WebAssembly)"
else
  echo "phonemizer DIFFERS from voice-core's: run scripts/sync-voice-core-js.sh" >&2
  fail=1
fi

# phontab is the file that actually carries the vowel definitions, so name it
# separately -- a failure here is the one that would be heard rather than seen.
if cmp -s "$MAC_DATA/phontab" "$XP_DATA/phontab"; then
  echo "phontab:        identical (this is the file that decides how 'four' sounds)"
else
  echo "phontab DIFFERS -- the platforms will not sound the same" >&2
  fail=1
fi

exit $fail
