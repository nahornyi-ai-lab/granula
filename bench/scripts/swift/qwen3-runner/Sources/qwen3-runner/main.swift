// Usage: qwen3-runner <model_dir> <list.tsv> <out.jsonl> --lang auto|forced
// list.tsv rows: utt \t wav_path \t lang (ru|uk|en|ru+en|uk+en)
// Qwen3-ASR (this Core ML port) accepts at most 30 s per call; longer files are split into
// consecutive <=28 s chunks at the quietest 100 ms frame near the boundary and the texts joined.
import FluidAudio
import Foundation

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write("usage: qwen3-runner <model_dir> <list.tsv> <out.jsonl> --lang auto|forced\n".data(using: .utf8)!)
    exit(2)
}
let forced = args.contains("forced")
let rows = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
FileManager.default.createFile(atPath: args[3], contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))

let manager = Qwen3AsrManager()
let t0 = Date()
try await manager.loadModels(from: URL(fileURLWithPath: args[1]))
FileHandle.standardError.write("models loaded in \(Date().timeIntervalSince(t0))s\n".data(using: .utf8)!)
let converter = AudioConverter()

func chunks(_ x: [Float]) -> [[Float]] {
    let sr = 16000, maxLen = 28 * sr, search = 3 * sr, frame = sr / 10
    var res: [[Float]] = []
    var start = 0
    while x.count - start > maxLen {
        // quietest 100 ms frame within the last 3 s before the 28 s limit
        var best = start + maxLen, bestE = Float.greatestFiniteMagnitude
        var p = start + maxLen - search
        while p + frame <= start + maxLen {
            var e: Float = 0
            for i in p..<(p + frame) { e += x[i] * x[i] }
            if e < bestE { bestE = e; best = p + frame / 2 }
            p += frame / 2
        }
        res.append(Array(x[start..<best]))
        start = best
    }
    res.append(Array(x[start...]))
    return res
}

let firstSamples = try converter.resampleAudioFile(path: rows[0][1])
_ = try await manager.transcribe(audioSamples: Array(firstSamples.prefix(16000 * 5)), language: nil as String?)  // warm-up

for r in rows {
    let utt = r[0], path = r[1], lang = r[2]
    let hint: String? = forced ? String(lang.split(separator: "+")[0]) : nil
    var obj: [String: Any] = ["utt": utt, "req_lang": hint ?? "auto"]
    let s = Date()
    do {
        let samples = try converter.resampleAudioFile(path: path)
        obj["audio_sec"] = Double(samples.count) / 16000.0
        var texts: [String] = []
        let parts = chunks(samples)
        for c in parts {
            texts.append(try await manager.transcribe(audioSamples: c, language: hint))
        }
        obj["n_chunks"] = parts.count
        obj["text"] = texts.joined(separator: " ")
    } catch {
        obj["text"] = ""
        obj["error"] = "\(error)"
    }
    obj["proc_sec"] = Date().timeIntervalSince(s)
    out.write(try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
    out.write("\n".data(using: .utf8)!)
}
try out.close()
