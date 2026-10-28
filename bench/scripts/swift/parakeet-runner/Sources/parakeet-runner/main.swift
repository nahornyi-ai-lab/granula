// Usage: parakeet-runner <model_dir> <list.tsv> <out.jsonl> [--lang-hint] [--version v3|ultra]
// list.tsv rows: utt \t wav_path \t lang (ru|uk|en|ru+en|uk+en)
// --lang-hint passes FluidAudio's script-aware token filter for single-language files.
import FluidAudio
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: parakeet-runner <model_dir> <list.tsv> <out.jsonl> [--lang-hint]\n".data(using: .utf8)!)
    exit(2)
}
let modelDir = URL(fileURLWithPath: args[1])
let rows = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
let useHint = args.contains("--lang-hint")
FileManager.default.createFile(atPath: args[3], contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))

var version: AsrModelVersion = .v3
if let i = args.firstIndex(of: "--version"), i + 1 < args.count, args[i + 1] == "ultra" { version = .ultra }
let t0 = Date()
let models = try AsrModels.loadLocal(from: modelDir, version: version)
let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize))
try await manager.loadModels(models)
let loadSec = Date().timeIntervalSince(t0)
FileHandle.standardError.write("models loaded in \(loadSec)s\n".data(using: .utf8)!)

// Warm-up so the first measured file does not pay Core ML compilation/caching.
if let first = rows.first {
    var st = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    _ = try await manager.transcribe(URL(fileURLWithPath: first[1]), decoderState: &st, language: nil)
}

for r in rows {
    let utt = r[0], path = r[1], lang = r[2]
    var hint: Language? = nil
    if useHint, !lang.contains("+") { hint = Language(rawValue: lang) }
    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let s = Date()
    var obj: [String: Any] = ["utt": utt]
    do {
        let res = try await manager.transcribe(URL(fileURLWithPath: path), decoderState: &state, language: hint)
        obj["text"] = res.text
        obj["audio_sec"] = res.duration
    } catch {
        obj["text"] = ""
        obj["error"] = "\(error)"
    }
    obj["proc_sec"] = Date().timeIntervalSince(s)
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    out.write(data)
    out.write("\n".data(using: .utf8)!)
}
try out.close()
