// Test helper for scripts/e2e/calendar.sh. Built into a tiny app bundle and
// launched through `open`, so the calendar permission belongs to this helper,
// not to the terminal. It only ever touches the calendar named "Granula E2E".
//
//   GranulaE2ECalendar create <title> <seconds-from-now>
//   GranulaE2ECalendar delete
import EventKit
import Foundation

let calendarName = "Granula E2E"
let store = EKEventStore()
let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") }

func fail(_ text: String) -> Never {
    print("FAIL \(text)")
    exit(1)
}

func ownCalendars() -> [EKCalendar] {
    store.calendars(for: .event).filter { $0.title == calendarName }
}

func create(title: String, seconds: TimeInterval) throws {
    // "On My Mac" if present, else iCloud (Google accounts cannot add calendars), else the default.
    guard let source = store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" })
            ?? store.defaultCalendarForNewEvents?.source else { fail("no calendar source") }
    let calendar = EKCalendar(for: .event, eventStore: store)
    calendar.title = calendarName
    calendar.source = source
    try store.saveCalendar(calendar, commit: true)

    let event = EKEvent(eventStore: store)
    event.calendar = calendar
    event.title = title
    event.startDate = Date().addingTimeInterval(seconds)
    event.endDate = event.startDate.addingTimeInterval(30 * 60)
    event.url = URL(string: "https://zoom.us/j/1234567890")
    event.location = "https://zoom.us/j/1234567890"
    try store.save(event, span: .thisEvent, commit: true)
    print("created source=\(source.title) start=\(ISO8601DateFormatter().string(from: event.startDate))")
}

func deleteAll() throws {
    let calendars = ownCalendars()
    for calendar in calendars { try store.removeCalendar(calendar, commit: true) }
    print("deleted calendars=\(calendars.count)")
}

Task {
    do {
        guard try await store.requestFullAccessToEvents() else { fail("calendar access denied") }
        switch args.first {
        case "create":
            guard args.count == 3, let seconds = TimeInterval(args[args.startIndex + 2]) else { fail("usage: create <title> <seconds>") }
            try deleteAll()
            try create(title: args[args.startIndex + 1], seconds: seconds)
        case "delete":
            try deleteAll()
        default:
            fail("usage: create <title> <seconds> | delete")
        }
        exit(0)
    } catch {
        fail("\(error)")
    }
}
RunLoop.main.run()
