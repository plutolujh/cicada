import Foundation

/// Any other service that speaks the OpenAI dialect: the user gives the address and the model
/// name. Text only — there is no way to know what a speech endpoint of an unknown service looks
/// like, so the room keeps the Mac's voice.
final class CustomProvider: AIProvider {
    let service = AIService.custom
    let displayName = L("自定义")
    let canSpeak = false
    let canClone = false
    let canInterpret = false
    let voiceTag = ""
    let startSpacing: TimeInterval = 0.1

    /// The address the user gave, and the model name with it.
    var baseURL: () -> String = { "" }
    var modelName: () -> String = { "" }

    var keyURL: URL? { nil }
    var keyHint: String { L("填入服务商的接口地址和模型名，再填它的 API key。") }
    var keyPlaceholder: String { "sk-…" }

    var models: [String] {
        let name = modelName().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? [] : [name]
    }
    var defaultModel: String { models.first ?? "" }

    /// The address to call, with the `/v1` the OpenAI dialect expects when it is missing.
    private var endpoint: URL? {
        var text = baseURL().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.hasPrefix("http://"), !text.hasPrefix("https://") { text = "https://" + text }
        if !text.hasSuffix("/") { text += "/" }
        return URL(string: text)
    }

    // MARK: Key

    func checkKey(_ key: String, model: String) async throws -> TimeInterval {
        let started = Date()
        _ = try await chat(key: key, content: "Reply with one word.", instruction: "hi", model: defaultModel,
                           json: false, maxTokens: 1, timeout: 15)
        return Date().timeIntervalSince(started)
    }

    // MARK: Chat

    func chat(key: String, content: String, instruction: String, model: String, json: Bool,
              maxTokens: Int, timeout: TimeInterval) async throws -> String {
        guard let base = endpoint else { throw AIFailure.unsupported }
        let name = model.isEmpty ? defaultModel : model
        guard !name.isEmpty else { throw AIFailure.unsupported }
        var body: [String: Any] = [
            "model": name,
            "messages": [
                ["role": "system", "content": content],
                ["role": "user", "content": instruction],
            ],
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "stream": false,
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        let root = try await AIHTTP.post(base.appendingPathComponent("chat/completions"), body: body, key: key, timeout: timeout)
        guard let text = AIHTTP.firstChoice(root) else { throw AIFailure.parse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Not supported

    func speech(key: String, text: String, voice: String, reference: (audio: String, text: String)?,
                language: String?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIFailure.unsupported) }
    }

    func interpret(key: String, wav: Data, content: String, instruction: String,
                   timeout: TimeInterval) async throws -> String {
        throw AIFailure.unsupported
    }
}
