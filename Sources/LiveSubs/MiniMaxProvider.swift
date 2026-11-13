import Foundation

/// MiniMax (minimaxi.com), OpenAI-compatible for text and with its own speech endpoint.
///
/// Four differences from Ling shape every call:
/// - The answers carry the real status in the body (`base_resp`), so a 200 can still be a failure.
/// - The text models think unless they are told not to. M3.1-Flash cannot be told: it always
///   thinks, and the thinking counts against the token budget, so the budget gets room for it.
///   M3 thinks only when it is asked to, and a short answer should not pay for that.
/// - `temperature` and `top_p` are ignored (fixed at 1 and 0.95), so they are not sent.
/// - The models come and go, so only the ones the platform still serves are offered.
///
/// It has no audio model, so pressing the talk key is transcribed on this Mac and translated as
/// text, and it cannot clone a voice: the room gets one of its own voices.
final class MiniMaxProvider: AIProvider {
    let service = AIService.minimax
    let displayName = "MiniMax"

    /// M3.1 Flash is what the subscription plans cover; M3 is the same family without the plan.
    static let availableModels = ["MiniMax-M3.1-Flash", "MiniMax-M3"]
    static let defaultModelName = "MiniMax-M3.1-Flash"
    var models: [String] { Self.availableModels }
    var defaultModel: String { Self.defaultModelName }

    let keyURL = URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key")
    let keyHint = L("在 MiniMax 开放平台创建 API Key，复制那串密钥。")
    let keyPlaceholder = "eyJ…"
    let canSpeak = true
    let canClone = false
    let canInterpret = false
    let voiceTag = "MiniMax"
    let startSpacing: TimeInterval = 0.1

    /// The Chinese endpoint. The international one is api.minimax.io: point the "自定义" service at
    /// https://api.minimax.io/v1 with the same key to use it.
    static let base = URL(string: "https://api.minimaxi.com/v1/")!
    static let speechModel = "speech-2.8-turbo"

    // MARK: Key

    /// The key is checked with the model the app will use: a model the platform has retired
    /// answers 404 with the code 2069, and that is a different problem from a wrong key, so the
    /// app has to be able to tell them apart.
    func checkKey(_ key: String, model: String) async throws -> TimeInterval {
        let name = Self.availableModels.contains(model) ? model : Self.defaultModelName
        var body = Self.body(model: name, maxTokens: 64)
        body["messages"] = [["role": "user", "content": "hi"]]
        let started = Date()
        do {
            _ = try await AIHTTP.post(Self.base.appendingPathComponent("chat/completions"), body: body, key: key, timeout: 15)
        } catch AIFailure.http(let code) {
            // The platform says what is wrong in the body; its code says more than the status.
            throw Self.failure(code)
        }
        return Date().timeIntervalSince(started)
    }

    // MARK: Chat

    func chat(key: String, content: String, instruction: String, model: String, json: Bool,
              maxTokens: Int, timeout: TimeInterval) async throws -> String {
        let name = model.isEmpty ? Self.defaultModelName : model
        var body = Self.body(model: name, maxTokens: maxTokens)
        body["messages"] = [
            ["role": "system", "content": content],
            ["role": "user", "content": instruction],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        do {
            return try await Self.ask(body, key: key, timeout: timeout)
        } catch AIFailure.http(2013) {
            // The JSON mode and the thinking knobs are not in every deployment's schema. Drop them
            // and ask again; the prompt asks for JSON either way.
            var plain = body
            plain.removeValue(forKey: "response_format")
            plain.removeValue(forKey: "reasoning_effort")
            plain.removeValue(forKey: "thinking")
            return try await Self.ask(plain, key: key, timeout: timeout)
        }
    }

    /// One chat call, with MiniMax's own codes turned into failures the app understands.
    private static func ask(_ body: [String: Any], key: String, timeout: TimeInterval) async throws -> String {
        do {
            let root = try await AIHTTP.post(Self.base.appendingPathComponent("chat/completions"),
                                            body: body, key: key, timeout: timeout)
            try Self.checkBody(root)
            guard let text = AIHTTP.firstChoice(root) else { throw AIFailure.parse }
            return Self.answer(text)
        } catch AIFailure.http(let code) {
            throw Self.failure(code)
        }
    }

    /// The body every text call shares: the model, the token budget and the thinking settings.
    private static func body(model: String, maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            // The thinking goes to its own field, so only the answer is left in `content`.
            "reasoning_split": true,
        ]
        if model.contains("M3.1") {
            // M3.1-Flash always thinks and cannot be told not to: think as little as it allows, and
            // give the budget room for the thinking, which counts against it.
            body["reasoning_effort"] = "low"
            body["max_completion_tokens"] = maxTokens + 2048
        } else {
            // M3 thinks only when it is asked to, and a short answer should not pay for it.
            body["thinking"] = ["type": "disabled"]
            body["max_completion_tokens"] = maxTokens
        }
        return body
    }

