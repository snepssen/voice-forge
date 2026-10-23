import CGtk
import Foundation
import VoiceForgeCore
import VoiceForgeTTS

// Voice Forge's workbench as a GTK4 + libadwaita window: the script on the
// left, the synthesiser's dials on the right, Render / Play / Stop / Export in
// the header. The engine is the Mac app's, unchanged; this file is only the
// window.
//
//   voice-forge-gtk                       the window
//   voice-forge-gtk --measure-startup     print ms to the first frame, then quit
//   voice-forge-gtk --measure-render TEXT render TEXT without a window, print the timing

// MARK: - State

final class Workbench {
    var window: Widget!
    var text: UnsafeMutablePointer<GtkTextBuffer>!
    var dials: [(Widget, WritableKeyPath<SynthesisSettings, Double>)] = []
    var voiceRow: Widget!
    var statusRow: Widget!
    var render: Widget!, play: Widget!, stop: Widget!, export: Widget!

    var engine: VoiceEngine?
    var settings = SynthesisSettings()
    var audio: [Float] = []
    var busy = false
    var media: UnsafeMutablePointer<GtkMediaStream>?

    var script: Script {
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(text, &start, &end)
        guard let raw = gtk_text_buffer_get_text(text, &start, &end, 0) else { return Script.parse("") }
        defer { g_free(raw) }
        return Script.parse(String(cString: raw))
    }

    func status(_ line: String) {
        adw_action_row_set_subtitle(typed(statusRow), line)
    }

    func refresh() {
        gtk_widget_set_sensitive(render, busy || engine == nil ? 0 : 1)
        gtk_widget_set_sensitive(play, audio.isEmpty || busy ? 0 : 1)
        gtk_widget_set_sensitive(stop, media == nil ? 0 : 1)
        gtk_widget_set_sensitive(export, audio.isEmpty || busy ? 0 : 1)
    }
}

nonisolated(unsafe) let bench = Workbench()
let defaultText = """
    Build the pattern. Each control prints what it is actually worth on the voice you chose.

    A paragraph break is a longer silence than a sentence gap, and both are exact.
    """

// MARK: - Measuring

/// Seconds since this process started, from the kernel's own record where
/// there is one, so the loader's work counts too.
func secondsSinceProcessStart() -> Double? {
    guard let stat = try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8),
          let uptime = try? String(contentsOfFile: "/proc/uptime", encoding: .utf8),
          let close = stat.lastIndex(of: ")") else { return nil }
    // Fields after the command name; starttime is the 22nd field overall.
    let fields = stat[stat.index(after: close)...].split(separator: " ")
    guard fields.count > 19, let ticks = Double(fields[19]),
          let now = Double(uptime.split(separator: " ")[0]) else { return nil }
    return now - ticks / Double(sysconf(Int32(_SC_CLK_TCK)))
}

let launched = Date()
let measuringStartup = CommandLine.arguments.contains("--measure-startup")

if let at = CommandLine.arguments.firstIndex(of: "--measure-render") {
    let words = at + 1 < CommandLine.arguments.count ? CommandLine.arguments[at + 1] : defaultText
    do {
        let loadStart = Date()
        guard let profile = VoiceEngine.availableVoices().first else { fatalError("no voice") }
        let engine = try VoiceEngine(profile: profile)
        let loaded = Date().timeIntervalSince(loadStart)
        let renderStart = Date()
        let audio = engine.assemble(try engine.render(Script.parse(words), settings: SynthesisSettings()))
        let took = Date().timeIntervalSince(renderStart)
        let seconds = Double(audio.count) / engine.sampleRate
        print(String(format: "voice %@: loaded in %.2f s; %.2f s of speech in %.2f s (%.1fx real time)",
                     profile.name, loaded, seconds, took, seconds / took))
        exit(0)
    } catch {
        print("render failed: \(error.localizedDescription)")
        exit(1)
    }
}

// MARK: - Actions

func startRender() {
    guard let engine = bench.engine, !bench.busy else { return }
    let script = bench.script
    guard !script.sentences.isEmpty else { return }
    var settings = bench.settings
    for (row, key) in bench.dials { settings[keyPath: key] = adw_spin_row_get_value(op(row)) }
    bench.settings = settings
    bench.busy = true
    bench.refresh()
    bench.status("Rendering \(script.sentences.count) sentence\(script.sentences.count == 1 ? "" : "s")…")
    let start = Date()
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            let rendered = try engine.render(script, settings: settings)
            let audio = engine.assemble(rendered)
            let took = Date().timeIntervalSince(start)
            onMain {
                bench.audio = audio
                bench.busy = false
                let seconds = Double(audio.count) / engine.sampleRate
                bench.status(String(format: "%.1f s of speech, rendered in %.1f s", seconds, took))
                bench.refresh()
            }
        } catch {
            onMain {
                bench.busy = false
                bench.status("Render failed: \(error.localizedDescription)")
                bench.refresh()
            }
        }
    }
}

