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
}
