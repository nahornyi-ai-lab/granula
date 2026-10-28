import AppKit
import EventKit
import Foundation

/// Reads upcoming events from macOS Calendar (iCloud, Google, Exchange — every
/// account added to the Mac). Read-only: Granula never writes to the calendar.
@MainActor
public final class CalendarWatcher {
    public enum Access: Equatable, Sendable { case notAsked, granted, denied }

    /// Days read and shown on «Главная»: today and the next four.
    public static let days = 5

    /// Meetings from now to the end of the fifth day, by start time.
    public private(set) var meetings: [CalendarMeeting] = []
    public var onChange: (() -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var logged: Set<String> = []

    public init() {}

    public static var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// Shows the macOS «Календари» prompt (first time only) and starts reading.
    @discardableResult
    public func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            Log.event("calendar.access", "granted=\(granted)")
            if granted { start() }
            return granted
        } catch {
            Log.error("calendar.unavailable", error)
            return false
        }
    }

    /// Re-reads on calendar changes, on wake and every 60 s.
    public func start() {
        guard Self.access == .granted else {
            Log.event("calendar.unavailable", "access=\(Self.access)")
            return
        }
        guard timer == nil else { refresh(); return }
        // Which calendars the Mac gives Granula: a missing account explains a missing meeting.
        let names = store.calendars(for: .event).map { "\($0.title) (\($0.source.title))" }.sorted()
        Log.event("calendar.calendars", "count=\(names.count) \(names.joined(separator: "; "))")
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    public func refresh() {
        guard Self.access == .granted else { return }
        let now = Date()
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: Self.days, to: calendar.startOfDay(for: now)) else { return }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        var fresh: [CalendarMeeting] = []
        for event in store.events(matching: predicate) {
            let m = Self.meeting(from: event)
            guard m.end > now else { continue }
            if CalendarRules.isMeeting(m) { fresh.append(m); continue }
            // Why a timed event is not a meeting — the first thing to look at when one is missing.
            if !m.isAllDay, !logged.contains("skip|" + m.reminderKey) {
                logged.insert("skip|" + m.reminderKey)
                let me = (event.attendees ?? []).contains(where: \.isCurrentUser)
                let organizer = event.organizer.map { $0.isCurrentUser ? "me" : "other" } ?? "none"
                Log.event("calendar.skipped", "title=\(m.title) attendees=\(event.attendees?.count ?? 0) me=\(me) organizer=\(organizer) declined=\(m.declinedByMe) link=\(CalendarRules.hasCallLink(m))")
            }
        }
        fresh.sort { $0.start < $1.start }
        for m in fresh where !logged.contains(m.reminderKey) {
            logged.insert(m.reminderKey)
            Log.event("calendar.upcoming", "title=\(m.title) start=\(ISO8601DateFormatter().string(from: m.start))")
        }
        if fresh != meetings {
            meetings = fresh
            onChange?()
        }
    }

    static func meeting(from event: EKEvent) -> CalendarMeeting {
        let attendees = event.attendees ?? []
        var others = attendees.filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
        // Invited by someone else (a recruiter's booking, a Meet link Google keeps out of
        // the notes): the organizer is a participant even when not on the guest list.
        if let organizer = event.organizer, !organizer.isCurrentUser,
           attendees.contains(where: \.isCurrentUser), !others.contains(where: { $0.url == organizer.url }) {
            others.insert(organizer, at: 0)
        }
        let declined = attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
        return CalendarMeeting(
            eventID: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString,
            title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Встреча") : event.title,
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            declinedByMe: declined,
            attendees: others.map(displayName),
            url: event.url?.absoluteString,
            location: event.location,
            notes: event.notes)
    }

    /// A name without the e-mail: the participant's name, else the part before «@».
    static func displayName(_ participant: EKParticipant) -> String {
        if let name = participant.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.contains("@") {
            return name
        }
        let address = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        return address.split(separator: "@").first.map { CalendarRules.readableName(String($0)) }
            ?? String(localized: "участник")
    }
}
