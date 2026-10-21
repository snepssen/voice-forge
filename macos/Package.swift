// swift-tools-version: 6.0
import PackageDescription

// Voice Forge — the Piper/VITS engine built for Gateway Forge, on its own, with
// its controls exposed instead of settled.
//
// The engine's dependency is confined to VoiceForgeTTS: `vfcheck` is a plain
// executable that asserts and exits non-zero, and it must never link the TTS
// stack. That rule is what keeps the checks fast and toolchain-independent,
// and it is worth more here than in the app it came from — this project's
// whole subject is what the engine does, so the harness that measures it has
// to be the cheap part.
//
// The mechanism is shared, the taste is not (2026-10-14). espeak-ng and its
// data, the phonemizer and the Piper inference call come from voice-core,
// which Gateway Forge and the Interpreter use too: the copies had drifted
// into three espeak builds and three phonemizers of the same pinned revision.
// What made this app different stays here: no respellings, the token layout,
// the duration dials, the padding and pause decisions. voice-core's tests
// hold its English phonemes word for word to what this app's own build gave,
// and a release there reaches here only through `vfcheck`.

let package = Package(
    name: "VoiceForge",
    // iOS for companion-core, which speaks through this engine on iPhone and
    // iPad; nothing in VoiceForgeCore or VoiceForgeTTS is Mac-only.
    platforms: [.macOS(.v14), .iOS(.v17)],
    // The engine and its arithmetic, for other apps to read through: the
    // companion uses the automatic reading and the lift, not this app's UI.
    products: [
        .library(name: "VoiceForgeCore", targets: ["VoiceForgeCore"]),
        .library(name: "VoiceForgeTTS", targets: ["VoiceForgeTTS"]),
    ],
    dependencies: [
        .package(url: "https://github.com/snepssen/voice-core", from: "1.0.1"),
    ],
    targets: [
        // Everything that can be decided without loading a model: the script
        // model, the pause plan, loudness measurement, export settings. This
        // is where the interesting arithmetic lives, and it is all reachable
        // from `vfcheck`.
        .target(name: "VoiceForgeCore"),
        // The synthesiser. Kept apart so the harness stays light.
        .target(name: "VoiceForgeTTS",
                dependencies: [
                    "VoiceForgeCore",
                    .product(name: "VoiceCore", package: "voice-core"),
                ],
                // One voice ships, named individually rather than by copying
                // the directory, so adding one is a deliberate edit here and a
                // stray file cannot ride along into the bundle. Everything else
                // a listener uses is installed into their voices folder, which
                // is not part of the build. espeak-ng's data rides in
                // voice-core's own resource bundle.
                resources: [
                    .copy("Resources/en_US-snepssen-medium.onnx"),
                    .copy("Resources/en_US-snepssen-medium.onnx.json"),
                ]),
        .executableTarget(name: "VoiceForge", dependencies: ["VoiceForgeCore", "VoiceForgeTTS"]),
        // Never depends on VoiceForgeTTS. Keep it that way.
        .executableTarget(name: "vfcheck", dependencies: ["VoiceForgeCore"]),
        // The render primitive, and the measurement rig: the only place a
        // model is actually loaded outside the app.
        .executableTarget(name: "vfrender", dependencies: ["VoiceForgeCore", "VoiceForgeTTS"]),
    ]
)
