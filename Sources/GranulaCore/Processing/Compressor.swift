import AVFoundation
import Foundation

/// CAF (16 kHz PCM) → AAC `.m4a` at ~32 kbit/s mono. The CAF is deleted only
/// after the m4a has been fully written and reads back with the same length.
public enum Compressor {
    public static func compress(_ caf: URL, to m4a: URL) throws {
        let input = try AVAudioFile(forReading: caf)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let temp = m4a.deletingLastPathComponent().appendingPathComponent(".\(m4a.lastPathComponent).partial.m4a")
        try? FileManager.default.removeItem(at: temp)
        do {
            let output = try AVAudioFile(forWriting: temp, settings: settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            let chunk: AVAudioFrameCount = 16_000 * 10
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw CocoaError(.fileWriteUnknown)
            }
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            if #available(macOS 15.0, *) { output.close() }
        }
        // Verify before replacing anything: same duration within half a second.
        let check = try AVAudioFile(forReading: temp)
        let inSeconds = Double(input.length) / format.sampleRate
        let outSeconds = Double(check.length) / check.processingFormat.sampleRate
        guard abs(inSeconds - outSeconds) < 0.5 || inSeconds == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "сжатый файл короче исходного: \(outSeconds) из \(inSeconds) с")])
        }
        try? FileManager.default.removeItem(at: m4a)
        try FileManager.default.moveItem(at: temp, to: m4a)
        try FileManager.default.removeItem(at: caf)
    }
}
