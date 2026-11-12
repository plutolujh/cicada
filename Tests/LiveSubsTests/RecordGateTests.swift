import Testing
@testable import LiveSubs

/// The meeting record only takes a sentence once the language it was heard in is settled: a
/// line transcribed with the wrong model would be translated wrong too. In 自动识别 the language
/// is settled by the detection, and the detection needs a second language to choose from — so
/// on a Mac with one installed model the record would stay empty forever.
@Suite struct RecordGateTests {
    private let chinese = sourceLanguages.first { $0.code == "zh-CN" }!
    private let english = sourceLanguages.first { $0.code == "en" }!

    @Test func aChosenLanguageGoesStraightIn() {
        #expect(RecordGate.recordable(mode: .fixed(chinese), candidates: [], active: nil,
                                      confirmed: false, ambiguous: 0))
    }

    @Test func oneInstalledModelIsTheLanguage() {
        #expect(RecordGate.recordable(mode: .auto, candidates: [chinese], active: chinese,
                                      confirmed: false, ambiguous: 0))
    }

    @Test func oneInstalledModelButAnotherLanguageHeard() {
        // The model in use is not the installed one: the language is not settled after all.
        #expect(!RecordGate.recordable(mode: .auto, candidates: [chinese], active: english,
                                       confirmed: false, ambiguous: 0))
    }

    @Test func twoModelsWaitForTheDetection() {
        #expect(!RecordGate.recordable(mode: .auto, candidates: [chinese, english], active: chinese,
                                       confirmed: false, ambiguous: 0))
    }

    @Test func aSettledLanguageGoesIn() {
        #expect(RecordGate.recordable(mode: .auto, candidates: [chinese, english], active: chinese,
                                      confirmed: true, ambiguous: 0))
    }

    @Test func anUndecidedDetectionStillGoesIn() {
        // Two detections that could not tell the languages apart: the record cannot wait forever.
        #expect(RecordGate.recordable(mode: .auto, candidates: [chinese, english], active: chinese,
                                      confirmed: false, ambiguous: 2))
    }

    @Test func noModelAtAllGoesInNothing() {
        #expect(!RecordGate.recordable(mode: .auto, candidates: [], active: nil,
                                       confirmed: false, ambiguous: 0))
    }
}
