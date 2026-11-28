import GranulaCore
import SwiftUI

/// Prepare, for an upcoming calendar meeting: what it is about (text and files), and whether it
/// gets hints and translation. Saved as it is typed; the recording of that meeting takes it.
struct PrepareSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let meeting: CalendarMeeting
    @State private var context: String
    /// nil: the default when the recording starts.
    @State private var hints: Bool?
    @State private var translate: Bool?
    @State private var failed = false

    init(meeting: CalendarMeeting, saved: (context: String, hints: Bool?, translate: Bool?)) {
        self.meeting = meeting
        _context = State(initialValue: saved.context)
        _hints = State(initialValue: saved.hints)
        _translate = State(initialValue: saved.translate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.title2.weight(.semibold)).lineLimit(2)
                Text(when).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Context").font(.headline)
                ContextEditor(text: $context, save: { persist($0) }, height: 240)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("For this meeting").font(.headline)
                Toggle("Hints", isOn: Binding(get: { hints ?? model.hintSettings.enabled },
                                              set: { hints = $0; persist() }))
                if TranslationLanguages.isAvailable {
                    if let target = model.liveSettings.target {
                        Toggle("Translation into \(TranslationLanguages.name(target))",
                               isOn: Binding(get: { translate ?? true }, set: { translate = $0; persist() }))
                    } else {
                        Toggle("Translation", isOn: .constant(false)).disabled(true)
                        Text("Choose a language to translate into in Translation… first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                if failed {
                    Label("Couldn't save the preparation", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var when: String {
        AppLanguage.format(meeting.start, template: "MMMMdEEEE") + ", "
            + meeting.start.formatted(date: .omitted, time: .shortened) + " – "
            + meeting.end.formatted(date: .omitted, time: .shortened)
    }

    private func persist(_ text: String? = nil) {
        failed = !model.savePrep(for: meeting, context: text ?? context, hints: hints, translate: translate)
    }
}
