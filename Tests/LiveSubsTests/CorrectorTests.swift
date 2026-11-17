import Foundation
import Testing
@testable import LiveSubs

/// The sentences that are polished together: a pause, a change of speaker or a long stretch of
/// talk ends a chunk.
@MainActor
struct CorrectorTests {
    private func item(_ id: String, _ t: Double, _ speaker: String = "说话人") -> Corrector.Item {
        Corrector.Item(id: id, t: t, speaker: speaker, text: "原文 \(id)")
    }

    @Test func aPauseEndsAChunk() {
        let items = [item("a", 0), item("b", 1), item("c", 10)]
        let chunks = Corrector.segment(items)
        #expect(chunks.count == 2)
        #expect(chunks[0].map(\.id) == ["a", "b"])
        #expect(chunks[1].map(\.id) == ["c"])
    }

    @Test func aChangeOfSpeakerEndsAChunk() {
        let items = [item("a", 0, "甲"), item("b", 1, "乙")]
        let chunks = Corrector.segment(items)
        #expect(chunks.count == 2)
    }

    @Test func aLongStretchOfTalkEndsAChunk() {
        // More than a minute after the chunk began: a new chunk starts, even without a pause.
        let items = [item("a", 0), item("b", 61)]
        let chunks = Corrector.segment(items)
        #expect(chunks.count == 2)
    }

    @Test func nearbyTalkStaysInOneChunk() {
        let items = [item("a", 0), item("b", 2), item("c", 4)]
        let chunks = Corrector.segment(items)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 3)
    }

    @Test func theEndOfASentenceShortensTheGapToTheNext() {
        // The last sentence ran until 5s, so the next one at 7s is only 2s away: no new chunk.
        let items = [item("a", 0), item("b", 7)]
        let chunks = Corrector.segment(items, endTimes: ["a": 5])
        #expect(chunks.count == 1)
    }

    @Test func nothingToCorrectIsNoChunk() {
        #expect(Corrector.segment([]).isEmpty)
    }

    @Test func theAnswerComesAsAnObject() {
        // The services are asked for a JSON object, so the sentences come back under a key.
        let reply = #"{"lines":[{"id":"a","text":"改好的 a"},{"id":"b","text":"改好的 b"}]}"#
        let fixed = Corrector.parse(reply)
        #expect(fixed?.count == 2)
        #expect(fixed?.first?.id == "a")
        #expect(fixed?.first?.text == "改好的 a")
    }

    @Test func anAnswerWithSurroundingTextIsStillRead() {
        let reply = "好的，这是结果：\n{\"lines\":[{\"id\":\"a\",\"text\":\"改好的 a\"}]}"
        let fixed = Corrector.parse(reply)
        #expect(fixed?.count == 1)
        #expect(fixed?.first?.text == "改好的 a")
    }

    @Test func aBareArrayIsAlsoRead() {
        // Some services answer with an array even when asked for an object.
        let reply = #"[{"id":"a","text":"改好的 a"}]"#
        let fixed = Corrector.parse(reply)
        #expect(fixed?.count == 1)
        #expect(fixed?.first?.id == "a")
    }

    @Test func anAnswerThatIsNotJsonIsNothing() {
        #expect(Corrector.parse("抱歉，我无法完成这个请求。") == nil)
    }

    @Test func instructionWarnsAgainstHomophones() {
        let p = Corrector.instruction(context: "", glossary: [])
        #expect(p.contains("思维画像"))
        #expect(p.contains("不要因为\"读音通顺\"就保留原文"))
    }

    @Test func contextIsPriorityRule() {
        let p = Corrector.instruction(context: "讨论年度预算", glossary: [])
        #expect(p.contains("本场会议在讲：讨论年度预算"))
        #expect(p.contains("最高优先级依据"))
    }

    @Test func glossaryTermsAreProtected() {
        let p = Corrector.instruction(context: "", glossary: ["思维画像（心理学概念；识别易错为 思维画想）"])
        #expect(p.contains("术语表里的词是本场会议的既定说法"))
        #expect(p.contains("不要按自己的理解改写成别的词"))
    }
}
