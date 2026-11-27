import Foundation

/// The owner's choices for live hints, kept in UserDefaults. The API key is not here:
/// it lives in a key file of its own (`KeyFile`, `HintSettings.keyName`).
public struct HintSettings: Equatable, Sendable {
    /// The hints column of the Live window, and the requests behind it.
    public var enabled: Bool
    /// The decision model that judges each turn of the other side (an OpenRouter model ID).
    public var judgeModel: String
    /// The model that writes the hint (an OpenRouter model ID).
    public var answerModel: String
    /// Free text about the owner: name, work, facts people ask about.
    public var aboutMe: String

    public static let defaultJudgeModel = "baseten/bison-1"
    public static let haiku = "anthropic/claude-haiku-5.5"
    public static let sonnet = "anthropic/claude-sonnet-5.5"
    /// The key file of the OpenRouter API key.
    public static let keyName = "openrouter-api-key"

    static let enabledKey = "hintsEnabled"
    static let judgeKey = "hintsJudgeModel"
    static let answerKey = "hintsModel"
    static let aboutMeKey = "hintsAboutMe"

    public init(enabled: Bool = true, judgeModel: String = HintSettings.defaultJudgeModel,
                answerModel: String = HintSettings.haiku, aboutMe: String = "") {
        self.enabled = enabled
        self.judgeModel = judgeModel
        self.answerModel = answerModel
        self.aboutMe = aboutMe
    }

    /// The model IDs as they are sent: trimmed, the default when the field is empty.
    public var judge: String { Self.clean(judgeModel) ?? Self.defaultJudgeModel }
    public var answer: String { Self.clean(answerModel) ?? Self.haiku }

    private static func clean(_ id: String?) -> String? {
        let id = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }

    public static func load(from defaults: UserDefaults = .standard) -> HintSettings {
        HintSettings(
            enabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
            judgeModel: clean(defaults.string(forKey: judgeKey)) ?? defaultJudgeModel,
            answerModel: clean(defaults.string(forKey: answerKey)) ?? haiku,
            aboutMe: defaults.string(forKey: aboutMeKey) ?? "")
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(judgeModel, forKey: Self.judgeKey)
        defaults.set(answerModel, forKey: Self.answerKey)
        defaults.set(aboutMe, forKey: Self.aboutMeKey)
    }
}
