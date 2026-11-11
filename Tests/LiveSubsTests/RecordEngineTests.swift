import Foundation
import Testing
@testable import LiveSubs

/// The running summary comes from the model as JSON, sometimes wrapped in prose.
@Suite struct RecordEngineTests {
    @Test func readsTopicsOutOfJSON() {
        let topics = RecordEngine.parse(#"{"topics":[{"title":"人物身份确认","detail":"他来自科沃斯。","points":["1990 年出生。"]}]}"#)
        #expect(topics?.count == 1)
        #expect(topics?[0].title == "人物身份确认")
        #expect(topics?[0].detail == "他来自科沃斯。")
        #expect(topics?[0].points == ["1990 年出生。"])
    }

    @Test func findsJSONInsideProse() {
        let topics = RecordEngine.parse("Here is the summary:\n{\"topics\":[{\"title\":\"A\",\"detail\":\"B\",\"points\":[]}]}\nHope that helps.")
        #expect(topics?.count == 1)
        #expect(topics?[0].title == "A")
    }

    @Test func keepsFailingAnswersWithoutCrashing() {
        // The closing brace before the opening one: the range is not a range, and asking for it
        // used to stop the app.
        #expect(RecordEngine.parse("} nothing { here") == nil)
        #expect(RecordEngine.parse("no json at all") == nil)
        #expect(RecordEngine.parse("") == nil)
        #expect(RecordEngine.parse("{\"topics\":[]}") == nil)
        #expect(RecordEngine.parse("{\"other\":1}") == nil)
    }

    @Test func dropsTopicsWithoutATitle() {
        let topics = RecordEngine.parse(#"{"topics":[{"title":"  ","detail":"x"},{"title":"B"}]}"#)
        #expect(topics?.count == 1)
        #expect(topics?[0].title == "B")
    }

    @Test func readsTheClockLikeARecording() {
        #expect(RecordEngine.clock(0) == "00:00")
        #expect(RecordEngine.clock(15) == "00:15")
        #expect(RecordEngine.clock(146) == "02:26")
        #expect(RecordEngine.clock(3600) == "60:00")
    }

    @Test func peopleAreNumberedInTheOrderTheyAreHeard() {
        var p = PersonNumbers()
        #expect(p.number(for: 0) == 1)
        #expect(p.number(for: 3) == 2)      // the ids are not in order, the voices are
        #expect(p.number(for: 0) == 1)      // the same voice keeps its number
        #expect(p.number(for: 7) == 3)
        #expect(p.count == 3)
    }

    @MainActor
    @Test func aSentenceCanBeCorrectedMergedAndSplit() {
        let engine = RecordEngine()
        engine.demo()
        let before = engine.lines.count

        // The words of a sentence can be corrected.
        engine.edit("d0", text: "改过的句子")
        #expect(engine.lines.first(where: { $0.id == "d0" })?.text == "改过的句子")
        // An empty correction is refused: a sentence with no words is not a sentence.
        engine.edit("d0", text: "   ")
        #expect(engine.lines.first(where: { $0.id == "d0" })?.text == "改过的句子")

        // Two sentences become one.
        engine.merge("d0", with: "d1")
        #expect(engine.lines.count == before - 1)
        #expect(engine.lines[0].text.contains("改过的句子"))
        #expect(engine.lines[0].text.contains("这是个好问题"))

        // A sentence can be cut in two again.
        engine.split("d0", at: 3)
        #expect(engine.lines.count == before)
        #expect(engine.lines[0].text == "改过的")
        #expect(engine.lines[1].text == "句子 这是个好问题。")
        // The two halves keep their order in time.
        #expect(engine.lines[0].t <= engine.lines[1].t)
    }

    @MainActor
    @Test func aSplitKeepsTheVoiceOfTheSentenceItCameFrom() {
        let engine = RecordEngine()
        engine.demo()
        let person = engine.lines[0].person
        engine.split("d0", at: 3)
        #expect(engine.lines[1].person == person)
    }

    @Test func theWordsOfASentenceAreSplitOut() {
        // A plain string has no word times, but the words still come out in order.
        let words = RecordEngine.words(of: AttributedString("你好 世界"))
        #expect(words.count == 2)
        #expect(words[0].text == "你好")
        #expect(words[1].text == "世界")
    }

    @Test func chineseIsWrittenLetterByLetter() {
        // Chinese has no spaces, so each character is a word of its own.
        let words = RecordEngine.words(of: AttributedString("讨论一下"))
        #expect(words.count == 4)
        #expect(words.map(\.text) == ["讨", "论", "一", "下"])
    }

    @Test func englishKeepsItsWordsWhole() {
        let words = RecordEngine.words(of: AttributedString("that is a question"))
        #expect(words.map(\.text) == ["that", "is", "a", "question"])
    }
}
