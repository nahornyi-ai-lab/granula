import GranulaCore
import SwiftUI

/// Own notes, autosaved half a second after typing stops.
struct NotesEditor: View {
    @EnvironmentObject var model: AppModel
    let record: MeetingRecord
    @State private var text = ""
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
                Text("Пишите заметки по ходу встречи — они попадут в итог")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 27)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            text = model.store.read(MeetingFile.notes, of: record) ?? ""
            loaded = true
        }
        .onChange(of: text) { _, new in
            guard loaded else { return }
            pendingSave?.cancel()
            let id = record.id
            let work = DispatchWorkItem { model.saveNotes(new, for: id) }
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
                Picker("Шаблон", selection: $template) {
                    ForEach(model.templates) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 260)
                Button("Пересоздать") { model.regenerate(record, template: template) }
                    .disabled(busy)
                Spacer()
                CopyButton(title: "Копировать итог") { model.copySummary(record) }
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
                    (busy ? Text("Итог появится после расшифровки.") : Text("Итога пока нет."))
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

    var body: some View {
        if let transcript = Transcript.load(from: record.url(MeetingFile.transcriptJSON)) {
            if transcript.segments.isEmpty {
                Text("Речи в записи не найдено.").foregroundStyle(.secondary).padding(28)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer()
                        CopyButton(title: "Копировать расшифровку") { model.copyTranscript(record) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    SnapshotFriendlyScroll {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                                TranscriptLine(segment: segment)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                        .frame(maxWidth: 820, alignment: .leading)
                    }
                }
            }
        } else {
            Text("Расшифровка появится после окончания записи.").foregroundStyle(.secondary).padding(28)
        }
    }
}

/// Copies to the clipboard and shows «Скопировано» for a moment, so the click is visibly done.
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
            Label(copied ? "Скопировано" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}

struct TranscriptLine: View {
    let segment: Segment

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
                Text(segment.text).font(.system(size: 14))
            }
        }
    }
}

extension Speaker {
    /// On screen the labels follow the interface language; files keep «Я» / «Собеседник».
    var label: LocalizedStringKey {
        switch self {
        case .me: return "Я"
        case .them: return "Собеседник"
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
