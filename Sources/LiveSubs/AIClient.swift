import Foundation
import Security

// MARK: - API key (local file)

/// The user's key for an AI service, in a file only this user can read (0600, folder 0700) under
/// Application Support, left out of backups. Never written to UserDefaults, logs or exports.
/// One file per service, so switching services does not lose the other one's key.
///
/// Not the Keychain for now: the app is signed ad hoc, so the Keychain only trusts one exact build
/// (its cdhash) and asks for the login password after every rebuild or update. Back to the Keychain
/// once builds are signed with a Developer ID (a stable team id). Keys saved there by earlier
/// builds are moved over once.
@MainActor
enum AIKey {
    private static var cached: [AIService: String?] = [:]

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevBuild.supportFolder)
    }
    /// One file per service: "ling-api-key", "minimax-api-key", "custom-api-key".
    static func file(for service: AIService) -> URL {
        folder.appendingPathComponent("\(service.rawValue)-api-key")
    }

    static func read(for service: AIService) -> String? {
        if let cached = cached[service] { return cached }
        var value = (try? String(contentsOf: file(for: service), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value?.isEmpty ?? true { value = nil }
        if value == nil, service == .ling, let old = LegacyKeychain.take() {
            // One last Keychain prompt, then the key lives in the file.
            value = old
            write(old, for: service)
        }
        cached[service] = .some(value)
        return value
    }

    @discardableResult
    static func save(_ key: String, for service: AIService) -> Bool {
        let ok = write(key, for: service)
        cached[service] = .some(ok ? key : nil)
        return ok
    }

    static func remove(for service: AIService) {
        try? FileManager.default.removeItem(at: file(for: service))
        if service == .ling { LegacyKeychain.delete() }
        cached[service] = .some(nil)
    }

    @discardableResult
    private static func write(_ key: String, for service: AIService) -> Bool {
        let fm = FileManager.default
        let file = file(for: service)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            // Create it 0600 before the key goes in, so it is never readable by others.
            if !fm.fileExists(atPath: file.path) {
                guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    debugLog("ai key: could not create the key file")
                    return false
                }
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try Data(key.utf8).write(to: file)
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch {
            debugLog("ai key: save failed \(error.localizedDescription)")
            return false
        }
    }

    /// Where builds before the file kept the key: login Keychain, service = bundle id + ".ai".
    private enum LegacyKeychain {
        private static var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.wquguru.cicada.swiftrun") + ".ai",
             kSecAttrAccount as String: "ling"]
        }

        /// The old key, removed from the Keychain once read.
        static func take() -> String? {
            // Skip the Keychain entirely when there was never an item (no prompt for new users).
            var exists = query
            exists[kSecReturnAttributes as String] = true
            guard SecItemCopyMatching(exists as CFDictionary, nil) == errSecSuccess else { return nil }
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let key = (out as? Data).flatMap({ String(data: $0, encoding: .utf8) }), !key.isEmpty else { return nil }
            delete()
            debugLog("ai key: moved from the Keychain to the key file")
            return key
        }

        static func delete() { SecItemDelete(query as CFDictionary) }
    }

    /// "sk-…3f9a" for display: the first three and last four characters, the rest hidden.
    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return "••••" }
        return String(key.prefix(3)) + String(repeating: "•", count: 12) + String(key.suffix(4))
    }
}

// MARK: - AI client

/// The one place the app talks to an AI service. It owns the parts that are the same for every
/// service: where the key lives, how it is checked, the start gate, the priorities and the
/// diagnostics. Which service is behind it is a setting, and each service's own quirks live in its
/// provider.
@MainActor
final class AIClient: ObservableObject {
    enum Priority: Int, Comparable {
        case speak = 0, translate = 1, notes = 2
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    enum KeyState: Equatable {
        case none
        case unchecked
        case checking
        case ok(seconds: Double)
        case invalid
        case unreachable(String)
        /// The plan's allowance is used up: the window has to refill before it works again.
        case quota
        /// The key or the model is not in the plan the user pays for.
        case plan
        /// The platform has retired the model.
        case retired
    }

    /// The service in use, and the model to use with it. The app sets them from the settings.
    var service: () -> AIService = { .ling }
    var model: () -> String = { "Ling-3.1-flash" }

    /// One provider per service.
    private(set) var providers: [AIService: AIProvider] = [:]

    /// How each service's key checked out, so switching back and forth keeps the answer.
    @Published private(set) var states: [AIService: KeyState] = [:]

