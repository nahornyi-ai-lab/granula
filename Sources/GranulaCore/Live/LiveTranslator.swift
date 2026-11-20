import FluidAudio
import Foundation
import NaturalLanguage
import Translation

/// Speech recognition the live transcript needs; `Transcriber` in the app, a fake in tests.
public protocol SpeechRecognizing: Sendable {
    /// Loads the model; false when it is not on this Mac.
    func load() async throws -> Bool
    /// Words of 16 kHz mono samples, times from the first sample.
    func words(in samples: [Float]) async throws -> [WordTiming]
}

public enum LineTranslation: Equatable, Sendable {
    case translated(String)
    /// The text is already in the target language.
    case sameLanguage
    /// The language pack from this source language is not downloaded.
    case missingLanguage(String)
    case unsupported
    case failed
}

/// Translation of single lines; Apple's on-device translation in the app, a fake in tests.
public protocol LineTranslating: Sendable {
    func translate(_ text: String, from source: String, to target: String) async -> LineTranslation
    /// The source languages whose pack into `target` still has to be downloaded.
    func missingLanguages(_ sources: [String], to target: String) async -> [String]
}

/// The languages Granula offers, as language codes ("en", "zh-Hans").
public enum TranslationLanguages {
    /// What the speech model (Parakeet v3) recognizes: the choice of meeting languages.
    public static let spoken = [
        "en", "ru", "uk", "es", "de", "fr", "it", "pt", "pl", "nl", "cs", "sk", "sv", "da", "fi",
        "el", "hu", "ro", "bg", "hr", "sl", "lt", "lv", "et",
    ]
    /// What translation may go into.
    public static let targets = [
        "en", "ru", "uk", "es", "de", "fr", "it", "pt", "pl", "nl", "tr", "ar", "hi", "id", "th", "vi",
        "zh-Hans", "zh-Hant", "ja", "ko",
    ]