func stopPlaying() {
    guard let media = bench.media else { return }
    gtk_media_stream_pause(media)
    g_object_unref(UnsafeMutableRawPointer(media))
    bench.media = nil
    bench.refresh()
}

func startPlaying() {
    guard let engine = bench.engine, !bench.audio.isEmpty else { return }
    stopPlaying()
    let url = FileManager.default.temporaryDirectory.appending(path: "voice-forge-take.wav")
    do {
        try Export.writeWAV(bench.audio, rate: engine.sampleRate, depth: .pcm16, to: url)
    } catch {
        bench.status("Could not write the take: \(error.localizedDescription)")
        return
    }
    bench.media = gtk_media_file_new_for_filename(url.path)
    gtk_media_stream_play(bench.media)
    bench.refresh()
}

func exportTake() {
    let dialog = gtk_file_dialog_new()
    gtk_file_dialog_set_initial_name(dialog, "voiceover.wav")
    gtk_file_dialog_save(dialog, typed(bench.window), nil, { source, result, _ in
        var error: UnsafeMutablePointer<GError>?
        guard let file = gtk_file_dialog_save_finish(OpaquePointer(source), result, &error),
              let path = g_file_get_path(file) else {
            if let error { g_error_free(error) }  // dismissed
            return
        }
        defer { g_free(path); g_object_unref(UnsafeMutableRawPointer(file)) }
        guard let engine = bench.engine else { return }
        let url = URL(fileURLWithPath: String(cString: path))
        do {
            let receipt = try Export.write(bench.audio, at: engine.sampleRate, to: url, settings: Export.Settings())
            bench.status(String(format: "Wrote %@: %.1f s at %.0f Hz", url.lastPathComponent,
                                receipt.seconds, receipt.sampleRate))
        } catch {
            bench.status("Export failed: \(error.localizedDescription)")
        }
    }, nil)
    g_object_unref(UnsafeMutableRawPointer(dialog))
}

// MARK: - The window

func button(_ label: String, _ handler: @escaping Handler) -> Widget {
    let b = gtk_button_new_with_label(label)!
    connect(b, "clicked", handler)
    return b
}

func dial(_ title: String, _ subtitle: String, _ key: WritableKeyPath<SynthesisSettings, Double>,
          range: ClosedRange<Double>, step: Double, digits: UInt32) -> Widget {
    let row = adw_spin_row_new_with_range(range.lowerBound, range.upperBound, step)!
    adw_preferences_row_set_title(typed(row), title)
    adw_action_row_set_subtitle(typed(row), subtitle)
    adw_spin_row_set_digits(op(row), digits)
    adw_spin_row_set_value(op(row), bench.settings[keyPath: key])
    bench.dials.append((row, key))
    return row
}

