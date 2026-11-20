import GranulaCore
import SwiftUI

/// Own notes, autosaved half a second after typing stops.
struct NotesEditor: View {
    @EnvironmentObject var model: AppModel
    let record: MeetingRecord
    @State private var text = ""
    /// What notes.md holds as far as this editor knows: loading it never schedules a save.
    @State private var savedText = ""
    @State private var loaded = false
    @State private var pendingSave: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            if text.isEmpty {
                Text("Take notes during the meeting — they go into the summary")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 27)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            let disk = model.store.read(MeetingFile.notes, of: record) ?? ""
            savedText = disk
            text = disk
            loaded = true
        }
        .onChange(of: text) { _, new in
            guard loaded else { return }
            // The last text always wins: an edit undone within half a second cancels its save.
            pendingSave?.cancel()
            pendingSave = nil
            guard new != savedText else { return }
            let id = record.id
            let work = DispatchWorkItem {
                savedText = new
                pendingSave = nil
                model.saveNotes(new, for: id)
            }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        .onDisappear { flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flush() }
    }

    /// Saves typing that the 0.5 s autosave has not written yet.
    private func flush() {
        if let pendingSave {
            pendingSave.cancel()
            self.pendingSave = nil
            savedText = text
            model.saveNotes(text, for: record.id)
        }
    }
}

struct SummaryTab: View {
    @EnvironmentObject var model: AppModel
    let record: MeetingRecord
    @State private var template = "auto"

    var body: some View {
        let summary = model.store.read(MeetingFile.summary, of: record) ?? ""
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Picker("Template", selection: $template) {
                    ForEach(model.templates) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 260)
                Button("Regenerate") { model.regenerate(record, template: template) }
                    .disabled(busy)
                Spacer()
                CopyButton(title: "Copy summary") { model.copySummary(record) }
                    .disabled(summary.isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            SnapshotFriendlyScroll {
                if !summary.isEmpty {
                    MarkdownView(text: summary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                        .frame(maxWidth: 760, alignment: .leading)
                } else {
                    (busy ? Text("The summary will appear after the transcript.") : Text("No summary yet."))
                        .foregroundStyle(.secondary)
                        .padding(28)
                }
            }
        }
        .onAppear {
            model.reloadTemplates()
            template = record.meeting.template
        }
    }

    private var busy: Bool { record.meeting.status == .processing || record.meeting.status == .recording }
}

struct TranscriptTab: View {
    @EnvironmentObject var model: AppModel
    let record: MeetingRecord
    @AppStorage("transcriptView") private var view = TranscriptView.both

    enum TranscriptView: String, CaseIterable, Identifiable {
        case original, translation, both
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .original: return "Original"
            case .translation: return "Translation"
            case .both: return "Both"
            }
        }
    }

    var body: some View {
        let _ = model.transcriptRevision
        if let transcript = Transcript.load(from: record.url(MeetingFile.transcriptJSON)) {
            if transcript.segments.isEmpty {
                Text("No speech found in the recording.").foregroundStyle(.secondary).padding(28)
            } else {
                let translation = TranscriptTranslation.load(from: record.url(MeetingFile.translationJSON))
                    .flatMap { $0.lines.count == transcript.segments.count ? $0 : nil }
                VStack(alignment: .leading, spacing: 0) {
                    toolbar(translation: translation)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                    SnapshotFriendlyScroll {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(transcript.segments.enumerated()), id: \.offset) { i, segment in
                                TranscriptLine(segment: segment,
                                               translation: translation.flatMap { view == .original ? nil : $0.lines[i] },
                                               translationOnly: view == .translation)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                        .frame(maxWidth: 820, alignment: .leading)
                    }
                }
            }
        } else if let lines = LiveLog.load(from: record.url(MeetingFile.live))?.filter({ !$0.echo }), !lines.isEmpty {
            // Until the transcript of the full recording is ready: what was heard live.
            VStack(alignment: .leading, spacing: 0) {
                Label("Live transcript. The full transcript replaces it when processing ends.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                SnapshotFriendlyScroll {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(lines) { line in
                            LiveLineView(speaker: line.speaker, start: line.start, text: line.text,
                                         translation: line.translation, translating: false, partial: false)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 820, alignment: .leading)
                }
            }
        } else {
            Text("The transcript will appear when the recording ends.").foregroundStyle(.secondary).padding(28)
        }
    }

    private func toolbar(translation: TranscriptTranslation?) -> some View {
        HStack(spacing: 10) {
            if let translation {
                Picker("", selection: $view) {
                    ForEach(TranscriptView.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                Text(verbatim: TranslationLanguages.name(translation.target))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.translatingTranscripts.contains(record.id) {
                ProgressView().controlSize(.small)
                Text("Translating…").font(.callout).foregroundStyle(.secondary)
            } else if TranslationLanguages.isAvailable {
                Menu {
                    ForEach(TranslationLanguages.targets, id: \.self) { code in
                        Button(TranslationLanguages.name(code)) { model.translateTranscript(record, to: code) }
                    }
                } label: {
                    Label(translation == nil ? "Translate" : "Translate again", systemImage: "translate")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(busy)
            }
            Spacer()
            if translation != nil {
                CopyButton(title: "Copy translation") { model.copyTranslation(record) }
            }
            CopyButton(title: "Copy transcript") { model.copyTranscript(record) }
        }
    }

    private var busy: Bool { record.meeting.status == .processing || record.meeting.status == .recording }
}

/// Copies to the clipboard and shows "Copied" for a moment, so the click is visibly done.
struct CopyButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}

struct TranscriptLine: View {
    let segment: Segment
    /// The line in the translation language; nil when there is none or none was needed.
    var translation: String? = nil
    var translationOnly = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Transcript.clock(segment.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.speaker.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(segment.speaker == .me ? Theme.accent : Color.purple)
                if let translation {
                    if !translationOnly {
                        Text(segment.text).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Text(translation).font(.system(size: 14))
                } else {
                    Text(segment.text).font(.system(size: 14))
                }
            }
        }
    }
}

extension Speaker {
    /// On screen the labels follow the interface language; files keep "Me" / "Them".
    var label: LocalizedStringKey {
        switch self {
        case .me: return "Me"
        case .them: return "Them"
        }
    }
}

/// Minimal Markdown: headings, bullet and numbered lists, inline emphasis.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                render(line)
            }
        }
    }

    private var lines: [String] { text.components(separatedBy: "\n") }

    @ViewBuilder
    private func render(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Spacer().frame(height: 4)
        } else if line.hasPrefix("### ") {
            inline(String(line.dropFirst(4))).font(.headline).padding(.top, 4)
        } else if line.hasPrefix("## ") {
            inline(String(line.dropFirst(3))).font(.title3.weight(.semibold)).padding(.top, 10)
        } else if line.hasPrefix("# ") {
            inline(String(line.dropFirst(2))).font(.title2.weight(.semibold)).padding(.top, 10)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            let indent = raw.prefix { $0 == " " }.count
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(String(line.dropFirst(2)))
            }
            .padding(.leading, CGFloat(indent) * 6)
        } else {
            inline(line)
        }
    }

    private func inline(_ s: String) -> Text {
        let attributed = (try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(attributed).font(.system(size: 14.5))
    }
}
