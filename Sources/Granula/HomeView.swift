import AppKit
import GranulaCore
import SwiftUI

/// «Главная»: the current recording, upcoming calendar meetings, past meetings by day.
struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // Re-drawn every 30 s: «идёт», today/tomorrow and «Сегодня» follow the clock.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            SnapshotFriendlyScroll {
                VStack(alignment: .leading, spacing: 0) {
                    if let record = model.record(id: model.recordingID) {
                        RecordingCard(record: record).padding(.bottom, 24)
                    }
                    UpcomingSection(now: context.date)
                    FeedSection().padding(.top, 24)
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 12)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background)
    }
}

/// A ScrollView, except under `--e2e-snapshot`: AppKit's cacheDisplay draws SwiftUI
/// scroll views blank, so the test lays the content out without one — pinned to the
/// top and clipped below, so a long feed does not push the top out of the picture.
struct SnapshotFriendlyScroll<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        if model.e2e.snapshotFolder != nil {
            Color.clear
                .overlay(alignment: .top) {
                    VStack(spacing: 0) { content() }.fixedSize(horizontal: false, vertical: true)
                }
                .clipped()
        } else {
            ScrollView { content() }
        }
    }
}

struct RecordingCard: View {
    @EnvironmentObject var model: AppModel
    let record: MeetingRecord

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 9, height: 9)
            Text("Идёт запись: \(record.meeting.title) · \(Transcript.clock(model.snapshot?.elapsed ?? 0))")
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Открыть") { model.selection = record.id }
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .card()
    }
}

// MARK: - Upcoming

struct UpcomingSection: View {
    @EnvironmentObject var model: AppModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Предстоящие").font(Theme.serif(28))
            if model.calendarAccess == .granted {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        if index > 0 { DashedLine() }
                        DayRow(day: day.date, events: day.events, now: now)
                    }
                }
                .card()
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "calendar").foregroundStyle(Theme.tileIcon)
                    Text("Здесь появятся ближайшие встречи из Календаря Mac.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Подключить календарь") { Task { await model.connectCalendar() } }
                        .buttonStyle(PillButtonStyle())
                }
                .padding(16)
                .card()
            }
        }
    }

    /// Today (including a meeting already under way) and the next four days.
    private var days: [(date: Date, events: [CalendarMeeting])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let sorted = model.upcoming.sorted { $0.start < $1.start }
        return (0..<CalendarWatcher.days).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            // A meeting under way since yesterday still shows under today.
            return (day, sorted.filter { (offset == 0 || $0.start >= day) && $0.start < next })
        }
    }
}

struct DayRow: View {
    let day: Date
    let events: [CalendarMeeting]
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLanguage.format(day, template: "d")).font(Theme.serif(30))
                HStack(spacing: 5) {
                    Text(AppLanguage.format(day, template: "LLL") + " · " + AppLanguage.format(day, template: "EEE"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if Calendar.current.isDate(day, inSameDayAs: now) {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    }
                }
            }
            .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                if events.isEmpty {
                    HStack(spacing: 10) {
                        AccentBar(color: Theme.line)
                        Text("Встреч нет").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 34)
                } else {
                    ForEach(events) { UpcomingEventRow(meeting: $0, now: now) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

struct UpcomingEventRow: View {
    @EnvironmentObject var model: AppModel
    let meeting: CalendarMeeting
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            AccentBar(color: Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Записать") { Task { await model.startRecording(event: meeting) } }
                .buttonStyle(PillButtonStyle())
                .disabled(model.isRecording)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var subtitle: String {
        let range = meeting.start.formatted(date: .omitted, time: .shortened) + " – "
            + meeting.end.formatted(date: .omitted, time: .shortened)
        return meeting.start <= now ? String(localized: "\(range) · идёт") : range
    }
}

// MARK: - Past meetings

struct FeedSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.meetings.isEmpty {
            FirstMeetingInvite()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups, id: \.day) { group in
                    Text(Self.dayTitle(group.day))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .padding(.top, 14)
                        .padding(.bottom, 2)
                    ForEach(group.items) { FeedRow(record: $0) }
                }
            }
        }
    }

    private var groups: [(day: Date, items: [MeetingRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.meetings) { calendar.startOfDay(for: $0.meeting.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day]!.sorted { $0.meeting.startedAt > $1.meeting.startedAt })
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Сегодня") }
        if calendar.isDateInYesterday(day) { return String(localized: "Вчера") }
        let thisYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return AppLanguage.format(day, template: thisYear ? "EEEdMMM" : "yMMMd")
    }
}

struct FeedRow: View {
    @EnvironmentObject var model: AppModel
    let record: MeetingRecord
    @State private var hovering = false

    private var isRecording: Bool { record.id == model.recordingID }

    var body: some View {
        Button { model.selection = record.id } label: {
            HStack(spacing: 12) {
                StatusTile(status: record.meeting.status, isRecording: isRecording)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.meeting.title).lineLimit(1)
                    if let people {
                        Text(people).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(trailing).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.tile.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Up to three attendees, then «ещё N».
    private var people: String? {
        guard let all = record.meeting.attendees?.map(CalendarRules.readableName), !all.isEmpty else { return nil }
        let shown = all.prefix(3).joined(separator: ", ")
        return all.count > 3 ? String(localized: "\(shown) и ещё \(all.count - 3)") : shown
    }

    private var trailing: String {
        let time = record.meeting.startedAt.formatted(date: .omitted, time: .shortened)
        if isRecording { return String(localized: "\(time) · идёт запись") }
        let minutes = max(1, Int((record.meeting.duration / 60).rounded()))
        return String(localized: "\(time) · \(minutes) мин")
    }
}

struct StatusTile: View {
    let status: Meeting.Status
    let isRecording: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.tile)
            if isRecording {
                Circle().fill(.red).frame(width: 10, height: 10)
            } else {
                switch status {
                case .recording, .processing: ProgressView().controlSize(.small)
                case .done: Image(systemName: "doc.text").foregroundStyle(Theme.tileIcon)
                case .summaryFailed, .noModel, .failed:
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.tileIcon)
                }
            }
        }
        .font(.system(size: 15))
        .frame(width: 34, height: 34)
    }
}

struct FirstMeetingInvite: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Запишите первую встречу").font(Theme.serif(22))
            Text("Нажмите «Новая встреча» или ⌥⌘R. Во время звонка в Zoom, Telegram или браузере Granula сама предложит записать.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Button("Новая встреча") { Task { await model.startRecording() } }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

// MARK: - Pieces

struct AccentBar: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
    }
}

struct DashedLine: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: geo.size.width, y: 0))
            }
            .stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(height: 1)
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .medium : .regular))
            .padding(.horizontal, prominent ? 16 : 11)
            .padding(.vertical, prominent ? 7 : 4)
            .foregroundStyle(prominent ? Color.white : Theme.tileIcon)
            .background(Capsule().fill(prominent ? Theme.accent : Theme.card))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.line))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

extension View {
    /// White rounded card with a thin warm border.
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }
}
