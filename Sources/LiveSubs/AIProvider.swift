import Foundation

// MARK: - Services

/// The AI services the app can talk to. Each one brings its own key, base URL, models and voices;
/// nothing outside a provider knows which service it is talking to.
enum AIService: String, CaseIterable, Codable, Identifiable {
    case ling, minimax, custom

    var id: String { rawValue }

    /// The name as the service writes it. "自定义" is ours, so it is translated.
    var displayName: String {
        switch self {
        case .ling: "Ling"
        case .minimax: "MiniMax"
        case .custom: L("自定义")
        }
    }
}

/// Why a call to an AI service failed.
enum AIFailure: Error, Equatable {
    case noKey, invalidKey, rateLimited
    /// The plan's allowance is used up: the window has to refill before it works again.
    case quota
    /// The key or the model is not in the plan the user pays for.
    case plan
    /// The platform has retired the model: it answers, but says the model is gone.
    case retired
    case hijacked, timeout, http(Int), network, parse, unsupported

    /// A short name for the diagnostics log.
    static func name(_ failure: AIFailure) -> String {
        switch failure {
        case .http(let code): "http\(code)"
        default: "\(failure)"
        }
    }
}

/// What the app needs from an AI service. Everything service-specific lives behind this: where
/// the key goes, which models exist, how a request is shaped, what its voices sound like.
protocol AIProvider: AnyObject {
    var service: AIService { get }
    /// The product's name, as it writes it.
    var displayName: String { get }
    /// The models the user can pick between.
    var models: [String] { get }
    /// The model to use until the user picks one.
    var defaultModel: String { get }
    /// Where to get a key.
    var keyURL: URL? { get }
    /// One line on how to get a key, in the UI language.
    var keyHint: String { get }
    /// What the key looks like, for the input field's placeholder.
    var keyPlaceholder: String { get }
    /// Whether the service can speak (text to speech).
    var canSpeak: Bool { get }
    /// Whether the service can clone a voice from a recording.
    var canClone: Bool { get }
    /// Whether the service has an audio model: it hears a recording and answers with the original
    /// and its translation in one go.
    var canInterpret: Bool { get }
    /// How the service's voices are marked in the picker.
    var voiceTag: String { get }
    /// How far apart two requests may start. Ling's account allows about two a second.
    var startSpacing: TimeInterval { get }

    /// Checks the key with the cheapest possible request; returns how long it took. The model is
    /// the one the app will use, so a model the platform has retired is caught here and not in
    /// the middle of a meeting.
    func checkKey(_ key: String, model: String) async throws -> TimeInterval
    /// One chat completion. `content` goes in the system message, `instruction` in the user message.
    func chat(key: String, content: String, instruction: String, model: String, json: Bool,
              maxTokens: Int, timeout: TimeInterval) async throws -> String
    /// The spoken form of `text`, as raw 24 kHz mono 16-bit PCM. `reference` is the user's own
    /// voice, for the services that can clone it.
    func speech(key: String, text: String, voice: String, reference: (audio: String, text: String)?,
                language: String?) -> AsyncThrowingStream<Data, Error>
    /// The service's audio model: a recording in, the original and its translation out. Only
    /// services with an audio model have one.
    func interpret(key: String, wav: Data, content: String, instruction: String,
                   timeout: TimeInterval) async throws -> String
}

// MARK: - Transport

/// One JSON POST with a bearer token, shared by the services that speak the same dialect.
enum AIHTTP {
    static func post(_ url: URL, body: [String: Any], key: String, timeout: TimeInterval) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw AIFailure.timeout
        } catch {
            throw AIFailure.network
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401, 403: throw AIFailure.invalidKey
        case 429: throw AIFailure.rateLimited
        case let code: throw AIFailure.http(Self.platformCode(data, http: code))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIFailure.parse }
        return root
    }

    /// Some services put their own code in the error body ("... (2013)"), and that code says more
    /// than the HTTP status does, so it is the one the caller acts on.
    private static func platformCode(_ data: Data, http: Int) -> Int {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "error",
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String,
              let open = message.lastIndex(of: "("),
              let close = message.lastIndex(of: ")"),
              close > open,
              let code = Int(message[message.index(after: open)..<close]) else { return http }
        return code
    }

    /// The text of the first choice, the shape every OpenAI-compatible service answers in.
    static func firstChoice(_ root: [String: Any]) -> String? {
        guard let choice = (root["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }
        return text
    }

    /// The prompt and completion tokens of a reply, for the diagnostics log.
    static func tokens(_ root: [String: Any]) -> (Int, Int) {
        let usage = root["usage"] as? [String: Any]
        return (usage?["prompt_tokens"] as? Int ?? 0, usage?["completion_tokens"] as? Int ?? 0)
    }
}
