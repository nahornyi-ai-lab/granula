import XCTest
@testable import GranulaCore

/// Critical positive scenario: without these rules no reminder ever appears.
final class CalendarRulesTests: XCTestCase {
    func testRemindsAboutMeetingsAndSkipsPersonalEvents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: String, in seconds: TimeInterval, attendees: [String] = [], location: String? = nil,
                   allDay: Bool = false, declined: Bool = false) -> CalendarMeeting {
            CalendarMeeting(eventID: id, title: id, start: now + seconds, end: now + seconds + 1800,
                            isAllDay: allDay, declinedByMe: declined, attendees: attendees, location: location)
        }
        let withPeople = event("Call with Ivan", in: 50, attendees: ["Ivan Petrov"])
        let zoomOnly = event("Demo", in: 55, location: "https://us02web.zoom.us/j/123456")
        let personal = event("Lunch", in: 40)
        let allDay = event("Vacation", in: 30, attendees: ["Anna"], allDay: true)
        let declined = event("Standup", in: 20, attendees: ["Anna"], declined: true)
        let events = [withPeople, zoomOnly, personal, allDay, declined]

        // The nearest real meeting comes first; personal, all-day and declined never do.
        let first = CalendarRules.dueReminder(in: events, now: now, reminded: [], isRecording: false)
        XCTAssertEqual(first?.title, "Call with Ivan")
        XCTAssertEqual(first?.attendees, ["Ivan Petrov"])

        // Once reminded, the Zoom-only meeting is next.
        let second = CalendarRules.dueReminder(in: events, now: now, reminded: [withPeople.reminderKey], isRecording: false)
        XCTAssertEqual(second?.title, "Demo")

        // After both, nothing else is a meeting.
        XCTAssertNil(CalendarRules.dueReminder(in: events, now: now,
                                               reminded: [withPeople.reminderKey, zoomOnly.reminderKey], isRecording: false))
        XCTAssertFalse([personal, allDay, declined].contains(where: CalendarRules.isMeeting))
    }

    /// Critical positive scenario: a recording started from the call prompt during a
    /// calendar meeting gets that meeting's attendees — otherwise they never reach the summary.
    func testRecordingDuringMeetingTakesItsAttendees() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sync = CalendarMeeting(eventID: "sync", title: "Weekly product sync",
                                   start: now - 13 * 60, end: now + 17 * 60,
                                   attendees: ["Olena Kovalenko", "taras.bondar", "Iryna Melnyk"])
        let later = CalendarMeeting(eventID: "later", title: "Intro", start: now + 3600, end: now + 5400,
                                    attendees: ["Dmytro"])
        let linked = CalendarRules.current(in: [later, sync], now: now)
        XCTAssertEqual(linked?.title, "Weekly product sync")
        XCTAssertEqual(linked?.attendees.count, 3)
    }
}
