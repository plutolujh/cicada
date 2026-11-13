import Foundation

/// Ling (ant-ling.com), OpenAI-compatible. Two quirks found in testing shape every call:
/// - `thinking` is on by default: always disable it (otherwise +2.6 s and billed reasoning).
/// - When the user message reads like a factual question, the gateway answers it with a search
///   essay instead of following the prompt. So the content always goes in the system message and
///   the user message is a fixed instruction; a search-style reply is detected and dropped.
///
/// The account allows about 2 requests per second across every model, so request *starts* go
/// through one gate (≥ 0.6 s apart, overlapping is fine) in priority order: speak-back,
/// translation, notes. The gate lives in `AIClient`; `startSpacing` is what this service needs.
final class LingProvider: AIProvider {
    let service = AIService.ling
    let displayName = "Ling"
    let models = ["Ling-3.1-flash", "Ling-3.0-flash"]
    let defaultModel = "Ling-3.1-flash"
    let keyURL = URL(string: "https://chat.ant-ling.com/platform/api")
    let keyHint = L("在 Ling 开放平台点“创建令牌”，复制以 sk- 开头的那串。")
    let keyPlaceholder = "sk-…"
    let canSpeak = true
    let canClone = true
    let canInterpret = true
    let voiceTag = "Ming"
    let startSpacing: TimeInterval = 0.6

    static let base = URL(string: "https://api.ant-ling.com/v1/")!
    private static let hijackPrefixes = ["根据现有检索证据", "暂未找到足够可靠的信息", "根据检索"]

    // MARK: Key

    func checkKey(_ key: String, model: String) async throws -> TimeInterval {
        let body: [String: Any] = [
            "model": "Ling-3.0-tiny",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
            "thinking": ["type": "disabled"],
        ]
        let started = Date()
        _ = try await AIHTTP.post(Self.base.appendingPathComponent("chat/completions"), body: body, key: key, timeout: 15)
        return Date().timeIntervalSince(started)
    }

    // MARK: Chat

    func chat(key: String, content: String, instruction: String, model: String, json: Bool,
              maxTokens: Int, timeout: TimeInterval) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": content],
                ["role": "user", "content": instruction],
            ],
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "thinking": ["type": "disabled"],
            "stream": false,
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        let root = try await AIHTTP.post(Self.base.appendingPathComponent("chat/completions"), body: body, key: key, timeout: timeout)
        guard let text = AIHTTP.firstChoice(root) else { throw AIFailure.parse }
        let choice = (root["choices"] as? [[String: Any]])?.first
        let finish = choice?["finish_reason"] as? String
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if finish == nil || Self.hijackPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            debugLog("ling: search-style reply dropped (finish=\(finish ?? "nil"))")
            throw AIFailure.hijacked
        }
        return trimmed
    }

    // MARK: Speech (Ming TTS)

    /// Ming's `language_id` for the languages that need it; Chinese and English speak without one.
    private static func languageID(_ code: String) -> String? {
        ["ja", "ko", "de", "fr", "es"].contains(code) ? code : nil
    }

    /// Streams Ming's voice for `text` as raw 24 kHz mono 16-bit PCM chunks: a built-in `voice`, or
    /// a voice cloned from `reference` (a WAV data URI and what it says). `language` is the
    /// two-letter code of the language the room hears; Chinese and English need no hint.
    func speech(key: String, text: String, voice: String, reference: (audio: String, text: String)?,
                language: String?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var req = URLRequest(url: Self.base.appendingPathComponent("audio/speech"))
                req.httpMethod = "POST"
                req.timeoutInterval = 20
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var body: [String: Any] = [
                    "model": "Ming-3.0-tts-0.5B", "input": text,
                    "response_format": "pcm", "sample_rate": 24000, "stream": true, "stream_format": "sse",
                ]
                if let reference {
                    body["references"] = [["audio": reference.audio, "text": reference.text]]
                    req.timeoutInterval = 30
                } else {
                    body["voice"] = voice
                }
                if let language, let id = Self.languageID(language) { body["language_id"] = id }
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
                    case 200: break
                    case 401, 403: throw AIFailure.invalidKey
                    case 429: throw AIFailure.rateLimited
                    case let code: throw AIFailure.http(code)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"),
                              let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                        else { continue }
                        if obj["type"] as? String == "speech.audio.done" { break }
                        if let b64 = obj["audio"] as? String, let pcm = Data(base64Encoded: b64) { cont.yield(pcm) }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Interpret (Ming's audio model)

    func interpret(key: String, wav: Data, content: String, instruction: String,
                   timeout: TimeInterval) async throws -> String {
        let body: [String: Any] = [
            "model": "Ming-3.0-audio-flash",
            "messages": [
                ["role": "system", "content": content],
                ["role": "user", "content": [
                    ["type": "audio_url", "audio_url": ["url": "data:audio/wav;base64," + wav.base64EncodedString()]],
                    ["type": "text", "text": instruction],
                ]],
            ],
            "max_tokens": 800,
            "temperature": 0.2,
            "thinking": ["type": "disabled"],
            "stream": false,
        ]
        let root = try await AIHTTP.post(Self.base.appendingPathComponent("chat/completions"), body: body, key: key, timeout: timeout)
        guard let text = AIHTTP.firstChoice(root) else { throw AIFailure.parse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