    /// Debug control only: make every chat call fail this way.
    var simulate: AIFailure?

    /// Debug control only: act as if there were no key, without touching the key file.
    var hideKey = false

    /// Every request, for diagnostics (timings and token counts only).
    var onCall: ((AICall) -> Void)?

    // MARK: The current service

    var current: AIService { service() }
    func provider(for service: AIService) -> AIProvider? { providers[service] }
    var currentProvider: AIProvider? { provider(for: current) }

    var keyState: KeyState { states[current] ?? .none }
    var key: String? { hideKey ? nil : AIKey.read(for: current) }
    var hasKey: Bool { key != nil }
    /// The key is known to work (or at least not known to be bad).
    var usable: Bool { hasKey && keyState != .invalid }

    init() {
        providers = [
            .ling: LingProvider(),
            .minimax: MiniMaxProvider(),
            .custom: CustomProvider(),
        ]
        for service in AIService.allCases where AIKey.read(for: service) != nil {
            states[service] = .unchecked
        }
    }

    // MARK: Key

    /// Saves the key and checks it with the cheapest possible request.
    func setKey(_ raw: String) async {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        if hideKey { debugLog("ai key: not saved while hidden (debug)"); states[current] = .invalid; return }
        AIKey.save(k, for: current)
        await check()
    }

    func removeKey() {
        AIKey.remove(for: current)
        states[current] = KeyState.none
    }

    func check() async {
        let service = current
        guard let key = AIKey.read(for: service), let provider = provider(for: service) else {
            states[service] = KeyState.none
            return
        }
        states[service] = .checking
        let started = Date()
        var why = ""
        do {
            if let simulate { throw simulate }
            _ = try await provider.checkKey(key, model: model())
            states[service] = .ok(seconds: Date().timeIntervalSince(started))
        } catch let failure as AIFailure {
            // Every reason is told apart: a retired model or a wrong key must not look like a
            // broken network, or the user is left guessing what to change.
            switch failure {
            case .invalidKey: states[service] = .invalid
            case .rateLimited: states[service] = .ok(seconds: Date().timeIntervalSince(started))
            case .quota: states[service] = .quota
            case .plan: states[service] = .plan
            case .retired: states[service] = .retired
            case .timeout: states[service] = .unreachable(L("超时"))
            case .http(let code): states[service] = .unreachable(L("\(provider.displayName) 返回 HTTP \(code)"))
            case .parse: states[service] = .unreachable(L("服务回了看不懂的内容"))
            default: states[service] = .unreachable(L("连不上 \(provider.displayName)，检查网络或代理"))
            }
            why = " (\(AIFailure.name(failure)))"
        } catch {
            states[service] = .unreachable(L("连不上 \(provider.displayName)，检查网络或代理"))
            why = " (\(error))"
        }
        debugLog("ai: \(service.rawValue) key check → \(states[service] ?? .none)\(why)")
    }

    // MARK: Chat

    /// One chat completion. `content` goes in the system message, `instruction` is the fixed user
    /// message. Notes retry 429s with backoff; translation and speak-back fail fast so the caller
    /// can fall back to another translator.
    func chat(content: String, instruction: String, priority: Priority, json: Bool = false,
              maxTokens: Int = 1024, timeout: TimeInterval = 30, model: String? = nil,
              onQueued: ((Double) -> Void)? = nil) async throws -> String {
        let service = current
        guard let key else { throw AIFailure.noKey }
        guard keyState != .invalid else { throw AIFailure.invalidKey }
        guard let provider = provider(for: service) else { throw AIFailure.unsupported }
        if let simulate {
            if simulate == .rateLimited { rateLimitedAt = Date() }
            throw simulate
        }
        let attempts = priority == .notes ? 4 : 1
        var delay = 1.0
        for attempt in 1...attempts {
            let asked = Date()
            await acquire(priority, spacing: provider.startSpacing)
            let queued = Date().timeIntervalSince(asked)
            onQueued?(queued)
            let started = Date()
            do {
                let reply = try await provider.chat(key: key, content: content, instruction: instruction,
                                                    model: model ?? self.model(), json: json,
                                                    maxTokens: maxTokens, timeout: timeout)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                debugLog("ai: \(service.rawValue) \(priority) ok \(ms) ms")
                report(priority, at: started, queued: queued, outcome: "ok")
                if rateLimitedAt != nil { rateLimitedAt = nil }
                return reply
            } catch let failure as AIFailure {
                if failure == .invalidKey { states[service] = .invalid }
                // The plan's allowance and what it covers are the service's state too, not just the
                // key's: the settings page says so instead of "can't reach it".
                if failure == .quota { states[service] = .quota }
                if failure == .plan { states[service] = .plan }
                if failure == .retired { states[service] = .retired }
                report(priority, at: started, queued: queued, outcome: AIFailure.name(failure))
                guard failure == .rateLimited else { throw failure }
                guard attempt < attempts else {
                    rateLimitedAt = Date()
                    throw failure
                }
                let wait = delay + Double.random(in: 0...0.5)
                debugLog("ai: \(service.rawValue) \(priority) 429, retry in \(String(format: "%.1f", wait)) s")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                delay *= 2
            }
        }
        throw AIFailure.rateLimited
    }

