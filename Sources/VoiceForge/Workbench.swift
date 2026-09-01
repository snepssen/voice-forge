import SwiftUI
import UniformTypeIdentifiers
import VoiceForgeCore
import VoiceForgeTTS

struct Workbench: View {
    @EnvironmentObject var studio: Studio
    @State private var exporting = false

    var body: some View {
        HSplitView {
            script.frame(minWidth: 420, idealWidth: 620)
            controls.frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
        }
        .background(Monokai.bg)
        .task { studio.load() }
        .onChange(of: studio.voice) { _, _ in studio.voiceChanged() }
        .onChange(of: studio.settings) { _, _ in studio.save() }
        .onChange(of: studio.text) { _, _ in studio.save() }
        .toolbar { toolbar }
        .sheet(isPresented: $studio.showingDictionary) {
            DictionaryView().environmentObject(studio)
        }
        .fileExporter(isPresented: $exporting,
                      document: WAVDocument(),
                      contentType: .wav,
                      defaultFilename: "voiceover") { result in
            if case .success(let url) = result { studio.exportTake(to: url) }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let busy = studio.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(Monokai.comment)
                }
            }
            Button { Task { await studio.renderAll() } } label: { Label("Render", systemImage: "waveform") }
                .disabled(studio.busy != nil || studio.script.isEmpty)
            Button { studio.play() } label: { Label("Play", systemImage: "play.fill") }
                .disabled(studio.rendered.isEmpty)
            Button { studio.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(studio.rendered.isEmpty)
            Button { studio.showingDictionary = true } label: {
                Label("Dictionary", systemImage: "character.book.closed")
            }
            .help("How this voice says particular words")
            Button { exporting = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(studio.rendered.isEmpty)
        }
    }

    // MARK: left — the script and what it became

