import Foundation

/// After-meeting pipeline, one meeting at a time:
/// transcribe both tracks → lines → drop echoes → merge → compress audio → AI summary.
/// Every step is resumable: on relaunch a meeting continues from what is on disk.
@MainActor
public final class MeetingProcessor {
    public var onUpdate: ((MeetingRecord) -> Void)?

    private let store: MeetingStore
    private var queue: [URL] = []
    private var isRunning = false
    private let summarizer = SummaryGenerator()
    /// Meetings whose summary is rebuilt; the old summary.md stays until the new one is ready.
    private var regenerate: Set<String> = []
    public private(set) var currentFolder: URL?

    public init(store: MeetingStore) {
        self.store = store
    }

    /// On launch: finish what was being processed; recover what was being recorded.
    public func recover() {
        for record in store.loadAll() {
            switch record.meeting.status {
            case .processing:
                enqueue(record)
            case .recording:
                Log.event("meeting.interrupted", "folder=\(record.folder.lastPathComponent)")
                let updated = update(record) {
                    $0.interrupted = true
                    $0.status = .processing
                    $0.endedAt = $0.endedAt ?? Self.lastWrite(in: record)
                }
                enqueue(updated)
            default:
                break
            }
        }
    }

    public func enqueue(_ record: MeetingRecord) {
        guard !queue.contains(record.folder), currentFolder != record.folder else { return }
        queue.append(record.folder)
        Log.event("processing.queued", "folder=\(record.folder.lastPathComponent)")
        runIfIdle()
    }

    /// "Повторить" after a failure, or "Пересоздать" for a finished meeting.
    public func retry(_ record: MeetingRecord, template: String? = nil, regenerateSummary: Bool = false) {
        let updated = update(record) {
            $0.status = .processing
            $0.error = nil
            if let template { $0.template = template }
        }
        if regenerateSummary { regenerate.insert(updated.id) }
        enqueue(updated)
    }

    public func cancelSummary() { summarizer.cancel() }

    // MARK: -

