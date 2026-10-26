# Voice Forge on Linux

A GTK4 + libadwaita window over the same engine the Mac app uses:
`VoiceForgeCore` and `VoiceForgeTTS` from `../macos`, unchanged, speaking
through voice-core (espeak-ng 724808c and ONNX Runtime 1.24.2). Only the
window is new. It is the cross-platform plan's first native shell, meant to
replace the Electron build in `../cross-platform` once it holds the same
fixtures and runs on the Steam Deck and Mint.

    ./start.sh

offers what is missing (Enter means yes), builds, and opens the window. GTK4
and libadwaita come from your distribution and need root, so their command is
printed, not run. ONNX Runtime is fetched into your own data folder. A Swift
toolchain builds it: <https://www.swift.org/install/linux/>.

**Without building it.** Every change to `linux/` leaves a ready bundle
(`voice-forge-linux`, kept a week) on its run of the `linux` workflow, under
Artifacts. Unpack it anywhere in your home folder and run

    voice-forge-linux/voice-forge            # the window
    voice-forge-linux/voice-forge measure    # this machine's numbers, saved beside it

It carries the voice, espeak-ng's data, ONNX Runtime and the Swift runtime.
GTK4 and libadwaita come from the system when it has them. SteamOS has
neither, so there it offers GNOME's Flatpak runtime instead (Enter means yes),
installed into your own account without root. CI runs that path too, on a
machine with no GTK at all.

What it does now: the script on the left, Pace, Variation, Cadence and the
two gaps on the right, Render, Play, Stop and Export (WAV, loudness-matched,
as the Mac app exports). Not yet: the pronunciation dictionary, expressions,
the voice library and installing voices, saved sessions.

## Measured (CI, ubuntu-latest, Swift 6.4)

| | native | Electron |
|---|---|---|
| download, `.tar.gz` | 101 MB | 376 MB (`Voice-Forge-x64.tar.gz`) |
| unpacked | 183 MB | |
| first frame, warm | 300–450 ms | not measured yet |
| first frame, cold | 3.5–4 s on CI's disk | not measured yet |
| rendering | 17–27× real time | |

Of the 183 MB, the voice and espeak-ng's data are 86 MB (Electron carries the
same), the Swift runtime 76 MB (mostly ICU's data), ONNX Runtime 22 MB, and
the app under 1 MB. `.github/workflows/linux.yml` measures all of it on every
change: `VoiceForgeGTK --measure-render` renders without a window, and
`--measure-startup` prints the first frame's time after the process started.
The start-up figures that decide this are the ones from a Steam Deck and a
Mint machine, side by side with the Electron build.