    private var script: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                voicePanel
                Panel(title: "Script", trailing: summary) {
                    TextEditor(text: $studio.text)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
                        .frame(minHeight: 150)
                    Text("A blank line starts a new paragraph. Each sentence becomes one call to the model — never more, never less.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = studio.error {
                    Text(error).font(.caption).foregroundStyle(Monokai.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 7))
                }
                if !studio.rendered.isEmpty { take }
            }
            .padding(14)
        }
    }

    /// The voice, said plainly rather than left to a toolbar control.
    ///
    /// It was in the toolbar first and rendered as an empty dropdown -- which
    /// is the worst possible failure for this particular control, because an
    /// empty voice picker and a voice picker that failed to find any voices
    /// look identical. Here it states what loaded, and at what rate, so
    /// "nothing found" cannot be mistaken for "nothing selected".
    private var voicePanel: some View {
        Panel(title: "Voice", trailing: studio.voices.isEmpty ? nil : "\(Int(studio.sampleRate)) Hz") {
            if studio.voices.isEmpty {
                Text("No voice models are bundled with this build.")
                    .foregroundStyle(Monokai.red)
            } else {
                Picker("", selection: $studio.voice) {
                    ForEach(studio.voices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if let note = VoiceNotes.note(studio.voice) {
                    Text(note.summary)
                        .font(.caption).foregroundStyle(Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("The same speaker either way. Switching re-renders nothing on its own — press Render.")
                    .font(.caption).foregroundStyle(Monokai.comment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summary: String {
        let s = studio.script
        return "\(s.sentences.count) sentence\(s.sentences.count == 1 ? "" : "s") · \(s.wordCount) words"
    }

    private var take: some View {
        Panel(title: "The take", trailing: timing) {
            HStack(spacing: 14) {
                Stat("length", String(format: "%.1fs", studio.totalSeconds))
                Stat("speech", String(format: "%.1fs", studio.spokenSeconds))
                Stat("silence", String(format: "%.1fs", studio.silentSeconds))
                Stat("pace", String(format: "%.0f wpm", studio.wordsPerMinute),
                     note: paceNote)
                Stat("loudness", studio.takeLUFS.isFinite
                     ? String(format: "%.1f LUFS", studio.takeLUFS) : "—",
                     note: studio.takeLUFS.isFinite ? "at the model's rate" : nil)
            }
            Divider().overlay(Monokai.inset)
            ForEach(studio.rendered, id: \.id) { r in
                SentenceRow(r: r, selected: studio.selected == r.id)
                    .onTapGesture { studio.selected = studio.selected == r.id ? nil : r.id }
            }
        }
    }

    /// Voiceover reads sit around 150 wpm; audiobooks nearer 155; anything
    /// past 180 is a fast read. Said as orientation, not as a rule -- there is
    /// nothing wrong with a fast read, but it is worth knowing you have one.
    private var paceNote: String? {
        let wpm = studio.wordsPerMinute
        guard wpm > 0 else { return nil }
        if wpm > 185 { return "a fast read; 150 is typical" }
        if wpm < 120 { return "a slow read; 150 is typical" }
        return "around the usual 150"
    }

    private var timing: String {
        studio.silentSeconds > 0
            ? String(format: "%.0f%% of it is silence", studio.silentSeconds / max(studio.totalSeconds, 0.001) * 100)
            : ""
    }

    // MARK: right — the dials

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { pauses; scales; advanced; exportPanel }
                .padding(14)
        }
    }

    private var pauses: some View {
        Panel(title: "Pauses") {
            Dial(label: "Between sentences", value: $studio.settings.sentenceGap,
                 range: SynthesisSettings.sentenceGapRange, step: 0.01, format: "%.2f s",
                 note: "Real silence laid between two calls to the model. Exact.",
                 reference: 0.08)
            Dial(label: "At a paragraph", value: $studio.settings.paragraphGap,
                 range: SynthesisSettings.paragraphGapRange, step: 0.05, format: "%.2f s",
                 note: "Replaces the sentence gap at a blank line rather than adding to it.",
                 reference: 0.55)
            Divider().overlay(Monokai.inset)
            StepDial(label: "Room at a comma", value: $studio.settings.clausePads,
                     range: SynthesisSettings.clausePadsRange,
                     note: clauseNote)
            calibrationRow
        }
    }

    private var clauseNote: String {
        guard let cal = studio.calibration else {
            return "Padding phonemes given to the model at , ; : and —. Measure the voice to see what they buy."
        }
        return cal.clausePauseDescription(pads: studio.settings.clausePads)
    }

    @ViewBuilder private var calibrationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cal = studio.calibration {
                HStack(spacing: 10) {
                    ForEach(cal.marks) { m in
                        VStack(spacing: 1) {
                            Text(m.mark).font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Monokai.fg)
                            Text(String(format: "%.0f", m.mean * 1000))
                                .monospacedDigit().foregroundStyle(Monokai.yellow)
                            Text("ms").font(.caption2).foregroundStyle(Monokai.comment)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(8)
                .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
                Text("Measured on this voice, by rendering each line with and without the mark and subtracting. The spread across the probe set is wide — the model decides in context — so these are central, not exact.")
                    .font(.caption2).foregroundStyle(Monokai.comment)
                    .fixedSize(horizontal: false, vertical: true)
                if studio.calibrationIsStale {
                    Text("Measured at a different voice or pace. Measure again.")
                        .font(.caption).foregroundStyle(Monokai.orange)
                }
            }
            Button {
                Task { await studio.calibrate() }
            } label: {
                Text(studio.calibration == nil ? "Measure this voice" : "Measure again")
                    .frame(maxWidth: .infinity)
            }
            .disabled(studio.busy != nil)
            if studio.busy == "Measuring" {
                ProgressView(value: studio.progress).tint(Monokai.purple)
            }
        }
    }

    private var scales: some View {
        Panel(title: "The model") {
            Dial(label: "Pace", value: $studio.settings.lengthScale,
                 range: SynthesisSettings.lengthScaleRange, step: 0.01, format: "%.2f",
                 note: VoiceNotes.paceNote(voice: studio.voice, lengthScale: studio.settings.lengthScale),
                 reference: 1.0)
            Dial(label: "Variation", value: $studio.settings.noiseScale,
                 range: SynthesisSettings.noiseScaleRange, step: 0.01, format: "%.3f",
                 note: "How much the sound differs between takes. Not pace, and not pausing.",
                 reference: 0.667)
            Dial(label: "Cadence variation", value: $studio.settings.noiseW,
                 range: SynthesisSettings.noiseWRange, step: 0.01, format: "%.2f",
                 note: "How much the rhythm differs between takes. At zero, two takes of a line are near-identical — repeatable, and noticeably mechanical.",
                 reference: 0.8)
        }
    }

    private var advanced: some View {
        Panel(title: "Endings") {
            StepDial(label: "Trailing padding", value: $studio.settings.trailingPads,
                     range: SynthesisSettings.trailingPadsRange,
                     note: "2 is a measured optimum, not a floor. These voices end on breath rather than silence; padding gives the decay somewhere to land. Three is worse than two.")
            Toggle("Drop the final full stop", isOn: $studio.settings.dropFinalFullStop)
                .foregroundStyle(Monokai.fg)
            Text("The voice learned \"the recording stops here\" at the full stop and reproduces whatever sat at that cut — heard as a phantom consonant after the words end. ? and ! are always kept.")
                .font(.caption).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exportPanel: some View {
        Panel(title: "Export") {
            Picker("Rate", selection: $studio.export.sampleRate) {
                ForEach(Audio.exportRates, id: \.self) { r in
                    Text(r == Audio.modelSampleRate ? "\(Int(r)) Hz · the model's own" : "\(Int(r)) Hz").tag(r)
                }
            }
            Picker("Depth", selection: $studio.export.depth) {
                ForEach(Export.Depth.allCases) { Text($0.rawValue).tag($0) }
            }
            Text(studio.export.depth.note).font(.caption).foregroundStyle(Monokai.comment)
            Picker("Loudness", selection: Binding(
                get: { studio.export.targetLUFS ?? .nan },
                set: { studio.export.targetLUFS = $0.isNaN ? nil : $0 })) {
                ForEach(Loudness.targets) { t in
                    Text(t.name).tag(t.lufs)
                }
            }
            if let t = Loudness.targets.first(where: {
                ($0.lufs.isNaN && studio.export.targetLUFS == nil) || $0.lufs == studio.export.targetLUFS
            }) {
                Text(t.note).font(.caption).foregroundStyle(Monokai.comment)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let p = studio.exportPreview { preview(p) }
            if let r = studio.lastReceipt { receipt(r) }
        }
        .onChange(of: studio.export) { _, _ in studio.refreshPreview(); studio.save() }
    }

    /// What exporting will do, before it does it.
    ///
    /// Reaching a streaming target from a single dry voice usually needs about
    /// +10 dB, and the true-peak ceiling will not allow it -- so the export
    /// lands short. Holding at the ceiling is the right behaviour, but finding
    /// out afterwards is the wrong order, and every number involved is knowable
    /// in advance.
    private func preview(_ p: Export.Preview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Monokai.inset)
            HStack(spacing: 14) {
                Stat("as rendered", String(format: "%.1f LUFS", p.lufs))
                Stat("true peak", String(format: "%.1f dBTP", p.truePeak))
                Stat("on export", String(format: "%.1f LUFS", p.resultingLUFS))
            }
            if p.heldBack {
                Text(String(format: "%.1f dB short of the target: the true-peak ceiling stops the gain first. A dry voice with hard consonants and real silences cannot reach a streaming target on gain alone — that needs compression, which this app does not do. The file will be correct, just quieter.", p.shortfall))
                    .font(.caption).foregroundStyle(Monokai.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if studio.export.targetLUFS != nil {
                Text("The target is reachable on gain alone.")
                    .font(.caption).foregroundStyle(Monokai.green)
            }
        }
    }

    private func receipt(_ r: Export.Receipt) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().overlay(Monokai.inset)
            Text(r.url.lastPathComponent).foregroundStyle(Monokai.fg)
            Text(String(format: "%.1fs · %.0f kHz · %@ · %.1f LUFS · true peak %.1f dBTP",
                        r.seconds, r.sampleRate / 1000, r.depth.rawValue,
                        r.lufsAfter, r.truePeakAfter))
                .font(.caption).monospacedDigit().foregroundStyle(Monokai.comment)
            if r.heldBackByCeiling {
                Text("Held back by the true-peak ceiling, so it is quieter than the target. A voice with hard consonants and long silences cannot reach a streaming target on gain alone — that needs compression, which this app does not do.")
                    .font(.caption).foregroundStyle(Monokai.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if r.clippedSamples > 0 {
                Text("\(r.clippedSamples) samples clipped.")
                    .font(.caption).foregroundStyle(Monokai.red)
            }
        }
    }
}

private struct Stat: View {
    var label: String, value: String, note: String?
    init(_ l: String, _ v: String, note: String? = nil) { label = l; value = v; self.note = note }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).monospacedDigit().foregroundStyle(Monokai.fg)
            Text(label).font(.caption2).foregroundStyle(Monokai.comment)
            if let note {
                Text(note).font(.caption2).foregroundStyle(Monokai.comment.opacity(0.75))
            }
        }
    }
}

private struct SentenceRow: View {
    @EnvironmentObject var studio: Studio
    var r: RenderedSentence
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(r.text)
                    .foregroundStyle(selected ? Monokai.purple : Monokai.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(String(format: "%.2fs", r.seconds))
                    .monospacedDigit().font(.caption).foregroundStyle(Monokai.comment)
            }
            if selected {
                HStack(spacing: 12) {
                    Text(String(format: "%.0f wpm", r.wordsPerMinute))
                    Text(String(format: "peak %.1f dBFS", r.peakDBFS))
                    if r.trailingGap > 0 { Text(String(format: "+%.2fs gap", r.trailingGap)) }
                    Spacer()
                    Button("Play") { studio.playOne(r.id) }.controlSize(.small)
                    Button("Re-roll") { Task { await studio.reroll(r.id) } }
                        .controlSize(.small)
                        .help("Render this sentence again. The model is stochastic, so it is a different take.")
                }
                .font(.caption).monospacedDigit().foregroundStyle(Monokai.comment)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// The exporter needs a document type; the real writing is done by
/// `Studio.exportTake` against the chosen URL, because it has to report a
/// receipt and a `FileDocument` cannot.
struct WAVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    init() {}
    init(configuration: ReadConfiguration) throws {}
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}