    private func runIfIdle() {
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            while !queue.isEmpty {
                let folder = queue.removeFirst()
                currentFolder = folder
                if let record = store.load(folder: folder) { await process(record) }
                currentFolder = nil
            }
            isRunning = false
        }
    }

    private func process(_ initial: MeetingRecord) async {
        var record = initial
        Log.event("processing.started", "folder=\(record.folder.lastPathComponent)")

        // 1. Transcript.
        var transcript = Transcript.load(from: record.url(MeetingFile.transcriptJSON))
        if transcript == nil {
            record = update(record) { $0.stage = .transcribing }
            do {
                try await Transcriber.shared.prepare()
            } catch {
                Log.error("asr.model_failed", error)
                record = update(record) { $0.status = .noModel; $0.stage = nil; $0.error = String(localized: "Модель распознавания не загрузилась: \(error.localizedDescription)") }
                return
            }
            do {
                transcript = try await transcribe(record)
                let built = transcript!
                try built.jsonData().write(to: record.url(MeetingFile.transcriptJSON), options: .atomic)
                try store.write(built.markdown, MeetingFile.transcriptMarkdown, of: record)
                Log.event("transcript.done", "segments=\(built.segments.count) echoes_dropped=\(built.droppedEchoes)")
            } catch {
                Log.error("transcript.failed", error)
                record = update(record) { $0.status = .failed; $0.stage = nil; $0.error = String(localized: "Расшифровка не удалась: \(error.localizedDescription)") }
                return
            }
        }

        // 2. Audio: CAF → m4a, off the main thread. The CAF stays if compression fails.
        record = update(record) { $0.stage = .compressing }
        var compressError: String?
        for (raw, compressed) in [(MeetingFile.micRaw, MeetingFile.micAudio), (MeetingFile.systemRaw, MeetingFile.systemAudio)] {
            let caf = record.url(raw)
            let m4a = record.url(compressed)
            guard FileManager.default.fileExists(atPath: caf.path) else { continue }
            do {
                try await Task.detached { try Compressor.compress(caf, to: m4a) }.value
            } catch {
                Log.error("compress.failed \(raw)", error)
                compressError = String(localized: "Звук не сжат, исходная запись сохранена: \(error.localizedDescription)")
            }
        }
        // A finished meeting with unsquashed audio shows the error and «Повторить».
        func finish(_ change: (inout Meeting) -> Void) -> MeetingRecord {
            update(record) {
                change(&$0)
                $0.stage = nil
                if $0.status == .done, let compressError { $0.status = .failed; $0.error = compressError }
            }
        }

        // 3. Summary.
        let rebuild = regenerate.remove(record.id) != nil
        if !rebuild, FileManager.default.fileExists(atPath: record.url(MeetingFile.summary).path) {
            record = finish { $0.status = .done }
            return
        }
        let notes = store.read(MeetingFile.notes, of: record) ?? ""
        guard let transcript, !(transcript.segments.isEmpty && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            try? store.write(String(localized: "Речи в записи не найдено.") + "\n", MeetingFile.summary, of: record)
            record = finish { $0.status = .done }
            Log.event("processing.done", "folder=\(record.folder.lastPathComponent) empty=1")
            return
        }
        record = update(record) { $0.stage = .summarizing }
        let templates = Templates.all(in: store.templatesFolder)
        // A failed rebuild stays a rebuild: «Повторить» must not settle for the old summary.
        func failed(_ text: String) {
            if rebuild { regenerate.insert(record.id) }
            record = update(record) { $0.status = .summaryFailed; $0.stage = nil; $0.error = text }
        }
        guard let template = templates.first(where: { $0.id == record.meeting.template }) ?? templates.first else {
            failed(String(localized: "Нет шаблонов итога"))
            return
        }
        do {
            let summary = try await summarizer.generate(
                system: Templates.systemPrompt(for: template),
                prompt: Templates.userPrompt(meeting: record.meeting, notes: notes, transcript: transcript))
            try store.write(summary + "\n", MeetingFile.summary, of: record)
            record = finish { $0.status = .done; $0.error = nil }
            Log.event("processing.done", "folder=\(record.folder.lastPathComponent)")
        } catch SummaryGenerator.SummaryError.cancelled {
            failed(String(localized: "Итог отменён"))
        } catch {
            Log.error("summary.error", error)
            failed(String(localized: "Итог не получился: \(String(describing: error))"))
        }
    }

    private func transcribe(_ record: MeetingRecord) async throws -> Transcript {
        let meeting = record.meeting
        func audio(_ raw: String, _ compressed: String) -> URL? {
            [raw, compressed].map(record.url).first { FileManager.default.fileExists(atPath: $0.path) }
        }
        // A track whose loudest moment is below speech level is skipped.
        // Peaks are unknown for an interrupted recording, so it is always tried.
        func audible(_ peak: Float) -> Bool { meeting.interrupted || peak >= TrackWriter.soundThreshold }

        return try await TranscriptPipeline.build(
            mic: audio(MeetingFile.micRaw, MeetingFile.micAudio).flatMap { audible(meeting.micPeak) ? $0 : nil },
            system: audio(MeetingFile.systemRaw, MeetingFile.systemAudio).flatMap { audible(meeting.systemPeak) ? $0 : nil })
    }

    /// Re-reads meeting.json before changing it, so a title edited in the UI
    /// meanwhile is not overwritten.
    @discardableResult
    private func update(_ record: MeetingRecord, _ change: (inout Meeting) -> Void) -> MeetingRecord {
        var fresh = store.load(folder: record.folder) ?? record
        change(&fresh.meeting)
        try? store.save(fresh)
        onUpdate?(fresh)
        return fresh
    }

    private static func lastWrite(in record: MeetingRecord) -> Date {
        let dates = [MeetingFile.micRaw, MeetingFile.systemRaw, MeetingFile.notes].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: record.url($0).path))?[.modificationDate] as? Date
        }
        return dates.max() ?? record.meeting.startedAt
    }
}
