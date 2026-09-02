import Foundation

/// Where this app keeps things, on each platform it will run on.
///
/// Written with the port in mind rather than after it. `FileManager`'s
/// `.applicationSupportDirectory` resolves on Linux too, but to
/// `~/.local/share`, ignoring `XDG_DATA_HOME` — and on Windows swift-corelibs
/// has historically pointed it somewhere unhelpful. Each platform's own
/// convention is cheap to honour here and expensive to retrofit once people
/// have files in the wrong place.
public enum AppDirectories {

    public static let productName = "Voice Forge"

    /// The writable home for settings, the global dictionary and installed
    /// voices.
    public static var support: URL {
        let base: URL
        #if os(macOS)
        base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first
            ?? home.appending(path: "Library/Application Support")
        return base.appending(path: productName)
        #elseif os(Windows)
        // %APPDATA% is the roaming profile, which is where per-user
        // application data belongs on Windows.
        if let appData = ProcessInfo.processInfo.environment["APPDATA"], !appData.isEmpty {
            base = URL(fileURLWithPath: appData)
        } else {
            base = home.appending(path: "AppData/Roaming")
        }
        return base.appending(path: productName)
        #else
        // XDG. The spec says data goes in XDG_DATA_HOME, defaulting to
        // ~/.local/share, and a lowercase hyphenated name is the convention.
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = home.appending(path: ".local/share")
        }
        return base.appending(path: "voice-forge")
        #endif
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Voices the listener has installed. One flat folder of Piper exports.
    public static var voices: URL { support.appending(path: "Voices") }

    public static var session: URL { support.appending(path: "session.json") }
    public static var pronunciation: URL { support.appending(path: "pronunciation.json") }

    /// Create the directories, ignoring failure — a missing folder shows up as
    /// "no installed voices", which is the right thing to display anyway, and
    /// is better than refusing to start.
    public static func ensure() {
        for dir in [support, voices] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
