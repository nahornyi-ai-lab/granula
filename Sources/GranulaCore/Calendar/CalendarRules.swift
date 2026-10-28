import Foundation

/// One calendar event as Granula sees it — copied out of EventKit so the
/// rules below can run on plain values.
public struct CalendarMeeting: Equatable, Sendable, Identifiable {
    public var eventID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The owner declined the invitation.
    public var declinedByMe: Bool
    /// Names of the other attendees (no e-mail addresses).
    public var attendees: [String]
    /// URL, location and notes — where call links live.
    public var url: String?
    public var location: String?
    public var notes: String?

    public init(eventID: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
                declinedByMe: Bool = false, attendees: [String] = [], url: String? = nil,
                location: String? = nil, notes: String? = nil) {
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.declinedByMe = declinedByMe
        self.attendees = attendees
        self.url = url
        self.location = location
        self.notes = notes
    }

    /// One reminder per event and start time: a moved event is reminded again.
    public var reminderKey: String { "\(eventID)|\(Int(start.timeIntervalSince1970))" }
    public var id: String { reminderKey }
}

public enum CalendarRules {
    static let maxDuration: TimeInterval = 4 * 3600
    /// Remind this long before the start.
    public static let reminderLead: TimeInterval = 60
    /// Not reminded once the start is this far behind (the Mac was asleep).
    public static let reminderLate: TimeInterval = 5 * 60
    /// An unanswered reminder disappears this long after the start.
    public static let reminderHideAfter: TimeInterval = 10 * 60

    static let callHosts = ["zoom.us/", "meet.google.com/", "teams.microsoft.com/", "telemost.yandex"]

    /// Whether an event is a meeting worth recording (spec «Какие события считаются встречами»).
    public static func isMeeting(_ event: CalendarMeeting) -> Bool {
        if event.isAllDay || event.declinedByMe { return false }
        if event.end.timeIntervalSince(event.start) > maxDuration { return false }
        return !event.attendees.isEmpty || hasCallLink(event)
    }

    /// Zoom, Meet, Teams, Telemost, or a t.me link with «call» in it — in URL, location or notes.
    public static func hasCallLink(_ event: CalendarMeeting) -> Bool {
        let text = [event.url, event.location, event.notes].compactMap { $0 }.joined(separator: " ").lowercased()
        if callHosts.contains(where: text.contains) { return true }
        return text.split(whereSeparator: \.isWhitespace).contains { $0.contains("t.me/") && $0.contains("call") }
    }

    /// «olena.kovalenko» → «Olena Kovalenko»: a readable name from an e-mail login.
    /// A name that already has a space or a capital letter stays as it is.
    public static func readableName(_ raw: String) -> String {
        guard !raw.contains(" "), raw == raw.lowercased() else { return raw }
        let parts = raw.split { "._-".contains($0) }
        guard !parts.isEmpty else { return raw }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// A recording started this long before a meeting still belongs to it.
    public static let linkEarly: TimeInterval = 5 * 60

    /// The meeting going on now (or starting within 5 minutes) — a recording started
    /// from the call prompt, the hot key or «Новая встреча» takes its title and attendees.
    /// Several at once → the one whose start is nearest to now.
    public static func current(in events: [CalendarMeeting], now: Date) -> CalendarMeeting? {
        events
            .filter { isMeeting($0) && $0.start.timeIntervalSince(now) <= linkEarly && $0.end > now }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    /// The meeting to remind about now, if any: starts within a minute (or started
    /// less than 5 minutes ago), not yet reminded, and nothing is being recorded.
    public static func dueReminder(in events: [CalendarMeeting], now: Date,
                                   reminded: Set<String>, isRecording: Bool) -> CalendarMeeting? {
        guard !isRecording else { return nil }
        return events
            .filter { isMeeting($0) && !reminded.contains($0.reminderKey) }
            .filter {
                let lead = $0.start.timeIntervalSince(now)
                return lead <= reminderLead && lead >= -reminderLate
            }
            .min { $0.start < $1.start }
    }
}
