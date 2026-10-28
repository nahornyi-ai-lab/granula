// Usage: canary-runner <model_dir> <list.tsv> <out.jsonl> [--units gpu]
// Canary-1B-v2 (FluidAudio Core ML int4, beta). Canary has no automatic language ID: the source
// language must be given, so each row is transcribed with its own language (first one for mixes).
// Files > 15 s use FluidAudio's overlapping 15 s windows with token-level seam merge.
// --units gpu loads encoder/decoder/projection on CPU+GPU instead of FluidAudio's default ANE
// (the int4 ANE compile did not finish in 20 min on macOS 26.6 / M4 Pro).
import CoreML
import FluidAudio
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: canary-runner <model_dir> <list.tsv> <out.jsonl>\n".data(using: .utf8)!)
    exit(2)
}
let rows = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
FileManager.default.createFile(atPath: args[3], contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))

let t0 = Date()
let dir = URL(fileURLWithPath: args[1])
let models: CanaryModels
if args.contains("gpu") {
    func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
        let c = MLModelConfiguration()
        c.computeUnits = units
        return try MLModel(contentsOf: dir.appendingPathComponent(name + ".mlmodelc"), configuration: c)
    }
    models = CanaryModels(
        preprocessor: try load("Preprocessor", .cpuOnly), encoder: try load("EncoderInt4", .cpuAndGPU),
        decoder: try load("DecoderInt4", .cpuAndGPU), projection: try load("Projection", .cpuAndGPU),
        tokenizer: try Tokenizer(vocabPath: dir.appendingPathComponent("vocab.json")))
} else {
    models = try CanaryModels.load(from: dir, precision: .int4)
}
var managers: [String: CanaryManager] = [:]
for (code, lang) in [("ru", CanaryLanguage.russian), ("uk", .ukrainian), ("en", .english)] {
    managers[code] = try CanaryManager(models: models, source: lang, target: lang, pnc: true)
}
FileHandle.standardError.write("models loaded in \(Date().timeIntervalSince(t0))s\n".data(using: .utf8)!)
_ = try await managers["en"]!.transcribe(audioURL: URL(fileURLWithPath: rows[0][1]))  // warm-up

for r in rows {
    let utt = r[0], path = r[1]
    let lang = String(r[2].split(separator: "+")[0])
    var obj: [String: Any] = ["utt": utt, "req_lang": lang]
    let s = Date()
    do {
        obj["text"] = try await managers[lang]!.transcribe(audioURL: URL(fileURLWithPath: path))
    } catch {
        obj["text"] = ""
        obj["error"] = "\(error)"
    }
    obj["proc_sec"] = Date().timeIntervalSince(s)
    out.write(try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
    out.write("\n".data(using: .utf8)!)
}
try out.close()
