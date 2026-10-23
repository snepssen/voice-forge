#!/usr/bin/env bash
# Copy voice-core's WebAssembly phonemizer (js/) into the Electron build, from
# the voice-core the macOS build resolves, so both builds phonemize with
# espeak-ng 724808c. check-shared-assets.sh fails if the copy drifts.
#   scripts/sync-voice-core-js.sh [VOICE_CORE_CHECKOUT]
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d macos/.build/checkouts/voice-core ] || (cd macos && swift package resolve >/dev/null)
FROM="${1:-macos/.build/checkouts/voice-core}/js"
TO=cross-platform/vendor/voice-core
[ -f "$FROM/phonemizer.mjs" ] || { echo "no js/ in $FROM: voice-core 1.2.0 or later has it" >&2; exit 1; }
mkdir -p "$TO"
for f in espeak.cjs espeak.wasm phonemizer.mjs phonemizer.d.mts; do cp "$FROM/$f" "$TO/$f"; done
echo "copied voice-core's js/ into $TO"
