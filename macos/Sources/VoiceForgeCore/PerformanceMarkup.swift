import Foundation

/// Hand-editable performance directions which live in the script rather than
/// in an invisible timeline. They alter the phoneme stream but never split a
/// sentence into another model call.
public enum PerformanceBeat: String, CaseIterable, Sendable {
    case short
    case medium
    case long

    /// Pads are the honest unit here. Their duration belongs to the voice and
    /// its surrounding phonemes, just like the existing clause-padding dial.
    public var pads: Int {
        switch self {
        case .short: 3
        case .medium: 6
        case .long: 12
        }
    }

    public var cue: String {
        switch self {
        case .short: "[[beat:short]]"
        case .medium: "[[beat]]"
        case .long: "[[beat:long]]"
        }
    }
}

public enum PerformanceToken: Equatable, Sendable {
    case text(String, focused: Bool)
    case beat(PerformanceBeat)
}

public enum PerformanceMarkup {
    /// Parse `*phrase focus*` and the three named beat forms. An unmatched `*`
    /// stays literal rather than silently eating the rest of somebody's copy.
    public static func parse(_ source: String) -> [PerformanceToken] {
        var tokens: [PerformanceToken] = []
        var plain = ""
        var i = source.startIndex

        func flush() {
            guard !plain.isEmpty else { return }
            appendText(plain, focused: false, to: &tokens)
            plain = ""
        }

        while i < source.endIndex {
            if let (beat, end) = beat(at: i, in: source) {
                flush()
                tokens.append(.beat(beat))
                i = end
                continue
            }

            if source[i] == "*" {
                let after = source.index(after: i)
                if after < source.endIndex, !source[after].isWhitespace,
                   let close = source[after...].firstIndex(of: "*"), close > after,
                   !source[source.index(before: close)].isWhitespace {
                    flush()
                    appendText(String(source[after ..< close]), focused: true, to: &tokens)
                    i = source.index(after: close)
                    continue
                }
            }

            plain.append(source[i])
            i = source.index(after: i)
        }
        flush()
        return tokens
    }

    /// What is actually said, with directions removed and enough whitespace
    /// left at a beat to keep adjacent words from running together.
    public static func spokenText(_ source: String) -> String {
        let pieces = parse(source).map { token -> String in
            switch token {
            case .text(let text, _): text
            case .beat: " "
            }
        }
        return pieces.joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func wordCount(_ source: String) -> Int {
        spokenText(source).split(whereSeparator: \.isWhitespace).count
    }

    public static func cueCounts(_ source: String) -> (focus: Int, beats: Int) {
        var focus = 0, beats = 0
        for token in parse(source) {
            switch token {
            case .text(_, let focused): if focused { focus += 1 }
            case .beat: beats += 1
            }
        }
        return (focus, beats)
    }

    private static func appendText(_ text: String, focused: Bool,
                                   to tokens: inout [PerformanceToken]) {
        guard !text.isEmpty else { return }
        if case .text(let previous, let wasFocused)? = tokens.last,
           wasFocused == focused {
            tokens[tokens.count - 1] = .text(previous + text, focused: focused)
        } else {
            tokens.append(.text(text, focused: focused))
        }
    }

    private static func beat(at index: String.Index, in source: String)
        -> (PerformanceBeat, String.Index)? {
        guard source[index] == "[" else { return nil }
        // Inspect only the longest possible cue, not the entire remaining
        // script at every character (which made ordinary prose quadratic).
        let rest = source[index...].prefix(15).lowercased()
        let candidates: [(String, PerformanceBeat)] = [
            ("[[beat:short]]", .short),
            ("[[beat:medium]]", .medium),
            ("[[beat:long]]", .long),
            ("[[beat]]", .medium),
        ]
        for (cue, beat) in candidates where rest.hasPrefix(cue) {
            return (beat, source.index(index, offsetBy: cue.count))
        }
        return nil
    }
}
