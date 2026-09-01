// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Voice Forge — the Piper/VITS engine built for Gateway Forge, on its own, with
// its controls exposed instead of settled.
//
// The same two dependencies, confined to VoiceForgeTTS for the same reason:
// `vfcheck` is a plain executable that asserts and exits non-zero, and it must
// never link the TTS stack. That rule is what keeps the checks fast and
// toolchain-independent, and it is worth more here than in the app it came
// from — this project's whole subject is what the engine does, so the harness
// that measures it has to be the cheap part.
//
// Nothing depends on Gateway Forge and nothing is shared with it. The engine
// files were copied, not linked: the two apps want different things from the
// same model — one wants a settled voice that never changes under a listener's
// tape, the other wants every dial on the outside — and a shared target would
// have to serve both. Divergence should be a deliberate edit visible in this
// project's own history.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let espeakLibDir = packageRoot.appending(path: "Sources/CEspeakNG/lib").path

let package = Package(
    name: "VoiceForge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"),
    ],
    targets: [
        // Headers + a vendored static lib, no compiled source of its own.
        .target(name: "CEspeakNG",
                linkerSettings: [
                    .unsafeFlags(["-L\(espeakLibDir)", "-lespeak-ng", "-lucd"]),
                ]),
        // Everything that can be decided without loading a model: the script
        // model, the pause plan, loudness measurement, export settings. This
        // is where the interesting arithmetic lives, and it is all reachable
        // from `vfcheck`.
        .target(name: "VoiceForgeCore"),
        // The synthesiser. Kept apart so the harness stays light.
        .target(name: "VoiceForgeTTS",
                dependencies: [
                    "VoiceForgeCore",
                    "CEspeakNG",
                    .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                ],
                // Two voices ship. Named individually rather than copying the
                // directory, so adding one is a deliberate edit here and a
                // stray file cannot ride along into the bundle.
                resources: [
                    .copy("Resources/en_US-snepssen-suno-medium.onnx"),
                    .copy("Resources/en_US-snepssen-suno-medium.onnx.json"),
                    .copy("Resources/en_US-snepssen-rode-medium.onnx"),
                    .copy("Resources/en_US-snepssen-rode-medium.onnx.json"),
                    .copy("Resources/espeak-ng-data"),
                ]),
        .executableTarget(name: "VoiceForge", dependencies: ["VoiceForgeCore", "VoiceForgeTTS"]),
        // Never depends on VoiceForgeTTS. Keep it that way.
        .executableTarget(name: "vfcheck", dependencies: ["VoiceForgeCore"]),
        // The render primitive, and the measurement rig: the only place a
        // model is actually loaded outside the app.
        .executableTarget(name: "vfrender", dependencies: ["VoiceForgeCore", "VoiceForgeTTS"]),
    ]
)
