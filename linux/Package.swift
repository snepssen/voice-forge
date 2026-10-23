// swift-tools-version: 6.0
import PackageDescription

// Voice Forge on Linux: a GTK4 + libadwaita window over the same engine the
// Mac app uses. VoiceForgeCore and VoiceForgeTTS come from ../macos as they
// are; only the window is new. The plan's P5 prototype, measured against the
// Electron build it is meant to replace (size, start-up), on the same fixtures.
let package = Package(
    name: "VoiceForgeLinux",
    dependencies: [
        .package(path: "../macos"),
    ],
    targets: [
        // GTK4 and libadwaita's C APIs, imported directly: no binding layer.
        .systemLibrary(
            name: "CGtk",
            pkgConfig: "gtk4 libadwaita-1",
            providers: [.apt(["libgtk-4-dev", "libadwaita-1-dev"]),
                        .brew(["gtk4", "libadwaita"])]),
        .executableTarget(
            name: "VoiceForgeGTK",
            dependencies: [
                "CGtk",
                .product(name: "VoiceForgeCore", package: "macos"),
                .product(name: "VoiceForgeTTS", package: "macos"),
            ]),
    ],
    // GTK's callbacks arrive on its own main loop, as C functions; Swift 6's
    // actor checking has nothing to say about that loop that would be true.
    swiftLanguageModes: [.v5]
)
