import Foundation
import Testing
@testable import GranulaCore

// "From → To" of the live translation: which languages a line is told between,
// what is kept between launches, and which pair a meeting is translated with.

@Suite struct LiveLanguagesTests {
    @Test func autoTellsAmongTheMeetingLanguages() {
        let settings = LiveSettings(target: "ru", source: nil, languages: ["ru", "uk", "en"])
        #expect(settings.detectionLanguages == ["ru", "uk", "en"])
    }

    @Test func fromToTellsEachLineBetweenTheTwo() {
        #expect(LiveSettings(target: "ru", source: "en", languages: ["uk"]).detectionLanguages == ["en", "ru"])
        #expect(LiveSettings(target: "ru", source: "es", languages: ["uk"]).detectionLanguages == ["es", "ru"])
    }

    @Test func targetNobodySpeaksIsLeftOut() {
        // Japanese is a translation target, but the speech model does not hear it.
        #expect(LiveSettings(target: "ja", source: "en").detectionLanguages == ["en"])
    }

    @Test func fromEqualToTargetMeansAuto() {
        #expect(LiveSettings(target: "ru", source: "ru", languages: ["ru", "en"]).detectionLanguages == ["ru", "en"])
    }

    @Test func fromIsOffWithoutATarget() {
        // The picker is greyed out then: the meeting languages decide.
        #expect(LiveSettings.detectionLanguages(source: "en", target: nil, languages: ["ru", "uk"]) == ["ru", "uk"])
    }

    @Test func transcriptKeepsTheMeetingPairAndAddsAThirdTarget() {
        let languages = ["ru", "uk", "en", "es"]
        // Recorded English → Russian: the Russian lines are still there in a Ukrainian translation.
        #expect(LiveSettings.transcriptLanguages(meetingFrom: "en", meetingTo: "ru", target: "uk", languages: languages)
            == ["en", "ru", "uk"])
        #expect(LiveSettings.transcriptLanguages(meetingFrom: "en", meetingTo: "ru", target: "ru", languages: languages)
            == ["en", "ru"])
        #expect(LiveSettings.transcriptLanguages(meetingFrom: "en", meetingTo: "ru", target: "en", languages: languages)
            == ["en", "ru"])
        // Recorded on Auto: the meeting languages.
        #expect(LiveSettings.transcriptLanguages(meetingFrom: nil, meetingTo: "ru", target: "uk", languages: languages)
            == languages)
        // A target nobody speaks is not a line's language.
        #expect(LiveSettings.transcriptLanguages(meetingFrom: "es", meetingTo: "ru", target: "ja", languages: languages)
            == ["es", "ru"])
    }

    @Test func fromAndTheWindowAreKeptBetweenLaunches() throws {
        let defaults = try #require(UserDefaults(suiteName: "granula-test-\(UUID().uuidString)"))
        var settings = LiveSettings.load(from: defaults)
        #expect(settings.source == nil)
        #expect(settings.window, "the live window is on until the owner closes it")
        settings.source = "es"
        settings.target = "ru"
        settings.window = false
        settings.save(to: defaults)
        let loaded = LiveSettings.load(from: defaults)
        #expect(loaded.source == "es")
        #expect(loaded.target == "ru")
        #expect(!loaded.window)
        // A language the model no longer knows falls back to Auto.
        defaults.set("xx", forKey: "translationSource")
        #expect(LiveSettings.load(from: defaults).source == nil)
    }

    @Test func meetingKeepsItsPair() throws {
        var meeting = Meeting(id: "m", title: "Call", startedAt: Date(timeIntervalSince1970: 0))
        meeting.translateTo = "ru"
        meeting.translateFrom = "es"
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        #expect(decoded.translateFrom == "es")
        #expect(decoded.translateTo == "ru")
        // Meetings saved before "From" existed read as Auto.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        json["translateFrom"] = nil
        let old = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.translateFrom == nil)
    }

    @Test func spanishEnglishAndRussianLinesAreTold() {
        #expect(LanguageDetector.detect("Podemos firmar el contrato la próxima semana", among: ["es", "ru"], previous: nil) == "es")
        #expect(LanguageDetector.detect("Хорошо, тогда переносим запуск", among: ["es", "ru"], previous: nil) == "ru")  // not localized: test speech
        #expect(LanguageDetector.detect("The client agreed to move the launch", among: ["en", "ru"], previous: nil) == "en")
        #expect(LanguageDetector.detect("Sí", among: ["es", "ru"], previous: "es") == "es")
    }
}
