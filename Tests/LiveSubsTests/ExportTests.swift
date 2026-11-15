import Foundation
import Testing
@testable import LiveSubs

@Suite struct ExportTests {
    private func line(_ id: String, _ t: Double, _ speaker: String, _ src: String, _ dst: String?) -> TranscriptLine {
        TranscriptLine(id: id, t: t, speaker: speaker, src: src, dst: dst, srcLang: "en", dstLang: "zh-CN")
    }

    private var session: Session {
        Session(id: "s", title: "Weekly", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 600),
                lines: [line("1", 1.5, "them", "Hello.", "你好。"),
                        line("2", 3.25, "me", "Same", "Same"),
                        line("3", 20, "them", "Bye.", nil)],
                hasAudio: false, notes: nil, renamed: true)
    }

    @Test func clockFormats() {
        #expect(TranscriptExport.clock(0) == "00:00")
        #expect(TranscriptExport.clock(-5) == "00:00")
        #expect(TranscriptExport.clock(125.9) == "02:05")
        #expect(TranscriptExport.clock(3725) == "1:02:05")
    }

    @Test func srtTimesAndTranslations() {
        let srt = TranscriptExport.srt(session)
        let cues = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        #expect(cues.count == 3)
        // Ends at the next line, at least 1 s and at most 8 s after it starts.
        #expect(cues[0] == "1\n00:00:01,500 --> 00:00:03,250\nHello.\n你好。")
        // A translation identical to the source isn't repeated.
        #expect(cues[1] == "2\n00:00:03,250 --> 00:00:11,250\nSame")
        // The last line gets 4 s.
        #expect(cues[2] == "3\n00:00:20,000 --> 00:00:24,000\nBye.")
    }

    @Test func markdownHasTitleLinesAndQuotes() {
        let md = TranscriptExport.markdown(session)
        #expect(md.hasPrefix("# Weekly\n\n"))
        #expect(md.contains("**[00:01] 对方**  \nHello.\n> 你好。\n"))
        #expect(md.contains("**[00:03] 你**  \nSame\n\n"))
        #expect(!md.contains("> Same"))
    }

    /// A meeting with notes: a topic with a fishbone, a conclusion and a to-do.
    private var sessionWithNotes: Session {
        var s = session
        s.notes = MeetingNotes(
            summary: "They talked about the release.",
            topics: [NoteTopic(start: 10, title: "The release", summary: "How it went.",
                               points: ["Shipped on Friday"],
                               fishbone: Fishbone(question: "Why late?", branches: [
                                FishboneBranch(label: "Tests", detail: "They were slow", t: 30, support: 2),
                                FishboneBranch(label: "Review", detail: "Two days", t: 40, support: 1),
                               ]))],
            conclusions: [NoteItem(text: "Ship on Friday", owner: nil, support: 3, t: 50)],
            todos: [NoteItem(text: "Write the notes", owner: "me", support: 0, t: nil)],
            terms: [NoteTerm(name: "Cicada", note: "the app", heard: ["知了"])]
        )
        return s
    }

    @Test func theExportHasOnlyWhatWasAskedFor() {
        let s = sessionWithNotes
        var options = ExportOptions()
        options.aiView = false
        options.textSummary = false
        options.transcript = true
        let transcript = TranscriptExport.markdown(s, options: options)
        #expect(transcript.contains(L("原始记录")))
        #expect(transcript.contains("Hello."))
        #expect(!transcript.contains(L("AI 视图")))
        #expect(!transcript.contains(L("文字总结")))

        options.aiView = true
        options.textSummary = false
        options.transcript = false
        let ai = TranscriptExport.markdown(s, options: options)
        #expect(ai.contains(L("AI 视图")))
        // The visualization keeps the fishbone and says what a conclusion rests on.
        #expect(ai.contains("Why late?"))
        #expect(ai.contains("Tests"))
        #expect(ai.contains(L("依据 3 句")))
        #expect(!ai.contains("Hello."))
        #expect(!ai.contains(L("文字总结")))
    }

    @Test func theWrittenSummaryIsThePlainReading() {
        var options = ExportOptions()
        options.aiView = false
        options.textSummary = true
        options.transcript = false
        let md = TranscriptExport.markdown(sessionWithNotes, options: options)
        #expect(md.contains(L("文字总结")))
        #expect(md.contains("They talked about the release."))
        #expect(md.contains("Shipped on Friday"))
        // The fishbone and the grounds belong to the visualization.
        #expect(!md.contains("Why late?"))
        #expect(!md.contains(L("依据 3 句")))
    }

    @Test func anEmptyExportIsEmpty() {
        var options = ExportOptions()
        options.aiView = false
        options.textSummary = false
        options.transcript = false
        #expect(options.isEmpty)
        // The title and the date stay: a file with nothing in it is still a file about a meeting.
        let md = TranscriptExport.markdown(session, options: options)
        #expect(md.hasPrefix("# Weekly\n\n"))
        #expect(!md.contains("Hello."))
    }

    /// Word and PDF are written from the same document as the Markdown, so the choices apply
    /// to them too.
    @Test func theDocumentHasOnlyWhatWasAskedFor() {
        let s = sessionWithNotes
        var options = ExportOptions()
        options.aiView = false
        options.textSummary = false
        options.transcript = true
        let transcript = TranscriptExport.styledDocument(s, options: options).string
        #expect(transcript.contains("Hello."))
        #expect(!transcript.contains("Why late?"))

        options.aiView = true
        options.transcript = false
        let ai = TranscriptExport.styledDocument(s, options: options).string
        #expect(ai.contains("Why late?"))
        #expect(ai.contains("Tests"))
        #expect(!ai.contains("Hello."))
        // Both readings lead with the summary; the fishbone is what tells them apart.
        #expect(ai.contains("They talked about the release."))
    }
}
