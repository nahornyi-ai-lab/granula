import GranulaCore
import SwiftUI

/// The Live window's content: From → To, what the transcript is waiting for, then
/// the lines, each with its translation under it, and the phrase being spoken in grey.
/// With hints on, the hints column on the right.
struct LiveTranscriptView: View {
    @EnvironmentObject var model: AppModel
    @State private var follow = true
    @State private var atBottom = true

    var body: some View {
        let live = model.live ?? LiveSnapshot()
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    LanguagePairPicker()
                    HintsToggle()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
                LiveStatusLine(live: live)
                    .padding(.horizontal, 14)
                Divider().padding(.top, 6)
                lines(live)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.hintSettings.enabled {
                Divider()
                HintsColumn()
                    .frame(width: LiveWindow.hintsWidth)
            }
        }
        .background(Theme.background)
    }

    private func lines(_ live: LiveSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    let lines = live.visibleLines
                    let partials = live.visiblePartials
                    if lines.isEmpty && partials.isEmpty {
                        Text("Lines appear here as people speak.")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                    }
                    ForEach(lines) { line in
                        LiveLineView(speaker: line.speaker, start: line.start, text: line.text,
                                     translation: line.translation, translating: live.pending.contains(line.id),
                                     partial: false)
                    }
                    ForEach(partials, id: \.speaker) { partial in
                        LiveLineView(speaker: partial.speaker, start: partial.start, text: partial.text,
                                     translation: partial.translation, translating: false, partial: true)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(FollowsBottom(follow: $follow, atBottom: $atBottom))
            // Any change can make the last rows taller: new lines, the phrase in progress,
            // a translation arriving. The session publishes only real changes.
            .onChange(of: live) { _, _ in scroll(proxy) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .overlay(alignment: .bottomTrailing) {
                if !follow {
                    Button {
                        follow = true
                        proxy.scrollTo("end", anchor: .bottom)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                    }
                    .controlSize(.small)
                    .padding(10)
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard follow else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) }
    }
}

/// From ▾ → To ▾: the language people speak (Auto: told among the meeting languages)
/// and the one to translate into. Lines already in the target are left as they are.
struct LanguagePairPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if TranslationLanguages.isAvailable {
                Picker("From", selection: $model.liveSettings.source) {
                    Text("Auto").tag(String?.none)
                    Divider()
                    ForEach(sources, id: \.self) { code in
                        Text(verbatim: TranslationLanguages.name(code)).tag(String?.some(code))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.liveSettings.target == nil)
                .help("The language to translate from. Auto: each line's own language, among the meeting languages")
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("To", selection: $model.liveSettings.target) {
                    Text("Don't translate").tag(String?.none)
                    Divider()
                    ForEach(TranslationLanguages.targets, id: \.self) { code in
                        Text(verbatim: TranslationLanguages.name(code)).tag(String?.some(code))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("The language to translate into")
                Spacer(minLength: 0)
                Button {
                    model.presentTranslationSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Translation settings…")
            } else {
                Label("Translation needs macOS 26 or later.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    /// What the speech model hears, but not the target: From equal to To would translate nothing.
    private var sources: [String] {
        TranslationLanguages.spoken.filter { code in
            !(model.liveSettings.target.map { TranslationLanguages.same(code, $0) } ?? false)
        }
    }
}

/// Stops following new lines while the owner has scrolled up to read; follows
/// again once they scroll back to the end. Before macOS 15 it always follows.
private struct FollowsBottom: ViewModifier {
    @Binding var follow: Bool
    @Binding var atBottom: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 30
                } action: { _, bottom in
                    atBottom = bottom
                }
                .onScrollPhaseChange { old, new in
                    // Only the owner's own scrolling changes it, not lines arriving
                    // nor the app's own animated scroll to them.
                    if new == .idle, old != .idle, old != .animating { follow = atBottom }
                }
        } else {
            content
        }
    }
}

/// One line: who and when, then the text. With a translation, the original small
/// and grey and the translation large under it; a line in the target language, once.
struct LiveLineView: View {
    let speaker: Speaker
    let start: TimeInterval
    let text: String
    let translation: String?
    let translating: Bool
    let partial: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(speaker.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(speaker == .me ? Theme.accent : Color.purple)
                Text(Transcript.clock(start))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if translation != nil || translating {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                // While it is being translated, a placeholder where the translation will be.
                Text(translation ?? "…")
                    .font(.system(size: 16))
                    .foregroundStyle(translation == nil || partial ? .secondary : .primary)
            } else {
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(partial ? .secondary : .primary)
            }
        }
        .opacity(partial ? 0.75 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the live transcript is waiting for, when it is not simply running.
struct LiveStatusLine: View {
    @EnvironmentObject var model: AppModel
    let live: LiveSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch live.status {
            case .loadingModel:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading the speech model…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .noModel:
                note(String(localized: "The speech model isn't downloaded — the transcript appears after the meeting."))
            case .failed(let why):
                note(String(localized: "Live transcript is off: \(why)"))
            case .running:
                EmptyView()
            }
            switch live.translation {
            case .missingLanguages(let sources):
                HStack(spacing: 8) {
                    note(String(localized: "Download to translate: \(sources.map(TranslationLanguages.name).joined(separator: ", "))"))
                    Button("Download…") { model.presentTranslationSettings() }
                        .controlSize(.small)
                }
            case .off, .on, .unavailableOS:
                // macOS < 26 is said by the From → To header instead.
                EmptyView()
            }
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The lightbulb in the header: the hints column on or off.
struct HintsToggle: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let on = model.hintSettings.enabled
        Button {
            model.hintSettings.enabled.toggle()
        } label: {
            Image(systemName: on ? "lightbulb.fill" : "lightbulb")
                .foregroundStyle(on ? Theme.accent : .secondary)
        }
        .buttonStyle(.borderless)
        .help("Hints")
        .accessibilityLabel(Text("Hints"))
    }
}

/// Suggested replies, newest on top: what the other side said, then what the owner can say,
/// and its translation when the turn was in another language.
struct HintsColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let snapshot = model.hints ?? HintsSnapshot()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hints").font(.headline)
                Spacer(minLength: 0)
                Button {
                    model.presentHintsSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Hints…")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            if let error = snapshot.judgeError {
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !model.hasHintKey {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Add your OpenRouter API key to get hints")
                                .foregroundStyle(.secondary)
                            Button("Hints…") { model.presentHintsSettings() }
                                .controlSize(.small)
                        }
                        .padding(.top, 8)
                    } else if snapshot.hints.isEmpty {
                        Text("Hints appear here when the other side expects your reply.")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                    }
                    ForEach(snapshot.hints.reversed()) { hint in
                        HintCard(hint: hint)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// One hint: when and what they said (small, grey, the end of a long turn), then the reply.
struct HintCard: View {
    let hint: LiveHint
    /// About three lines of caption text in the column.
    private static let saidLimit = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Transcript.clock(hint.start))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                // The end of a long turn, where the question usually is.
                Text(hint.said.count > Self.saidLimit ? "…" + hint.said.suffix(Self.saidLimit) : hint.said)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !hint.text.isEmpty {
                Text(hint.text)
                    .font(.system(size: 16))
                    .foregroundStyle(hint.state == .writing ? .secondary : .primary)
            }
            if let translation = hint.translation {
                Text(translation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            switch hint.state {
            case .writing where hint.text.isEmpty:
                Text("Writing…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            case .failed(let error):
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension HintError {
    /// What the hints column and Hints… say about it.
    var message: String {
        switch self {
        case .keyRejected: return String(localized: "The OpenRouter key was rejected — check it in Hints…")
        case .noCredits: return String(localized: "OpenRouter is out of credits")
        case .unknownModel(let id): return String(localized: "Unknown model: \(id)")
        case .busy: return String(localized: "The model is busy — no hint this time")
        case .offline: return String(localized: "No connection — no hint this time")
        case .keyUnavailable: return String(localized: "Couldn't read the saved key — save it again in Hints…")
        }
    }
}
