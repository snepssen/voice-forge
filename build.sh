#!/usr/bin/env bash
# Build Voice Forge.app.
#
# `swift build`, like the app this engine came from: onnxruntime ships a
# prebuilt XCFramework and needs no Metal shader compilation, which was the
# only reason that project ever needed xcodebuild.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/Voice Forge.app"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[ -n "$APP_VERSION" ] || { echo "VERSION is empty" >&2; exit 1; }

case "$(echo "${1:-release}" | tr '[:upper:]' '[:lower:]')" in
  release) CONF=release ;;
  debug)   CONF=debug ;;
  *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac
PRODUCTS="$(swift build -c "$CONF" --show-bin-path)"

assert_arm64() {
  local archs; archs="$(lipo -archs "$1" 2>/dev/null || echo "not a fat binary")"
  case "$archs" in arm64|*arm64*) ;; *) echo "wrong arch for $1: $archs" >&2; exit 1 ;; esac
}

echo "checks…"
swift build --product vfcheck -c "$CONF"
assert_arm64 "$PRODUCTS/vfcheck"
"$PRODUCTS/vfcheck"

echo "building…"
swift build --product vfrender -c "$CONF"
assert_arm64 "$PRODUCTS/vfrender"
swift build --product VoiceForge -c "$CONF"
BIN="$PRODUCTS/VoiceForge"
assert_arm64 "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoiceForge"

# SwiftPM resource bundles sit beside the product; in a .app they belong in
# Contents/Resources, where Bundle.module looks.
bundles=0
while IFS= read -r b; do
  cp -R "$b" "$APP/Contents/Resources/"
  bundles=$((bundles + 1))
done < <(find "$PRODUCTS" -maxdepth 1 -name '*.bundle')

# The voice gate, derived from the source tree and naming nothing.
#
# Inherited from Gateway Forge along with the reason it looks like this: the
# gate there tested for a literal model filename that had been deleted from
# source months earlier, and SwiftPM -- which does not prune resources it has
# already staged -- kept a copy in .build that satisfied it. The app shipped a
# third voice nobody had trained, offered in the picker like any other, because
# the engine enumerates that directory by name. A gate a leftover can satisfy is
# not a gate.
VOICE_SRC="$ROOT/Sources/VoiceForgeTTS/Resources"
voice_names() {
  find "$1" -maxdepth 1 -name 'en_US-*-medium.onnx' -exec basename {} \; 2>/dev/null \
    | sed 's/^en_US-//; s/-medium\.onnx$//' | sort
}
SRC_VOICES="$(voice_names "$VOICE_SRC")"
[ -n "$SRC_VOICES" ] || { echo "error: no voice model in $VOICE_SRC" >&2; exit 1; }

VOICE_BUNDLE="$(find "$APP/Contents/Resources" -maxdepth 1 -iname '*VoiceForgeTTS*.bundle' | head -1)"
[ -n "$VOICE_BUNDLE" ] || { echo "error: no VoiceForgeTTS resource bundle in the app" >&2; exit 1; }

pruned=0
while IFS= read -r name; do
  echo "$SRC_VOICES" | grep -qx "$name" && continue
  rm -f "$VOICE_BUNDLE/en_US-$name-medium.onnx" "$VOICE_BUNDLE/en_US-$name-medium.onnx.json"
  echo "pruned stale voice from the bundle: $name"
  pruned=$((pruned + 1))
done < <(voice_names "$VOICE_BUNDLE")

APP_VOICES="$(voice_names "$VOICE_BUNDLE")"
if [ "$SRC_VOICES" != "$APP_VOICES" ]; then
  echo "error: packaged voices do not match the source tree" >&2
  echo "  source: $(echo "$SRC_VOICES" | tr '\n' ' ')" >&2
  echo "  app:    $(echo "$APP_VOICES" | tr '\n' ' ')" >&2
  exit 1
fi
voice_count=0
while IFS= read -r name; do
  for part in "en_US-$name-medium.onnx" "en_US-$name-medium.onnx.json"; do
    [ -s "$VOICE_BUNDLE/$part" ] || { echo "error: $name is packaged without $part" >&2; exit 1; }
  done
  voice_count=$((voice_count + 1))
done < <(echo "$APP_VOICES")
[ -d "$VOICE_BUNDLE/espeak-ng-data" ] || {
  echo "error: espeak-ng-data did not land in the app" >&2; exit 1; }
echo "voices packaged: $(echo "$APP_VOICES" | tr '\n' ' ')($voice_count)$([ "$pruned" -gt 0 ] && echo ", $pruned pruned")"

# The training guide travels with the app, so "How to train one" works with no
# network and no repository checkout.
cp "$ROOT/TRAINING.md" "$APP/Contents/Resources/TRAINING.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>VoiceForge</string>
  <key>CFBundleIdentifier</key><string>local.voiceforge.app</string>
  <key>CFBundleName</key><string>Voice Forge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" >/dev/null 2>&1 || true
APP_KB="$(du -sk "$APP" | awk '{print $1}')"
echo "built: $APP  ($CONF, arm64, $bundles resource bundle(s), $voice_count voice(s), $((APP_KB / 1024)) MiB)"
