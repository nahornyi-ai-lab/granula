import AVFoundation
import Foundation

/// Records one meeting: microphone ("Я") and system audio ("Собеседник") to
/// two CAF tracks on one timeline. One track failing never stops the other.
/// Lives on the main thread; capture callbacks only touch the writers.
@MainActor
public final class Recorder {
    public enum TrackState: Equatable, Sendable {
        case starting
        case running
        case failed(String)
    }

    public struct Snapshot: Sendable {
        public var elapsed: TimeInterval
        public var micState: TrackState
        public var systemState: TrackState
        public var micLevel: Float
        public var systemLevel: Float
        public var micDevice: String?
        public var warnings: [String]
    }

    public let record: MeetingRecord
    public let startedAt: Date

    private let micWriter: TrackWriter
    private let systemWriter: TrackWriter
    private var mic = MicCapture()
    private var system = SystemAudioCapture()
    private var micState: TrackState = .starting
    private var systemState: TrackState = .starting
    private var micStartAttempt = Date()
    private var systemStartAttempt = Date()
    private var deviceObserver: AudioDeviceObserver?
    private var watchdog: Timer?
    private var activity: NSObjectProtocol?
    private var watchdogWarnings: [String] = []
    private var rebuildNotice: (text: String, at: Date)?
    private(set) public var isStopped = false

    /// A track with no buffers for this long is rebuilt.
    static let stallTimeout: TimeInterval = 5
    /// System track of exact zeros for this long while the mic hears sound.
    static let silentSystemTimeout: TimeInterval = 60
    static let silentMicTimeout: TimeInterval = 30

    public init(record: MeetingRecord) throws {
        self.record = record
        self.startedAt = record.meeting.startedAt
        micWriter = try TrackWriter(url: record.url(MeetingFile.micRaw), start: startedAt)
        systemWriter = try TrackWriter(url: record.url(MeetingFile.systemRaw), start: startedAt)
    }

    public func start() async {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Granula records a meeting")
        startSystem()
        let micAllowed = await MicCapture.requestAccess()
        // Stop may have been pressed while the permission prompt was up.
        guard !isStopped else { return }
        if micAllowed {
            startMic()
        } else {
            micState = .failed(String(localized: "нет доступа к микрофону"))
            Log.event("mic.denied")
        }
        deviceObserver = AudioDeviceObserver(
            onInputChange: { [weak self] in self?.rebuildMic(reason: "default_input_changed") },
            onOutputChange: { [weak self] in self?.rebuildSystem(reason: "default_output_changed") })
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTracks() }
        }
        Log.event("recording.started", "folder=\(record.folder.lastPathComponent)")
    }

    /// Stops both tracks, pads them to the stop moment and closes the files.
    /// Returns the loudest peak of each track.
    @discardableResult
    public func stop() -> (mic: Float, system: Float) {
        guard !isStopped else { return (micWriter.stats.maxPeak, systemWriter.stats.maxPeak) }
        isStopped = true
        watchdog?.invalidate()
        deviceObserver = nil
        mic.stop()
        system.stop()
        let end = Date()
        micWriter.pad(to: end)
        systemWriter.pad(to: end)
        micWriter.close()
        systemWriter.close()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        let peaks = (micWriter.stats.maxPeak, systemWriter.stats.maxPeak)
        Log.event("recording.stopped",
                  String(format: "duration=%.1f mic_peak=%.4f system_peak=%.4f",
                         end.timeIntervalSince(startedAt), peaks.0, peaks.1))
        return peaks
    }

    public var snapshot: Snapshot {
        let m = micWriter.stats
        let s = systemWriter.stats
        var warnings = watchdogWarnings
        if let notice = rebuildNotice, Date().timeIntervalSince(notice.at) < 10 { warnings.append(notice.text) }
        if case .failed(let why) = micState { warnings.insert(String(localized: "Микрофон не пишется: \(why)"), at: 0) }
        if case .failed(let why) = systemState { warnings.insert(String(localized: "Звук звонка не пишется: \(why)"), at: 0) }
        return Snapshot(
            elapsed: Date().timeIntervalSince(startedAt),
            micState: micState, systemState: systemState,
            micLevel: m.level, systemLevel: s.level,
            micDevice: mic.deviceName, warnings: warnings)
    }

    // MARK: - Tracks

    private func startMic() {
        micStartAttempt = Date()
        let writer = micWriter
        mic.onBuffer = { writer.append($0) }
        do {
            try mic.start()
            micState = .running
        } catch {
            micState = .failed(String(describing: error))
            Log.error("mic.start_failed", error)
        }
    }

    private func startSystem() {
        systemStartAttempt = Date()
        let writer = systemWriter
        system.onBuffer = { writer.append($0) }
        do {
            try system.start()
            systemState = .running
        } catch {
            systemState = .failed(String(describing: error))
            Log.error("system.start_failed", error)
        }
    }

    private func rebuildMic(reason: String) {
        guard !isStopped, MicCapture.isAuthorized else { return }
        Log.event("mic.rebuild", "reason=\(reason)")
        if reason == "no_buffers" { rebuildNotice = (String(localized: "Микрофон не давал звук — переподключаю"), Date()) }
        mic.stop()
        mic = MicCapture()
        startMic()
    }

    private func rebuildSystem(reason: String) {
        guard !isStopped else { return }
        Log.event("system.rebuild", "reason=\(reason)")
        if reason == "no_buffers" { rebuildNotice = (String(localized: "Звук звонка не поступал — переподключаю"), Date()) }
        system.stop()
        system = SystemAudioCapture()
        startSystem()
    }

    private func checkTracks() {
        guard !isStopped else { return }
        let now = Date()
        let m = micWriter.stats
        let s = systemWriter.stats

        // A fresh start gets the full grace period even if old buffers exist.
        let micSince = max(m.lastBufferAt ?? .distantPast, micStartAttempt)
        let systemSince = max(s.lastBufferAt ?? .distantPast, systemStartAttempt)
        if micState == .running, now.timeIntervalSince(micSince) > Self.stallTimeout {
            rebuildMic(reason: "no_buffers")
        } else if case .failed = micState, MicCapture.isAuthorized,
                  now.timeIntervalSince(micStartAttempt) > Self.stallTimeout {
            rebuildMic(reason: "retry_failed")
        }
        if systemState == .running, now.timeIntervalSince(systemSince) > Self.stallTimeout {
            rebuildSystem(reason: "no_buffers")
        } else if case .failed = systemState, now.timeIntervalSince(systemStartAttempt) > Self.stallTimeout {
            rebuildSystem(reason: "retry_failed")
        }

        var warnings: [String] = []
        let elapsed = now.timeIntervalSince(startedAt)
        if micState == .running, elapsed > Self.silentMicTimeout,
           now.timeIntervalSince(m.lastSoundAt ?? startedAt) > Self.silentMicTimeout {
            warnings.append(String(localized: "Микрофон молчит"))
        }
        let micHeardRecently = m.lastSoundAt.map { now.timeIntervalSince($0) < Self.silentSystemTimeout } ?? false
        if systemState == .running, elapsed > Self.silentSystemTimeout, micHeardRecently,
           now.timeIntervalSince(s.lastNonZeroAt ?? startedAt) > Self.silentSystemTimeout {
            warnings.append(String(localized: "Звук звонка не слышен — если это звонок, проверьте разрешение «Запись системного звука»"))
        }
        if warnings != watchdogWarnings {
            watchdogWarnings = warnings
            if !warnings.isEmpty { Log.event("recording.warning", warnings.joined(separator: " | ")) }
        }
    }
}