func build(_ app: UnsafeMutablePointer<AdwApplication>) {
    let window = adw_application_window_new(UnsafeMutablePointer<GtkApplication>(OpaquePointer(app)))!
    bench.window = window
    gtk_window_set_title(typed(window), "Voice Forge")
    gtk_window_set_default_size(typed(window), 1040, 680)

    let header = adw_header_bar_new()!
    bench.render = button("Render") { _, _ in startRender() }
    gtk_widget_add_css_class(bench.render, "suggested-action")
    bench.play = button("Play") { _, _ in startPlaying() }
    bench.stop = button("Stop") { _, _ in stopPlaying() }
    bench.export = button("Export…") { _, _ in exportTake() }
    adw_header_bar_pack_start(op(header), bench.render)
    adw_header_bar_pack_start(op(header), bench.play)
    adw_header_bar_pack_start(op(header), bench.stop)
    adw_header_bar_pack_end(op(header), bench.export)

    // The script.
    let view = gtk_text_view_new()!
    gtk_text_view_set_wrap_mode(typed(view), GTK_WRAP_WORD_CHAR)
    gtk_text_view_set_left_margin(typed(view), 18)
    gtk_text_view_set_right_margin(typed(view), 18)
    gtk_text_view_set_top_margin(typed(view), 18)
    gtk_text_view_set_bottom_margin(typed(view), 18)
    bench.text = gtk_text_view_get_buffer(typed(view))
    gtk_text_buffer_set_text(bench.text, defaultText, -1)
    let scroller = gtk_scrolled_window_new()!
    gtk_scrolled_window_set_child(op(scroller), view)

    // The dials, named as the Mac app names them.
    let page = adw_preferences_page_new()!
    let voice = adw_preferences_group_new()!
    adw_preferences_group_set_title(typed(voice), "Voice")
    bench.voiceRow = adw_action_row_new()!
    adw_preferences_row_set_title(typed(bench.voiceRow), "Loading…")
    bench.statusRow = adw_action_row_new()!
    adw_preferences_row_set_title(typed(bench.statusRow), "Take")
    adw_action_row_set_subtitle(typed(bench.statusRow), "Nothing rendered yet")
    adw_preferences_group_add(typed(voice), bench.voiceRow)
    adw_preferences_group_add(typed(voice), bench.statusRow)

    let synthesis = adw_preferences_group_new()!
    adw_preferences_group_set_title(typed(synthesis), "Synthesis")
    adw_preferences_group_add(typed(synthesis), dial("Pace", "Length scale: 1.10 is ten percent slower", \.lengthScale,
                                                    range: 0.5...2.0, step: 0.01, digits: 2))
    adw_preferences_group_add(typed(synthesis), dial("Variation", "How much the timbre varies between draws", \.noiseScale,
                                                    range: 0...1.5, step: 0.01, digits: 3))
    adw_preferences_group_add(typed(synthesis), dial("Cadence", "How much the durations vary between draws", \.noiseW,
                                                    range: 0...1.5, step: 0.01, digits: 2))
    let pauses = adw_preferences_group_new()!
    adw_preferences_group_set_title(typed(pauses), "Pauses")
    adw_preferences_group_add(typed(pauses), dial("Sentence gap", "Seconds of silence between sentences", \.sentenceGap,
                                                 range: 0...2, step: 0.01, digits: 2))
    adw_preferences_group_add(typed(pauses), dial("Paragraph gap", "Seconds at a paragraph break", \.paragraphGap,
                                                 range: 0...3, step: 0.05, digits: 2))
    for group in [voice, synthesis, pauses] { adw_preferences_page_add(typed(page), typed(group)) }

    let split = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
    gtk_paned_set_start_child(op(split), scroller)
    gtk_paned_set_end_child(op(split), page)
    gtk_paned_set_position(op(split), 620)

    let toolbar = adw_toolbar_view_new()!
    adw_toolbar_view_add_top_bar(op(toolbar), header)
    adw_toolbar_view_set_content(op(toolbar), split)
    adw_application_window_set_content(typed(window), toolbar)
    bench.refresh()

    if measuringStartup {
        connect(window, "map") { _, _ in
            onMain {
                let since = secondsSinceProcessStart() ?? Date().timeIntervalSince(launched)
                print(String(format: "first frame %.0f ms after the process started", since * 1000))
                g_application_quit(UnsafeMutablePointer<GApplication>(OpaquePointer(application)))
            }
        }
    }
    gtk_window_present(typed(window))

    // The model loads off the main loop; the window is usable meanwhile.
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            guard let profile = VoiceEngine.availableVoices().first else {
                onMain { adw_preferences_row_set_title(typed(bench.voiceRow), "No voice installed") }
                return
            }
            let engine = try VoiceEngine(profile: profile)
            onMain {
                bench.engine = engine
                adw_preferences_row_set_title(typed(bench.voiceRow), profile.name)
                adw_action_row_set_subtitle(typed(bench.voiceRow), String(format: "%.0f Hz", engine.sampleRate))
                bench.refresh()
            }
        } catch {
            onMain {
                adw_preferences_row_set_title(typed(bench.voiceRow), "The voice did not load")
                adw_action_row_set_subtitle(typed(bench.voiceRow), error.localizedDescription)
            }
        }
    }
}

// MARK: - Run

nonisolated(unsafe) var application: UnsafeMutablePointer<AdwApplication>!
application = adw_application_new("com.snepssen.voiceforge", G_APPLICATION_DEFAULT_FLAGS)
connect(UnsafeMutableRawPointer(application), "activate") { app, _ in
    build(app!.assumingMemoryBound(to: AdwApplication.self))
}
// Only the program's name: this app takes its own flags, and GApplication
// would refuse any it was not told about.
let status = g_application_run(UnsafeMutablePointer<GApplication>(OpaquePointer(application)),
                               1, CommandLine.unsafeArgv)
exit(status)