    /// The spoken form of `text`, as raw PCM. `reference` is the user's own voice, for the services
    /// that can clone it.
    func speech(_ text: String, voice: String, reference: (audio: String, text: String)? = nil,
                language: String? = nil) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task { @MainActor [weak self] in
                guard let self, let key = self.key, let provider = self.currentProvider else {
                    cont.finish(throwing: AIFailure.noKey)
                    return
                }
                await self.acquire(.speak, spacing: provider.startSpacing)
                let stream = provider.speech(key: key, text: text, voice: voice, reference: reference, language: language)
                for try await chunk in stream { cont.yield(chunk) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// The service's audio model: a recording in, the original and its translation out. Only the
    /// services with an audio model answer this.
    func interpret(wav: Data, content: String, instruction: String, timeout: TimeInterval = 12) async throws -> String {
        let service = current
        guard let key else { throw AIFailure.noKey }
        guard keyState != .invalid else { throw AIFailure.invalidKey }
        guard let provider = provider(for: service) else { throw AIFailure.unsupported }
        if let simulate { throw simulate }
        await acquire(.speak, spacing: provider.startSpacing)
        return try await provider.interpret(key: key, wav: wav, content: content, instruction: instruction, timeout: timeout)
    }

    // MARK: Diagnostics

    @Published private(set) var rateLimitedAt: Date?

    private func report(_ priority: Priority, at started: Date, queued: Double, outcome: String, tokens: (Int, Int) = (0, 0)) {
        onCall?(AICall(at: started, priority: "\(priority)", queue: queued, seconds: Date().timeIntervalSince(started),
                       outcome: outcome, promptTokens: tokens.0, completionTokens: tokens.1))
    }

    // MARK: Start gate

    /// Requests start no closer together than `spacing`, in priority order: speak-back, translation,
    /// notes. One gate per service, so each one's own limit applies.
    private struct Gate {
        var lastStart = Date.distantPast
        var waiting: [(priority: Priority, seq: Int, resume: CheckedContinuation<Void, Never>)] = []
        var seq = 0
        var pumping = false
    }
    private var gates: [AIService: Gate] = [:]

    private func acquire(_ priority: Priority, spacing: TimeInterval) async {
        let service = current
        var gate = gates[service] ?? Gate()
        if gate.waiting.isEmpty && Date().timeIntervalSince(gate.lastStart) >= spacing {
            gate.lastStart = Date()
            gates[service] = gate
            return
        }
        gate.seq += 1
        let n = gate.seq
        gates[service] = gate
        await withCheckedContinuation { cont in
            gate.waiting.append((priority, n, cont))
            gates[service] = gate
            pump(service)
        }
    }

    private func pump(_ service: AIService) {
        guard var gate = gates[service], !gate.pumping, !gate.waiting.isEmpty else { return }
        gate.pumping = true
        let spacing = provider(for: service)?.startSpacing ?? 0.6
        let wait = max(0, spacing - Date().timeIntervalSince(gate.lastStart))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, var gate = self.gates[service] else { return }
                gate.pumping = false
                guard let i = gate.waiting.indices.min(by: {
                    (gate.waiting[$0].priority, gate.waiting[$0].seq) < (gate.waiting[$1].priority, gate.waiting[$1].seq)
                }) else {
                    self.gates[service] = gate
                    return
                }
                let next = gate.waiting.remove(at: i)
                gate.lastStart = Date()
                self.gates[service] = gate
                next.resume.resume()
                self.pump(service)
            }
        }
    }
}
