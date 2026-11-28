import GranulaCore
import SwiftUI

/// "Hints…": the OpenRouter key (kept in Granula's key file only), the model that judges whether
/// a reply is expected, the model that writes it, and "About me".
struct HintsSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var keyFailed = false
    /// "Other…" is chosen: kept apart from the ID, so typing a variant of a preset
    /// ("…-5.5:nitro") does not switch the picker to that preset halfway.
    @State private var customAnswer = false

    private static let other = "other"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hints").font(.title2.weight(.semibold))
            Text("During a call, when the other side expects your reply, a suggested answer appears in the Live window. After every turn of the other side, the conversation and \"About me\" are sent to OpenRouter; for a hint, also the meeting title, attendee names, your notes and the meeting context.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Turn on hints for new meetings", isOn: $model.hintSettings.enabled)
                Text("Each meeting can differ: Prepare in Coming up, or the lightbulb in the Live window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("OpenRouter API key").font(.headline)
                HStack {
                    SecureField(model.hasHintKey ? String(localized: "Key saved") : "sk-or-…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.hasHintKey {
                        Button("Remove") { model.removeHintKey() }
                    }
                }
                if keyFailed {
                    Label("Couldn't save the key.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.hasHintKey {
                    Label("Key saved", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Judge model") {
                    TextField("Judge model", text: $model.hintSettings.judgeModel,
                              prompt: Text(verbatim: HintSettings.defaultJudgeModel))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                Picker("Answer model", selection: answerChoice) {
                    Text(verbatim: "Claude Haiku 5.5").tag(HintSettings.haiku)
                    Text(verbatim: "Claude Sonnet 5.5").tag(HintSettings.sonnet)
                    Text("Other…").tag(Self.other)
                }
                if customAnswer {
                    LabeledContent("Model ID") {
                        TextField("Model ID", text: $model.hintSettings.answerModel,
                                  prompt: Text(verbatim: "provider/model"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Text("OpenRouter model IDs. The judge is a decision model: it answers yes or no in a fraction of a second.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 6) {
                Text("About me").font(.headline)
                TextEditor(text: $model.hintSettings.aboutMe)
                    .font(.body)
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Text("Your name, your work, facts people ask you about. Hints take facts only from here, the meeting context, your notes and the call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 12) {
                Button("Check") { model.checkHints() }
                    .disabled(!model.hasHintKey || model.hintCheck == .checking)
                checkResult
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { customAnswer = !Self.isPreset(model.hintSettings.answerModel) }
    }

    @ViewBuilder
    private var checkResult: some View {
        switch model.hintCheck {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .done(let judge, let answer):
            VStack(alignment: .leading, spacing: 2) {
                checkLine(String(localized: "Judge model"), judge)
                checkLine(String(localized: "Answer model"), answer)
            }
            .font(.caption)
        case nil:
            EmptyView()
        }
    }

    private func checkLine(_ title: String, _ error: HintError?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: error == nil ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(error == nil ? Color.green : Color.orange)
            Text(verbatim: title + ":")
            Text(error?.message ?? String(localized: "Works"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func isPreset(_ id: String) -> Bool {
        id == HintSettings.haiku || id == HintSettings.sonnet
    }

    /// Haiku, Sonnet, or any other ID typed in.
    private var answerChoice: Binding<String> {
        Binding {
            let id = model.hintSettings.answerModel
            return customAnswer || !Self.isPreset(id) ? Self.other : id
        } set: { choice in
            customAnswer = choice == Self.other
            // "Other…" keeps the current ID in the field, to edit rather than retype.
            if choice != Self.other { model.hintSettings.answerModel = choice }
        }
    }

    private func save() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        keyFailed = !model.saveHintKey(key)
        if !keyFailed { key = "" }
    }
}
