import Foundation

/// Where a voice came from and whether it is complete.
///
/// One voice ships with the app. Everything else is the listener's own — a
/// Piper model they trained or downloaded, dropped into the voices folder. The
/// bundled one is not privileged beyond being present: it loads by the same
/// path, is validated by the same rules, and can be hidden behind a better one.
public struct VoiceProfile: Equatable, Sendable, Identifiable {
    public var id: String { name }
    /// The name shown and stored. Derived from the filename, never typed.
    public var name: String
    public var modelURL: URL
    public var configURL: URL
    public var isBundled: Bool

    public init(name: String, modelURL: URL, configURL: URL, isBundled: Bool) {
        self.name = name; self.modelURL = modelURL
        self.configURL = configURL; self.isBundled = isBundled
    }
}

/// Why a candidate voice was refused.
///
/// Refusals are named rather than silent. Somebody who has just spent hours
/// training a model and dropped it in the folder deserves to be told which
/// file is missing, not to find their voice absent from a menu.
public enum VoiceRejection: Equatable, Sendable {
    case missingConfig(model: String)
    case missingModel(config: String)

    public var message: String {
        switch self {
        case .missingConfig(let m):
            "\(m) has no matching .onnx.json beside it. Piper exports the two together; copy both."
        case .missingModel(let c):
            "\(c) has no matching .onnx beside it. Copy the model file too."
        }
    }
}

/// What a folder of files amounts to.
///
/// Pure, so the rules are checkable without a filesystem or a model: given the
/// names in a directory, which voices are there and what is wrong with the rest.
public enum VoiceLibrary {

    /// Piper's own naming, which is what an exported voice already has:
    /// `<locale>-<name>-<quality>.onnx`. The name is the middle field.
    ///
    /// Kept permissive on purpose. A voice somebody trained might be
    /// `en_GB-alice-high` or `de_DE-hans-low`, and refusing it for not being
    /// `en_US`/`medium` would reject perfectly good models to enforce a
    /// convention this app has no stake in.
    public static func voiceName(fromModelFile file: String) -> String? {
        guard file.hasSuffix(".onnx") else { return nil }
        let stem = String(file.dropLast(".onnx".count))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3 else {
            // No locale/quality convention at all -- take the stem whole, so a
            // plainly named `myvoice.onnx` still works.
            return stem.isEmpty ? nil : stem
        }
        return parts[1 ..< (parts.count - 1)].joined(separator: "-")
    }

    public static func configFile(forModelFile file: String) -> String {
        file + ".json"
    }

    /// Sort out a directory listing into voices and complaints.
    ///
    /// - Parameter files: bare filenames in one directory.
    public static func scan(files: [String], in directory: URL, bundled: Bool)
        -> (voices: [VoiceProfile], rejected: [VoiceRejection]) {
        let present = Set(files)
        var voices: [VoiceProfile] = []
        var rejected: [VoiceRejection] = []

        for file in files.sorted() where file.hasSuffix(".onnx") {
            guard let name = voiceName(fromModelFile: file) else { continue }
            let config = configFile(forModelFile: file)
            guard present.contains(config) else {
                rejected.append(.missingConfig(model: file)); continue
            }
            voices.append(VoiceProfile(name: name,
                                       modelURL: directory.appending(path: file),
                                       configURL: directory.appending(path: config),
                                       isBundled: bundled))
        }
        // A config with no model is the other half of the same mistake.
        for file in files.sorted() where file.hasSuffix(".onnx.json") {
            let model = String(file.dropLast(".json".count))
            if !present.contains(model) { rejected.append(.missingModel(config: file)) }
        }
        return (voices, rejected)
    }

    /// Merge bundled and installed voices into one list.
    ///
    /// **An installed voice of the same name wins.** That is what makes the
    /// bundled voice unprivileged: somebody who retrains `snepssen` and drops
    /// it in gets their version, without having to pick a different name to
    /// escape ours.
    public static func merge(bundled: [VoiceProfile], installed: [VoiceProfile]) -> [VoiceProfile] {
        var byName: [String: VoiceProfile] = [:]
        for v in bundled { byName[v.name] = v }
        for v in installed { byName[v.name] = v }
        return byName.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
