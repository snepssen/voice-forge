import AppKit
import SwiftUI

/// How the listener wants the app to look.
enum Appearance: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
    }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    /// The AppKit appearance to force app-wide so the raw `NSColor` dynamic
    /// providers below (Monokai) resolve the same way `.preferredColorScheme`
    /// sets the SwiftUI environment. The two mechanisms don't talk to each
    /// other -- a dynamic `NSColor` resolves against the window's actual
    /// `NSAppearance`, not SwiftUI's color-scheme environment value -- so
    /// without this, toggling the in-app control changes nothing on screen.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Monokai, and a light companion that keeps its hues.
///
/// **Every colour is one dynamic value, so nothing else in the app changed.**
/// The alternative was threading a palette through the environment and
/// rewriting some two hundred call sites, which would have been a large diff to
/// accomplish what AppKit already does: an `NSColor` built with a dynamic
/// provider resolves itself against whatever appearance the window is in. The
/// toggle sets the window's appearance and the colours follow.
///
/// This is the one deliberately Apple-only thing in the app, and it is the
/// right trade while the UI is SwiftUI. A port draws its own pixels and will
/// carry these hex values across rather than this mechanism.
///
/// The light side is not an inversion. Monokai's character is its hues against
/// a warm ground, so the ground stays warm and the hues are darkened until they
/// carry on paper — a straight inversion gives the washed-out pastel look that
/// makes a light theme feel like an afterthought.
enum Monokai {
    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }

    static let bg      = dynamic(dark: 0x272822, light: 0xFAF8F0)
    static let panel   = dynamic(dark: 0x31322B, light: 0xF1EEE1)
    static let inset   = dynamic(dark: 0x3E3D32, light: 0xE2DECD)
    static let fg      = dynamic(dark: 0xF8F8F2, light: 0x272822)
    static let comment = dynamic(dark: 0x75715E, light: 0x8A8672)
    static let yellow  = dynamic(dark: 0xE6DB74, light: 0x8A7500)
    static let orange  = dynamic(dark: 0xFD971F, light: 0xB35C00)
    static let red     = dynamic(dark: 0xF92672, light: 0xC2185B)
    static let green   = dynamic(dark: 0xA6E22E, light: 0x4F7A00)
    static let purple  = dynamic(dark: 0xAE81FF, light: 0x6A3FD4)
    static let cyan    = dynamic(dark: 0x66D9EF, light: 0x00697F)
}

/// A titled panel. Every box in this app is one, so the spacing is decided
/// once rather than per view.
struct Panel<Content: View>: View {
    var title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                if let trailing {
                    Text(trailing).font(.caption).foregroundStyle(Monokai.comment)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A dial: a slider, the value, and — the reason this app exists — a line
/// underneath saying what the number actually means.
struct Dial: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.01
    var format: String = "%.2f"
    var note: String
    /// Shown in cyan when the value is the one the voice was measured or
    /// configured at, so leaving it alone reads as a decision rather than as
    /// not having touched it.
    var reference: Double? = nil

    private var atReference: Bool {
        guard let reference else { return false }
        return abs(value - reference) < step / 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).foregroundStyle(Monokai.fg)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(atReference ? Monokai.cyan : Monokai.yellow)
                if reference != nil, !atReference {
                    Button {
                        value = reference!
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .foregroundStyle(Monokai.comment)
                    .help("Back to the voice's own value")
                }
            }
            Slider(value: $value, in: range, step: step)
            Text(note)
                .font(.caption).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The same, for a dial that counts rather than measures.
struct StepDial: View {
    var label: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).foregroundStyle(Monokai.fg)
                Spacer()
                Text("\(value)").monospacedDigit().foregroundStyle(Monokai.yellow)
                Stepper("", value: $value, in: range).labelsHidden()
            }
            Text(note)
                .font(.caption).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
