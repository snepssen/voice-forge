import SwiftUI
import VoiceForgeCore

/// The pronunciation table.
///
/// Opened from the toolbar, because it is a place you go rather than a dial you
/// nudge — and because most scripts never need it. espeak is right most of the
/// time; it got *Siobhan* to `ʃɪvˈɔːn` unaided. What breaks is proper nouns,
/// brand names, acronyms and homographs, so the table starts from the words in
/// your script rather than from an empty field.
struct DictionaryView: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @State private var adding = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Monokai.inset)
            if studio.dictionary.entries.isEmpty { empty } else { table }
            Divider().overlay(Monokai.inset)
            footer
        }
        // **Bounded, and scrolling inside.** The sheet used to size itself to
        // its contents, so each new entry made the window taller until a long
        // dictionary ran off the bottom of the screen with no way back. A
        // table is a thing you scroll, not a thing that grows.
        .frame(minWidth: 760, idealWidth: 820,
               minHeight: 420, idealHeight: 560, maxHeight: 720)
        .background(Monokai.bg)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pronunciation").font(.title3).foregroundStyle(Monokai.fg)
                Text("What you type is handed straight to the model — it speaks IPA, so this is not a translation step.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing here yet.").foregroundStyle(Monokai.fg)
            Text("Add a word below, or take one from the script. Only add what comes out wrong — espeak reads most things correctly on its own, including names it has no business knowing.")
                .font(.caption).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
            suggestions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }

    private var table: some View {
        VStack(spacing: 0) {
            columnHeadings
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($studio.dictionary.entries) { $entry in
                        EntryRow(entry: $entry)
                        Divider().overlay(Monokai.inset.opacity(0.5))
                    }
                }
            }
            // Held out of the scrolling rows: the headings stay put, the rows
            // scroll under them, and the suggestions stay reachable at the
            // bottom instead of being buried under a hundred entries.
            if !studio.candidateWords.isEmpty {
                Divider().overlay(Monokai.inset)
                ScrollView { suggestions.padding(12) }
                    .frame(maxHeight: 96)
            }
        }
    }

    private var columnHeadings: some View {
        HStack(spacing: 10) {
            Text("Word").frame(width: 150, alignment: .leading)
            Text("Says it as").frame(width: 130, alignment: .leading)
            Text("Say it as instead").frame(maxWidth: .infinity, alignment: .leading)
            Text("Where").frame(width: 130, alignment: .leading)
            Spacer().frame(width: 58)
        }
        .font(.caption).foregroundStyle(Monokai.comment)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Monokai.panel)
    }

    /// Words in the script that have no entry yet. A shortcut, not a
    /// recommendation — the app has no way of knowing which of these espeak
    /// gets wrong, and says so rather than pretending to.
    @ViewBuilder private var suggestions: some View {
        let words = studio.candidateWords
        if !words.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("From your script")
                    .font(.caption).foregroundStyle(Monokai.comment)
                FlowRow(words) { word in
                    Button {
                        studio.addEntry(for: word)
                    } label: {
                        Text(word).font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Monokai.inset, in: Capsule())
                    }
                    .contentShape(Capsule())
                    .buttonStyle(.plain)
                    .foregroundStyle(Monokai.fg)
                }
                Text("Longer and less common words, which is where espeak is likeliest to guess. Hear one before you change it.")
                    .font(.caption2).foregroundStyle(Monokai.comment)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TextField("Add a word", text: $adding)
                .textFieldStyle(.roundedBorder).frame(width: 200)
                .onSubmit { commit() }
            Button("Add") { commit() }
                .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
            Text("\(studio.dictionary.global.count) everywhere · \(studio.dictionary.project.count) this script")
                .font(.caption).foregroundStyle(Monokai.comment)
        }
        .padding(14)
    }

    private func commit() {
        let w = adding.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        studio.addEntry(for: w)
        adding = ""
    }
}

private struct EntryRow: View {
    @EnvironmentObject var studio: Studio
    @Binding var entry: PronunciationEntry

    private var problem: PronunciationProblem {
        PronunciationDictionary.problem(with: entry.ipa, vocabulary: studio.vocabulary)
    }
    private var shadowed: Bool { studio.dictionary.isShadowed(entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(entry.word)
                    .foregroundStyle(entry.enabled && !shadowed ? Monokai.fg : Monokai.comment)
                    .strikethrough(shadowed)
                    .frame(width: 150, alignment: .leading)

                Text(studio.defaultPhonemes(for: entry.word))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Monokai.comment)
                    .frame(width: 130, alignment: .leading)
                    .help("What espeak says for this word on its own.")

                TextField("IPA", text: $entry.ipa)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity)

                Picker("", selection: $entry.scope) {
                    ForEach(PronunciationEntry.Scope.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 130)

                Toggle("", isOn: $entry.enabled).labelsHidden()
                    .help("Off keeps the entry without applying it.")
                Button {
                    studio.removeEntry(entry.id)
                } label: { Image(systemName: "trash") }
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .foregroundStyle(Monokai.comment)
            }
            status
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    @ViewBuilder private var status: some View {
        let p = problem
        if p.isBlocking && !entry.ipa.isEmpty {
            Label(p.message, systemImage: "exclamationmark.octagon.fill")
                .font(.caption).foregroundStyle(Monokai.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if p.hasWarning {
            Label(p.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(Monokai.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if shadowed {
            Text("A “this script” entry for the same word is in force, so this one is doing nothing.")
                .font(.caption).foregroundStyle(Monokai.comment)
        } else if !entry.ipa.isEmpty, entry.enabled {
            // Whether it lands is a fact about the script, not about the entry,
            // and it is the failure this feature exists to prevent.
            let n = studio.sentencesAffected(by: entry)
            let total = studio.script.sentences.filter {
                $0.text.lowercased().contains(entry.key)
            }.count
            if total == 0 {
                Text("Not in this script. It will apply when the word appears.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            } else if n == total {
                Label("Applies in \(n) of \(total) sentence\(total == 1 ? "" : "s").",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Monokai.green)
            } else {
                Label("Applies in \(n) of \(total) — espeak said something different in the rest, usually because the stress moved.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Monokai.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A wrapping row of chips. SwiftUI has no flow layout before macOS 15 that is
/// worth the ceremony, and this is nine lines.
private struct FlowRow<Item: Hashable, Content: View>: View {
    var items: [Item]
    @ViewBuilder var content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items; self.content = content
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ForEach(items, id: \.self, content: content) }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(stride(from: 0, to: items.count, by: 6)), id: \.self) { start in
                    HStack(spacing: 6) {
                        ForEach(items[start ..< min(start + 6, items.count)], id: \.self, content: content)
                    }
                }
            }
        }
    }
}
