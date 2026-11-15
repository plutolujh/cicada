import Foundation

/// Polishes the words speech recognition got wrong.
///
/// The recognizer hears sounds, not words: 红西 for 虹吸, 一块 for 一块儿, a comma where a full
/// stop belongs. This sends the text to the AI service and asks for the same sentences back with
/// the typos, homophones and punctuation fixed — and nothing else changed.
///
/// The original is always kept: a correction is a second copy of the sentence, so the reader can
/// still see what was actually said and can undo the change.
@MainActor
enum Corrector {
    /// One sentence to polish.
    struct Item: Codable, Identifiable {
        let id: String
        let t: Double
        let speaker: String
        let text: String
    }

    /// The polished sentence coming back.
    struct Fixed: Codable {
        let id: String
        let text: String
    }

    /// Splits the sentences into the chunks that are corrected together: a pause, a change of
    /// speaker or a long stretch of talk ends a chunk.
    static func segment(_ items: [Item], endTimes: [String: Double] = [:]) -> [[Item]] {
        guard !items.isEmpty else { return [] }
        var segments: [[Item]] = []
        var current: [Item] = []
        var segStart = items[0].t
        for item in items {
            let prev = current.last
            let gap = prev.map { _ in item.t - (endTimes[prev!.id] ?? prev!.t) } ?? 0
            let speakerChange = prev.map { $0.speaker != item.speaker } ?? false
            let tooLong = item.t - segStart > 60
            if !current.isEmpty && (gap > 3.0 || speakerChange || tooLong) {
                segments.append(current)
                current = []
                segStart = item.t
            }
            current.append(item)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Reads the answer. The service is asked for a JSON object (the providers ask for one), so
    /// the sentences come back under a key; a bare array is accepted too, in case the service
    /// answers that way.
    static func parse(_ reply: String) -> [Fixed]? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            // The service may have put a word or two around the JSON: take the JSON out of it.
            guard let body = jsonPart(of: trimmed),
                  let data = body.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return fixed(in: root)
        }
        return fixed(in: root)
    }

    /// The JSON inside a reply that has something else around it.
    private static func jsonPart(of text: String) -> String? {
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b {
            return String(text[a...b])
        }
        if let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b {
            return String(text[a...b])
        }
        return nil
    }

    private static func fixed(in root: Any) -> [Fixed]? {
        if let array = root as? [Any] {
            return decode(array)
        }
        guard let object = root as? [String: Any] else { return nil }
        for key in ["lines", "items", "result", "results"] {
            if let array = object[key] as? [Any] { return decode(array) }
        }
        return nil
    }

    private static func decode(_ array: [Any]) -> [Fixed]? {
        var out: [Fixed] = []
        for element in array {
            guard let item = element as? [String: Any] else { continue }
            let id = (item["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty, !text.isEmpty else { continue }
            out.append(Fixed(id: id, text: text))
        }
        return out
    }

    /// Polishes one chunk: the AI gets the sentences with their times and speakers, and answers
    /// with the same sentences in the same order.
    static func correct(items: [Item], endTimes: [String: Double] = [:], glossary: [String], ai: AIClient) async -> [(id: String, text: String)] {
        guard let inputData = try? JSONEncoder().encode(items),
              let inputJSON = String(data: inputData, encoding: .utf8) else { return [] }
        var instruction = """
        你是会议转写润色助手。收到一段语音识别原文（含时间戳、说话人），请仅修正错别字、同音字、漏字、多余字、标点。
        严格要求：
        - 不改说话人标签、不改时间、不增删行、不改变语序、不合并/拆分句子
        - 不润色成书面语，保持口语原貌
        - 只输出一个 JSON 对象，形如 {"lines":[{"id":"原id","text":"修正后文本"}]}，与输入顺序、id 一一对应
        - 某行无需修改时 text 填原文
        """
        if !glossary.isEmpty {
            instruction += "\n已知术语/人名（识别易错→正确）：\n" + glossary.prefix(30).map { "- \($0)" }.joined(separator: "\n")
        }
        do {
            let reply = try await ai.chat(content: inputJSON, instruction: instruction, priority: .notes, json: true, maxTokens: 4096, timeout: 45)
            guard let outs = parse(reply) else {
                debugLog("correct: parse failed for segment of \(items.count)")
                return []
            }
            // Only the sentences that really changed are kept: a line that came back the same is
            // not a correction, and marking it as one would put a badge on every sentence.
            var out: [(id: String, text: String)] = []
            for item in items {
                guard let fixed = outs.first(where: { $0.id == item.id }) else { continue }
                let clean = fixed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean != item.text else { continue }
                out.append((item.id, clean))
            }
            return out
        } catch {
            debugLog("correct: failed: \(error.localizedDescription)")
            return []
        }
    }
}
