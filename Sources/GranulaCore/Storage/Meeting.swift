import Foundation

/// Contents of `meeting.json` — the single source of a meeting's state.
public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording
        case processing
        case summaryFailed = "summary_failed"
        case noModel = "no_model"
        case failed
        case done
    }

    public enum Stage: String, Codable, Sendable {
        case transcribing, compressing, summarizing
    }

    public var id: String            // folder name at creation, stable
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: Status
    public var stage: Stage?
    /// Set when the app died while recording; processed from what was written.
    public var interrupted: Bool
    public var template: String
    /// App that triggered the call prompt, when started from it.
    public var callApp: String?
    /// Calendar event the recording was started from, and its other attendees.
    public var calendarEventID: String?
    public var attendees: [String]?
    public var micPeak: Float
    public var systemPeak: Float
    public var error: String?

    public init(id: String, title: String, startedAt: Date, template: String = "auto",
                callApp: String? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = nil
        self.status = .recording
        self.stage = nil
        self.interrupted = false
        self.template = template
        self.callApp = callApp
        self.micPeak = 0
        self.systemPeak = 0
        self.error = nil
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}
