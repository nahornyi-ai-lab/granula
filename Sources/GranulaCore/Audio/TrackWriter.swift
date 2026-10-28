import AVFoundation
import Foundation
import os.lock

/// Writes one track as 16 kHz mono Int16 CAF on a wall-clock timeline that
/// starts at the recording start: a late start or a gap (device switch,
/// rebuild) is filled with silence, so both tracks share one time axis.
/// CAF keeps everything already written if the app dies mid-meeting.
public final class TrackWriter: @unchecked Sendable {
    public static let sampleRate: Double = 16_000
    /// A buffer arriving later than this behind the timeline triggers padding.
    static let gapTolerance: TimeInterval = 0.25
    /// Peak at or above this counts as sound (about -54 dBFS). Low on
    /// purpose: quiet call audio must never be skipped as silence.
    public static let soundThreshold: Float = 0.002

    public struct Stats: Sendable {
        public var lastBufferAt: Date?
        public var lastSoundAt: Date?
        public var lastNonZeroAt: Date?
        public var level: Float = 0
        public var maxPeak: Float = 0
        public var seconds: TimeInterval = 0
    }

    public let url: URL
    private let start: Date
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: TrackWriter.sampleRate, channels: 1, interleaved: false)!

    private struct State {
        var file: AVAudioFile?
        var converter: AVAudioConverter?
        var converterInput: AVAudioFormat?
        var framesWritten: AVAudioFramePosition = 0
        var stats = Stats()
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init(url: URL, start: Date) throws {
        self.url = url
        self.start = start
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        state.withLockUnchecked { $0.file = file }
    }

    public var stats: Stats { state.withLockUnchecked { $0.stats } }

    /// Append a captured buffer that has just arrived (any format).
    public func append(_ buffer: AVAudioPCMBuffer, arrival: Date = Date()) {
        state.withLockUnchecked { s in
            guard let file = s.file, buffer.frameLength > 0 else { return }
            guard let converted = convert(buffer, state: &s) else { return }

            // Where on the timeline this buffer starts.
            let bufferStart = arrival.timeIntervalSince(start) - Double(buffer.frameLength) / buffer.format.sampleRate
            let expected = AVAudioFramePosition(max(0, bufferStart) * Self.sampleRate)
            let lag = expected - s.framesWritten
            if lag > AVAudioFramePosition(Self.gapTolerance * Self.sampleRate) {
                writeSilence(frames: lag, to: file, state: &s)
            }

            do {
                try file.write(from: converted)
                s.framesWritten += AVAudioFramePosition(converted.frameLength)
            } catch {
                Log.error("track.write_failed \(url.lastPathComponent)", error)
            }

            let peak = Self.peak(of: converted)
            s.stats.lastBufferAt = arrival
            s.stats.level = max(peak, s.stats.level * 0.8)
            s.stats.maxPeak = max(s.stats.maxPeak, peak)
            if peak > 0 { s.stats.lastNonZeroAt = arrival }
            if peak >= Self.soundThreshold { s.stats.lastSoundAt = arrival }
            s.stats.seconds = Double(s.framesWritten) / Self.sampleRate
        }
    }

    /// Extend the track with silence up to `date` (used at stop, so both
    /// tracks end at the same moment even if one died early).
    public func pad(to date: Date) {
        state.withLockUnchecked { s in
            guard let file = s.file else { return }
            let expected = AVAudioFramePosition(max(0, date.timeIntervalSince(start)) * Self.sampleRate)
            let lag = expected - s.framesWritten
            if lag > 0 { writeSilence(frames: lag, to: file, state: &s) }
            s.stats.seconds = Double(s.framesWritten) / Self.sampleRate
        }
    }

    public func close() {
        state.withLockUnchecked { s in
            if #available(macOS 15.0, *) { s.file?.close() }
            s.file = nil
            s.converter = nil
        }
    }

    // MARK: -

    private func convert(_ buffer: AVAudioPCMBuffer, state s: inout State) -> AVAudioPCMBuffer? {
        let input = buffer.format
        if input.sampleRate == outFormat.sampleRate, input.channelCount == 1,
           input.commonFormat == .pcmFormatFloat32, !input.isInterleaved {
            return buffer
        }
        if s.converter == nil || s.converterInput != input {
            s.converter = AVAudioConverter(from: input, to: outFormat)
            s.converter?.downmix = true
            s.converterInput = input
        }
        guard let converter = s.converter else { return nil }
        let ratio = outFormat.sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.event("track.convert_failed", "\(url.lastPathComponent) \(error?.localizedDescription ?? "")")
            return nil
        }
        return out
    }

    private func writeSilence(frames: AVAudioFramePosition, to file: AVAudioFile, state s: inout State) {
        var remaining = frames
        let chunk: AVAudioFrameCount = 16_000
        while remaining > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            guard let silent = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: n) else { return }
            silent.frameLength = n
            if let data = silent.floatChannelData { memset(data[0], 0, Int(n) * MemoryLayout<Float>.size) }
            do { try file.write(from: silent) } catch {
                Log.error("track.pad_failed \(url.lastPathComponent)", error)
                return
            }
            s.framesWritten += AVAudioFramePosition(n)
            remaining -= AVAudioFramePosition(n)
        }
    }

    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        var peak: Float = 0
        let samples = data[0]
        for i in 0..<n { peak = max(peak, abs(samples[i])) }
        return peak
    }
}