    /// The language's own name ("Русский", "English").
    public static func name(_ code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// "pt-BR" and "pt" are one language here; "zh-Hans" and "zh-Hant" are not.
    public static func same(_ a: String, _ b: String) -> Bool {
        let la = Locale.Language(identifier: a), lb = Locale.Language(identifier: b)
        guard la.languageCode == lb.languageCode else { return false }
        return la.script == nil || lb.script == nil || la.script == lb.script
    }

    /// Meeting languages for a first launch: the Mac's preferred languages the model knows, and English.
    public static var defaultSpoken: [String] {
        var result: [String] = []
        for identifier in Locale.preferredLanguages {
            guard let code = Locale.Language(identifier: identifier).languageCode?.identifier,
                  spoken.contains(code), !result.contains(code) else { continue }
            result.append(code)
        }
        if !result.contains("en") { result.append("en") }
        return result
    }

    /// Live translation runs on Apple's on-device models, from macOS 26.
    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// Which meeting language a line is in. Short lines say little, so the speaker's
/// previous language wins unless the text clearly says otherwise.
public enum LanguageDetector {
    public static func detect(_ text: String, among languages: [String], previous: String?) -> String? {
        let candidates = languages.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard text.contains(where: \.isLetter) else { return previous }
        if candidates.count == 1 { return candidates[0] }
        let recognizer = NLLanguageRecognizer()
        if !candidates.isEmpty {
            recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
        }
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: max(3, candidates.count))
        guard let top = hypotheses.max(by: { $0.value < $1.value }) else { return previous }
        if let previous, candidates.isEmpty || candidates.contains(previous) {
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            // "так", "ok": too short to tell; the speaker's language, if it is written that way.
            if words < 3 && cyrillic(text) == cyrillicLanguages.contains(previous) { return previous }
            let previousScore = hypotheses[NLLanguage(rawValue: previous)] ?? 0
            if top.value < 0.6 && previousScore >= 0.2 { return previous }
        }
        return top.key.rawValue
    }

    static let cyrillicLanguages: Set<String> = ["ru", "uk", "bg", "sr", "mk", "be"]

    static func cyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}

/// Apple's on-device translation (the Translation framework). It only uses
/// language packs already downloaded; downloading needs the window's
/// `translationTask` (Translation settings).
@available(macOS 26.0, *)
public actor AppleTranslator: LineTranslating {
    private let quality: TranslationQuality
    private var sessions: [String: TranslationSession] = [:]
    /// Pairs known to be installed; a missing pair is asked again after `recheck`.
    private var installed: Set<String> = []
    private var checked: [String: (status: LanguageAvailability.Status, at: Date)] = [:]
    /// Pairs whose session kept failing with the preferred strategy: they use the default one.
    private var plainOnly: Set<String> = []
    /// Failures in a row with the preferred strategy, per pair.
    private var strategyFailures: [String: Int] = [:]
    private static let maxStrategyFailures = 3
    private static let recheck: TimeInterval = 10

    public init(quality: TranslationQuality) {
        self.quality = quality
    }

    public func translate(_ text: String, from source: String, to target: String) async -> LineTranslation {
        if TranslationLanguages.same(source, target) { return .sameLanguage }
        let key = "\(source)>\(target)"
        switch await status(source, target) {
        case .installed: break
        case .supported: return .missingLanguage(source)
        default: return .unsupported
        }
        let session = sessions[key] ?? makeSession(source, target, preferred: !plainOnly.contains(key))
        sessions[key] = session
        do {
            let response = try await session.translate(text)
            strategyFailures[key] = nil
            return .translated(response.targetText)
        } catch {
            Log.error("translation.failed pair=\(key)", error)
            // The text itself (digits only, say): the session is fine.
            if TranslationError.nothingToTranslate ~= error || TranslationError.unableToIdentifyLanguage ~= error {
                return .failed
            }
            // A broken session is rebuilt on the next line; the pack is checked again.
            sessions[key] = nil
            installed.remove(key)
            checked[key] = nil
            if TranslationError.notInstalled ~= error { return .missingLanguage(source) }
            guard !plainOnly.contains(key) else { return .failed }
            // The preferred strategy (high fidelity, low latency) may be what fails on this Mac:
            // after a few failures in a row the pair keeps to the default one.
            let failures = (strategyFailures[key] ?? 0) + 1
            strategyFailures[key] = failures
            if failures >= Self.maxStrategyFailures { plainOnly.insert(key) }
            // This line once more with the default strategy, in a session that is not kept.
            let plain = makeSession(source, target, preferred: false)
            defer { plain.cancel() }
            guard let response = try? await plain.translate(text) else { return .failed }
            return .translated(response.targetText)
        }
    }

    public func missingLanguages(_ sources: [String], to target: String) async -> [String] {
        var missing: [String] = []
        for source in sources where !TranslationLanguages.same(source, target) {
            if await status(source, target) == .supported { missing.append(source) }
        }
        return missing
    }

    private func status(_ source: String, _ target: String) async -> LanguageAvailability.Status {
        let key = "\(source)>\(target)"
        if installed.contains(key) { return .installed }
        if let cached = checked[key], Date().timeIntervalSince(cached.at) < Self.recheck { return cached.status }
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        if status == .installed { installed.insert(key) }
        checked[key] = (status, Date())
        return status
    }

    private func makeSession(_ source: String, _ target: String, preferred: Bool) -> TranslationSession {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        if preferred, #available(macOS 26.4, *) {
            return TranslationSession(installedSource: from, target: to,
                                      preferredStrategy: quality == .live ? .lowLatency : .highFidelity)
        }
        return TranslationSession(installedSource: from, target: to)
    }
}

public enum TranslationQuality: Sendable {
    /// Fast: for the live transcript.
    case live
    /// Best: for the transcript after the meeting.
    case best
}

public enum Translators {
    /// Apple's translation where the OS has it; nil before macOS 26.
    public static func make(_ quality: TranslationQuality) -> LineTranslating? {
        if #available(macOS 26.0, *) { return AppleTranslator(quality: quality) }
        return nil
    }
}
