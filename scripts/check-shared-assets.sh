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

MAC_DATA=macos/Sources/VoiceForgeTTS/Resources/espeak-ng-data
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

# phontab is the file that actually carries the vowel definitions, so name it
# separately -- a failure here is the one that would be heard rather than seen.
if cmp -s "$MAC_DATA/phontab" "$XP_DATA/phontab"; then
  echo "phontab:        identical (this is the file that decides how 'four' sounds)"
else
  echo "phontab DIFFERS -- the platforms will not sound the same" >&2
  fail=1
fi

exit $fail
