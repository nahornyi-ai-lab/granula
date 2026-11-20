import Foundation

/// The owner's choices for the live transcript and translation, kept in UserDefaults.
public struct LiveSettings: Equatable, Sendable {
    /// Translate into this language; nil: no translation.
    public var target: String?
    /// Translate from this language ("From" in the live window); nil: Auto, the line's
    /// language is told among `languages`.
    public var source: String?
    /// Languages spoken in meetings: with From on Auto they decide which language a line is in.
    public var languages: [String]
    /// The live window (transcript and translation over other apps) during a recording.
    public var window: Bool

    static let targetKey = "translationTarget"
    static let sourceKey = "translationSource"
    static let languagesKey = "meetingLanguages"
    static let windowKey = "liveWindow"

    public init(target: String? = nil, source: String? = nil,
                languages: [String] = TranslationLanguages.defaultSpoken, window: Bool = true) {
        self.target = target
        self.source = source
        self.languages = languages
        self.window = window
    }

    /// The languages a line's language is told among.
    public var detectionLanguages: [String] {
        Self.detectionLanguages(source: source, target: target, languages: languages)
    }

    /// From → To: the line is in one of the two (the target only when the speech model hears it,
    /// Japanese say is a target nobody speaks). Auto, From equal to To, or no To (From is off
    /// without one): the meeting languages.
    public static func detectionLanguages(source: String?, target: String?, languages: [String]) -> [String] {
        guard let source, let target, !TranslationLanguages.same(source, target) else { return languages }
        var result = [source]
        if let spoken = TranslationLanguages.spoken.first(where: { TranslationLanguages.same($0, target) }) {
            result.append(spoken)
        }
        return result
    }

    /// After the meeting: the languages a line is told among when the transcript of a meeting
    /// recorded From → To (`meetingFrom`, `meetingTo`) is translated into `target`. The meeting's
    /// pair stays, and `target` joins it when it is a third language (a meeting in English and
    /// Russian translated into Ukrainian still has its Russian lines). Auto: the meeting languages.
    public static func transcriptLanguages(meetingFrom: String?, meetingTo: String?, target: String,
                                           languages: [String]) -> [String] {
        guard meetingFrom != nil else { return languages }
        var result = detectionLanguages(source: meetingFrom, target: meetingTo ?? target, languages: languages)
        if let spoken = TranslationLanguages.spoken.first(where: { TranslationLanguages.same($0, target) }),
           !result.contains(where: { TranslationLanguages.same($0, spoken) }) {
            result.append(spoken)
        }
        return result
    }

    public static func load(from defaults: UserDefaults = .standard) -> LiveSettings {
        let languages = (defaults.stringArray(forKey: languagesKey) ?? []).filter(TranslationLanguages.spoken.contains)
        return LiveSettings(
            target: defaults.string(forKey: targetKey).flatMap { $0.isEmpty ? nil : $0 },
            source: defaults.string(forKey: sourceKey).flatMap { TranslationLanguages.spoken.contains($0) ? $0 : nil },
            languages: languages.isEmpty ? TranslationLanguages.defaultSpoken : languages,
            window: defaults.object(forKey: windowKey) as? Bool ?? true)
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let target { defaults.set(target, forKey: Self.targetKey) } else { defaults.removeObject(forKey: Self.targetKey) }
        if let source { defaults.set(source, forKey: Self.sourceKey) } else { defaults.removeObject(forKey: Self.sourceKey) }
        defaults.set(languages, forKey: Self.languagesKey)
        defaults.set(window, forKey: Self.windowKey)
    }
}
