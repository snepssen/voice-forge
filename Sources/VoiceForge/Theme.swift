import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Monokai, the same palette Gateway Forge uses, and the same rule about what
/// colour means: gray = unavailable · orange = pending · red = error ·
/// green = fine · purple = active. Never an ad-hoc colour.
enum Monokai {
    static let bg      = Color(hex: 0x272822)
    static let panel   = Color(hex: 0x31322B)
    static let inset   = Color(hex: 0x3E3D32)
    static let fg      = Color(hex: 0xF8F8F2)
    static let comment = Color(hex: 0x75715E)
    static let yellow  = Color(hex: 0xE6DB74)
    static let orange  = Color(hex: 0xFD971F)
    static let red     = Color(hex: 0xF92672)
    static let green   = Color(hex: 0xA6E22E)
    static let purple  = Color(hex: 0xAE81FF)
    static let cyan    = Color(hex: 0x66D9EF)
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
