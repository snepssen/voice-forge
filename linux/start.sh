#!/usr/bin/env bash
# Voice Forge on Linux: offers what is missing, builds, and opens the window.
#
#   ./start.sh            ask, then install what is missing (Enter means yes)
#   ./start.sh --yes      install without asking
#
# Three things are needed beyond this checkout. GTK4 and libadwaita come from
# the distribution's package manager, which needs root, so their command is
# printed for you to run, never run with sudo here. ONNX Runtime goes in your
# own data folder, so it is fetched (pinned, checksummed). A Swift toolchain
# builds the app; its installer is linked, since it is a toolchain choice.
set -euo pipefail
cd "$(dirname "$0")"
YES=false; [ "${1:-}" = "--yes" ] && { YES=true; shift; }

missing=()
command -v swift >/dev/null || missing+=(swift)
pkg-config --exists gtk4 libadwaita-1 2>/dev/null || missing+=(gtk)
ORT="${XDG_DATA_HOME:-$HOME/.local/share}/snepssen/onnxruntime/1.24.2/lib/libonnxruntime.so"
[ -f "$ORT" ] || missing+=(onnxruntime)

if [ ${#missing[@]} -gt 0 ]; then
  echo "Voice Forge needs a few things it does not ship:"
  for m in "${missing[@]}"; do
    case $m in
      swift) echo "  swift        builds the app — https://www.swift.org/install/linux/ (swiftly)";;
      gtk) echo "  gtk          GTK4 and libadwaita, the window";;
      onnxruntime) echo "  onnxruntime  runs the voice (Microsoft's 1.24.2, into $(dirname "$(dirname "$ORT")"))";;
    esac
  done
  echo
  if [[ " ${missing[*]} " == *" gtk "* ]]; then
    echo "GTK needs root to install, so Voice Forge will not run it for you. Copy this:"
    if command -v apt-get >/dev/null; then echo "  sudo apt-get install libgtk-4-dev libadwaita-1-dev"
    elif command -v pacman >/dev/null; then echo "  sudo pacman -S gtk4 libadwaita"
    elif command -v dnf >/dev/null; then echo "  sudo dnf install gtk4-devel libadwaita-devel"
    else echo "  (your distribution's gtk4 and libadwaita development packages)"; fi
    echo
  fi
  if [[ " ${missing[*]} " == *" onnxruntime "* ]]; then
    answer=y
    $YES || read -r -p "Fetch ONNX Runtime now? [Y/n] " answer || true
    case "${answer:-y}" in
      [nN]*) echo "Not fetched. Starting again will ask again." ;;
      *) # voice-core's own script, from the checkout SwiftPM keeps of it.
         swift package resolve >/dev/null
         .build/checkouts/voice-core/scripts/fetch-onnxruntime.sh >/dev/null && echo "  ✓ onnxruntime" ;;
    esac
  fi
  command -v swift >/dev/null && pkg-config --exists gtk4 libadwaita-1 2>/dev/null && [ -f "$ORT" ] || exit 1
fi

swift build -c release
exec .build/release/VoiceForgeGTK "$@"
