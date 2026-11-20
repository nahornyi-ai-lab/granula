import AVFoundation
import FluidAudio
import Foundation

/// Local speech recognition: Parakeet TDT 0.6B v3 Ultra through FluidAudio
/// (Core ML / Neural Engine). Language is not set — the model switches
/// between Russian, Ukrainian and English by itself.
public actor Transcriber {
    public static let shared = Transcriber()
    static let version: AsrModelVersion = .ultra

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    /// One recognition at a time: the live transcript and the after-meeting
    /// pass share the model, and an actor alone would interleave them at `await`.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public static var modelsDirectory: URL { AsrModels.defaultCacheDirectory(for: version) }

    public static var modelsPresent: Bool { AsrModels.modelsExist(at: modelsDirectory, version: version) }

    /// Downloads the model (~600 MB) if needed and loads it.
    /// Concurrent callers (onboarding, the processor) share one load.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard manager == nil else { return }
        if let loading {
            manager = try await loading.value
            return
        }
        let task = Task<AsrManager, Error> {
            let started = Date()
            let models = try await AsrModels.downloadAndLoad(version: Self.version, progressHandler: { p in
                progress?(p.fractionCompleted)
            })
            let manager = AsrManager(config: ASRConfig(
                tdtConfig: TdtConfig(blankId: Self.version.blankId),
                encoderHiddenSize: Self.version.encoderHiddenSize))
            try await manager.loadModels(models)
            Log.event("asr.ready", String(format: "seconds=%.1f", Date().timeIntervalSince(started)))
            return manager
        }
        loading = task
        do {
            manager = try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    /// Word timings of one audio file.
    public func words(in url: URL) async throws -> [WordTiming] {
        // The model rejects audio shorter than 0.3 s; such a track has no words.
        if let file = try? AVAudioFile(forReading: url),
           Double(file.length) / file.fileFormat.sampleRate < ASRConstants.minimumAudioDurationSeconds {
            return []
        }
        try await prepare()
        await acquire()
        defer { release() }
        guard let manager else { throw ASRError.notInitialized }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &state, language: nil)
        Log.event("asr.done", String(format: "file=%@ audio=%.1f rtfx=%.0f",
                                     url.lastPathComponent, result.duration, result.rtfx))
        return buildWordTimings(from: result.tokenTimings ?? [])
    }

    /// Word timings of 16 kHz mono samples (the live transcript's window).
    /// Times are seconds from the first sample. Needs `prepare()` first.
    public func words(in samples: [Float]) async throws -> [WordTiming] {
        guard !samples.isEmpty else { return [] }
        var samples = samples
        // Shorter audio is rejected by the model; trailing silence changes no word.
        let minimum = Int(ASRConstants.minimumAudioDurationSeconds * TrackWriter.sampleRate) + 1600
        if samples.count < minimum { samples += [Float](repeating: 0, count: minimum - samples.count) }
        await acquire()
        defer { release() }
        guard let manager else { throw ASRError.notInitialized }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        return buildWordTimings(from: result.tokenTimings ?? [])
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
    }

    /// Hands the model to the next caller, or frees it.
    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

extension Transcriber: SpeechRecognizing {
    /// Loads the model for the live transcript; false when it is not downloaded
    /// (a meeting never starts a 600 MB download).
    public func load() async throws -> Bool {
        guard manager != nil || Self.modelsPresent else { return false }
        try await prepare()
        return true
    }
}
