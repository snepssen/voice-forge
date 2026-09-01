import SwiftUI

@main
struct VoiceForgeApp: App {
    @StateObject private var studio = Studio()

    var body: some Scene {
        WindowGroup("Voice Forge") {
            Workbench()
                .environmentObject(studio)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
                .tint(Monokai.purple)
        }
        .defaultSize(width: 1240, height: 820)
    }
}
