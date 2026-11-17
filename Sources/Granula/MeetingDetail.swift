import GranulaCore
import SwiftUI

struct MeetingDetail: View {
    @EnvironmentObject var model: AppModel
    let record: MeetingRecord
    @State private var tab: Tab = .notes
    @State private var title = ""

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case summary = "Summary"
        case transcript = "Transcript"
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .notes: return "Notes"
            case .summary: return "Summary"
            case .transcript: return "Transcript"
            }
        }
    }

    private var isRecording: Bool { record.id == model.recordingID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.leading, 28)
                .padding(.trailing, 220)  // room for the "New meeting" pill
                .padding(.top, 20)
                .padding(.bottom, 12)
            if isRecording, let snapshot = model.snapshot {
                RecordingPanel(snapshot: snapshot)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            } else {
                StatusBanner(record: record)
                    .padding(.horizontal, 28)
            }
            if !isRecording {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
            Divider()
            Group {
                switch isRecording ? .notes : tab {
                case .notes: NotesEditor(record: record)
                case .summary: SummaryTab(record: record)
                case .transcript: TranscriptTab(record: record)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.background)
        .onAppear {
            title = record.meeting.title
            if record.meeting.status == .done { tab = .summary }
        }
        .onChange(of: record.meeting.status) { _, status in
            if status == .done && tab == .notes { tab = .summary }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.openFolder(record) } label: { Label("Open folder", systemImage: "folder") }
                    .help("Open the meeting folder")
                Button { model.copySummary(record) } label: { Label("Copy summary", systemImage: "doc.on.doc") }
                    .help("Copy summary")
                    .disabled(record.meeting.status != .done)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.serif(28))
                .onSubmit { model.rename(record, to: title) }
                .onChange(of: record.meeting.title) { _, new in title = new }
                .onDisappear { model.rename(record, to: title) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.rename(record, to: title)
                }
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            // Who was invited, from the calendar event the recording is linked to.
            if let people = record.meeting.attendees, !people.isEmpty {
                Label(people.map(CalendarRules.readableName).joined(separator: ", "), systemImage: "person.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var subtitle: String {
        var parts = [AppLanguage.format(record.meeting.startedAt, template: "yMMMMdjmm")]
        let minutes = max(1, Int((record.meeting.duration / 60).rounded()))
        if !isRecording { parts.append(String(localized: "\(minutes) min")) }
        if record.meeting.interrupted { parts.append(String(localized: "recording interrupted")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Recording

struct RecordingPanel: View {
    @EnvironmentObject var model: AppModel
    let snapshot: Recorder.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(Transcript.clock(snapshot.elapsed))
                        .font(.system(.title3, design: .monospaced).weight(.medium))
                }
                VStack(alignment: .leading, spacing: 5) {
                    LevelMeter(label: "Me", level: snapshot.micLevel, state: snapshot.micState)
                    LevelMeter(label: "Them", level: snapshot.systemLevel, state: snapshot.systemState)
                }
                Spacer()
                Button(role: .destructive) {
                    model.stopRecording(reason: "user")
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
            ForEach(snapshot.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.06)))
    }
}

struct LevelMeter: View {
    let label: LocalizedStringKey
    let level: Float
    let state: Recorder.TrackState

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color).frame(width: geo.size.width * fraction)
                }
            }
            .frame(width: 160, height: 6)
        }
    }

    private var fraction: CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }

    private var color: Color {
        if case .failed = state { return .orange }
        return .green
    }
}

// MARK: - Status

struct StatusBanner: View {
    @EnvironmentObject var model: AppModel
    let record: MeetingRecord

    var body: some View {
        switch record.meeting.status {
        case .processing, .recording:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(stageText).foregroundStyle(.secondary)
                if record.meeting.stage == .summarizing {
                    Button("Cancel") { model.cancelSummary() }.controlSize(.small)
                }
            }
            .padding(.bottom, 4)
        case .summaryFailed, .noModel, .failed:
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(record.meeting.error ?? String(localized: "Error")).font(.callout).lineLimit(3)
                Spacer()
                Button("Retry") { model.retry(record) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            .padding(.bottom, 4)
        case .done:
            EmptyView()
        }
    }

    private var stageText: String {
        switch record.meeting.stage {
        case .transcribing: return String(localized: "Transcribing…")
        case .compressing: return String(localized: "Compressing audio…")
        case .summarizing: return String(localized: "Writing the summary…")
        case nil: return String(localized: "Waiting to be processed…")
        }
    }
}