    /// The answer without the thinking: some replies keep the thinking in the text.
    private static func answer(_ text: String) -> String {
        var out = text
        while let open = out.range(of: "<think>"), let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Speech

    /// The whole utterance comes back at once, as hex PCM: the app plays 24 kHz mono 16-bit, so
    /// that is what is asked for.
    func speech(key: String, text: String, voice: String, reference: (audio: String, text: String)?,
                language: String?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                guard reference == nil else {
                    cont.finish(throwing: AIFailure.unsupported)
                    return
                }
                var body: [String: Any] = [
                    "model": Self.speechModel,
                    "text": text,
                    "stream": false,
                    "voice_setting": ["voice_id": voice, "speed": 1.0, "vol": 1.0, "pitch": 0],
                    "audio_setting": ["sample_rate": 24000, "format": "pcm", "channel": 1],
                ]
                if let language, let name = Self.languageName(language) { body["language_boost"] = name }
                var req = URLRequest(url: Self.base.appendingPathComponent("t2a_v2"))
                req.httpMethod = "POST"
                req.timeoutInterval = 30
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (data, response) = try await URLSession.shared.data(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw Self.httpFailure(status, data: data) }
                    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIFailure.parse }
                    try Self.checkBody(root)
                    guard let hex = (root["data"] as? [String: Any])?["audio"] as? String, !hex.isEmpty else { throw AIFailure.parse }
                    guard let pcm = Self.decode(hex) else { throw AIFailure.parse }
                    cont.yield(pcm)
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Interpret

    func interpret(key: String, wav: Data, content: String, instruction: String,
                   timeout: TimeInterval) async throws -> String {
        throw AIFailure.unsupported
    }

    // MARK: Body

    /// The language the room hears, spelled the way MiniMax writes it, so a voice that is not
    /// native to it still says the right words.
    private static func languageName(_ code: String) -> String? {
        switch code {
        case "zh": "Chinese"
        case "en": "English"
        case "ja": "Japanese"
        case "ko": "Korean"
        case "es": "Spanish"
        case "fr": "French"
        case "de": "German"
        case "pt": "Portuguese"
        default: nil
        }
    }

    /// MiniMax answers 200 with the real status inside the body.
    private static func checkBody(_ root: [String: Any]) throws {
        guard let base = root["base_resp"] as? [String: Any] else { return }
        let code = base["status_code"] as? Int ?? 0
        guard code != 0 else { return }
        let message = base["status_msg"] as? String ?? ""
        debugLog("minimax: \(code) \(message)")
        throw Self.failure(code)
    }

    /// The failure for a status the API did not like: the platform code in the body if there is
    /// one, the HTTP status otherwise.
    private static func httpFailure(_ status: Int, data: Data) -> AIFailure {
        switch status {
        case 401, 403: return .invalidKey
        case 429: return .rateLimited
        default: break
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let base = root["base_resp"] as? [String: Any],
           let code = base["status_code"] as? Int, code != 0 {
            return failure(code)
        }
        return .http(status)
    }

    /// What MiniMax's own codes mean. The plans are metered in windows, so "used up" and "not in
    /// your plan" are everyday answers, not accidents.
    private static func failure(_ code: Int) -> AIFailure {
        switch code {
        case 1004, 2049: return .invalidKey      // no key, or the wrong one
        case 1002, 1045: return .rateLimited     // too many requests
        case 1008, 2053, 2056, 2062: return .quota   // no balance, or the plan's allowance is gone
        case 2057, 2061: return .plan            // the key or the model is not in the plan
        case 2069: return .retired               // the model is gone (the platform retired it)
        default: return .http(code)
        }
    }

    /// The audio comes back as hex for PCM; base64 is tried too, in case the format changes.
    private static func decode(_ text: String) -> Data? {
        let hex = text.count.isMultiple(of: 2) && text.allSatisfy { $0.isHexDigit } ? text : ""
        if !hex.isEmpty, let data = Data(hexString: hex) { return data }
        return Data(base64Encoded: text)
    }
}

extension Data {
    /// Bytes from a hex string, or nothing when it is not one.
    init?(hexString: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
