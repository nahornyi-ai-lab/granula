import GranulaCore
import SwiftUI
import Translation

/// "Translation…": the languages to translate from and into, the languages spoken in
/// meetings, and the on-device language packs, downloaded through macOS's own prompt.
struct TranslationSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Translation").font(.title2.weight(.semibold))
            if #available(macOS 26.0, *) {
                TranslationSettingsForm()
            } else {
                Text("Translation needs macOS 26 or later. The live transcript works without it.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

@available(macOS 26.0, *)
private struct TranslationSettingsForm: View {
    @EnvironmentObject var model: AppModel
    /// Status of each pair "source>target" for the chosen target.
    @State private var statuses: [String: LanguageAvailability.Status] = [:]
    /// Languages macOS can translate, to hide the meeting languages it cannot.
    @State private var supported: [Locale.Language] = []
    @State private var download: TranslationSession.Configuration?
    @State private var downloading: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Translate into", selection: $model.liveSettings.target) {
                    Text("Don't translate").tag(String?.none)
                    Divider()
                    ForEach(TranslationLanguages.targets, id: \.self) { code in
                        Text(verbatim: TranslationLanguages.name(code)).tag(String?.some(code))
                    }
                }
                Picker("From", selection: $model.liveSettings.source) {
                    Text("Auto").tag(String?.none)
                    Divider()
                    ForEach(sourceChoices, id: \.self) { code in
                        Text(verbatim: TranslationLanguages.name(code)).tag(String?.some(code))
                    }
                }
                .disabled(model.liveSettings.target == nil)
            }
            .frame(maxWidth: 320)

            VStack(alignment: .leading, spacing: 6) {
                Text("Languages spoken in meetings").font(.headline)
                Text("With From on Auto, each line is translated from the language it is in; Granula picks it among these.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(spokenChoices, id: \.self) { code in
                        Toggle(TranslationLanguages.name(code), isOn: spokenBinding(code))
                    }
                }
            }

            if !packPairs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Language packs").font(.headline)
                    Text("Translation runs on this Mac. Each language is downloaded once.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(packPairs, id: \.self) { pair in
                        packRow(source: pair.source, target: pair.target)
                    }
                }
            }
        }
        .task(id: packPairs) { await refresh() }
        .task { supported = await LanguageAvailability().supportedLanguages }
        .translationTask(download) { session in
            do {
                try await session.prepareTranslation()
                Log.event("translation.downloaded", "pair=\(downloading ?? "")")
            } catch {
                Log.error("translation.download_failed pair=\(downloading ?? "")", error)
            }
            // Refresh first: clearing the configuration cancels this action, and a cancelled
            // refresh keeps its statuses to itself.
            await refresh()
            downloading = nil
            download = nil
        }
    }

    private func packRow(source: String, target: String) -> some View {
        let key = "\(source)>\(target)"
        return HStack(spacing: 10) {
            Text(verbatim: "\(TranslationLanguages.name(source)) → \(TranslationLanguages.name(target))")
                .frame(width: 260, alignment: .leading)
            switch statuses[key] {
            case .installed?:
                Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .supported?:
                if downloading == key {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Download") {
                        downloading = key
                        download = TranslationSession.Configuration(
                            source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
                    }
                    .disabled(downloading != nil)
                }
            case .unsupported?:
                Text("Not available").foregroundStyle(.secondary)
            default:
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Meeting languages offered: what the speech model knows and macOS can translate.
    private var spokenChoices: [String] {
        guard !supported.isEmpty else { return TranslationLanguages.spoken.filter(model.liveSettings.languages.contains) }
        return TranslationLanguages.spoken.filter { code in
            model.liveSettings.languages.contains(code)
                || supported.contains { $0.languageCode?.identifier == code }
        }
    }

    private func spokenBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { model.liveSettings.languages.contains(code) },
            set: { on in
                var languages = model.liveSettings.languages.filter { $0 != code }
                if on { languages.append(code) }
                // At least one language: with none, a line's language could not be told.
                guard !languages.isEmpty else { return }
                model.liveSettings.languages = TranslationLanguages.spoken.filter(languages.contains)
            })
    }

    /// From: what the speech model hears, but not the target (From equal to To translates nothing).
    private var sourceChoices: [String] {
        TranslationLanguages.spoken.filter { code in
            !(model.liveSettings.target.map { TranslationLanguages.same(code, $0) } ?? false)
        }
    }

    private struct Pair: Hashable {
        let source: String
        let target: String
    }

    /// The live translation's pairs (From → To, or each meeting language → To on Auto), and the
    /// ones a transcript's translation is missing.
    private var packPairs: [Pair] {
        var pairs: [Pair] = []
        func add(_ sources: [String], _ target: String) {
            for source in sources where !TranslationLanguages.same(source, target) {
                let pair = Pair(source: source, target: target)
                if !pairs.contains(pair) { pairs.append(pair) }
            }
        }
        if let target = model.liveSettings.target {
            add(model.liveSettings.detectionLanguages, target)
        }
        if let target = model.translationSettingsTarget {
            add(model.translationSettingsSources, target)
        }
        return pairs
    }

    private func refresh() async {
        let availability = LanguageAvailability()
        var found: [String: LanguageAvailability.Status] = [:]
        for pair in packPairs {
            found["\(pair.source)>\(pair.target)"] = await availability.status(
                from: Locale.Language(identifier: pair.source), to: Locale.Language(identifier: pair.target))
        }
        // Replaced by a newer refresh (the pairs changed): its statuses win.
        guard !Task.isCancelled else { return }
        statuses = found
    }
}
