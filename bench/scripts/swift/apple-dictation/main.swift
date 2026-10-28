// Apple Speech framework (macOS 26+) DictationTranscriber batch runner.
// Usage:
//   apple-dictation --locales                      print supported / installed locales
//   apple-dictation --install ru_RU                download the on-device asset via AssetInventory
//   apple-dictation <list.tsv> <out.jsonl>         transcribe; lang column ru|uk|en (+en mixes use first)
// Build: swiftc -O -parse-as-library main.swift -o apple-dictation
import AVFoundation
import Foundation
import Speech

let localeFor: [String: String] = ["ru": "ru_RU", "uk": "uk_UA", "en": "en_US"]

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func ensureAsset(_ t: DictationTranscriber) async throws -> String {
    let st = await AssetInventory.status(forModules: [t])
    if st == .installed { return "installed" }
    if st == .unsupported { return "unsupported" }
    if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
        try await req.downloadAndInstall()
    }
    return "\(await AssetInventory.status(forModules: [t]))"
}

func transcribe(_ url: URL, locale: Locale) async throws -> String {
    let t = DictationTranscriber(locale: locale, preset: .longDictation)
    let file = try AVAudioFile(forReading: url)
    async let collected: String = t.results.reduce(into: "") { acc, r in
        acc += String(r.text.characters)
    }
    let analyzer = SpeechAnalyzer(modules: [t])
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collected
}

@main
struct Main {
    static func main() async {
        let a = CommandLine.arguments
        do {
            if a.count >= 2 && a[1] == "--locales" {
                let sup = await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
                let ins = await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) }.sorted()
                print("supported:", sup.joined(separator: ","))
                print("installed:", ins.joined(separator: ","))
                for (_, id) in localeFor.sorted(by: { $0.key < $1.key }) {
                    let eq = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: id))
                    let st = await AssetInventory.status(forModules: [DictationTranscriber(locale: Locale(identifier: id), preset: .longDictation)])
                    print(id, "->", eq?.identifier ?? "nil", "status:", st)
                }
                return
            }
            if a.count >= 3 && a[1] == "--install" {
                let t = DictationTranscriber(locale: Locale(identifier: a[2]), preset: .longDictation)
                print(a[2], try await ensureAsset(t))
                return
            }
            guard a.count >= 3 else { err("usage: see header"); exit(2) }
            let rows = try String(contentsOfFile: a[1], encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
            FileManager.default.createFile(atPath: a[2], contents: nil)
            let out = try FileHandle(forWritingTo: URL(fileURLWithPath: a[2]))
            // warm-up
            _ = try? await transcribe(URL(fileURLWithPath: rows[0][1]), locale: Locale(identifier: localeFor[String(rows[0][2].prefix(2))]!))
            for r in rows {
                let lang = String(r[2].split(separator: "+")[0])
                let loc = Locale(identifier: localeFor[lang]!)
                var obj: [String: Any] = ["utt": r[0], "req_lang": lang]
                let s = Date()
                do {
                    obj["text"] = try await transcribe(URL(fileURLWithPath: r[1]), locale: loc)
                } catch {
                    obj["text"] = ""
                    obj["error"] = "\(error)"
                }
                obj["proc_sec"] = Date().timeIntervalSince(s)
                out.write(try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
                out.write("\n".data(using: .utf8)!)
            }
            try out.close()
        } catch {
            err("fatal: \(error)")
            exit(1)
        }
    }
}
