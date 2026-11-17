import XCTest
@testable import GranulaCore

/// Critical positive scenario: the summary prompt works for whoever runs Granula —
/// no owner's name and no interface language baked into what Claude reads.
final class TemplatesTests: XCTestCase {
    func testPromptNamesNoOwnerAndLabelsSpeakers() {
        let meeting = Meeting(id: "m", title: "Weekly sync", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let transcript = Transcript(segments: [
            Segment(speaker: .me, start: 0, end: 2, text: "hello"),
            Segment(speaker: .them, start: 65, end: 67, text: "hi there"),
        ])
        let prompt = Templates.userPrompt(meeting: meeting, notes: "", transcript: transcript)

        XCTAssertTrue(prompt.contains("[00:00] Me: hello"))
        XCTAssertTrue(prompt.contains("[01:05] Them: hi there"))
        // With Latin input, any Cyrillic letter would come from the prompt itself.
        for text in [Templates.system, prompt] {
            XCTAssertNil(text.range(of: "[А-Яа-яЁёІіЇїЄєҐґ]", options: .regularExpression), text)
        }
    }

    func testDefaultTemplatesAreInstalledInOrder() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("granula-templates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        Templates.installDefaults(in: folder)

        let templates = Templates.all(in: folder)
        XCTAssertEqual(templates.map(\.id), ["auto", "negotiation", "one-on-one", "general"])
        XCTAssertFalse(templates.contains { $0.name.isEmpty || $0.body.isEmpty })
    }
}
