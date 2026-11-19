import Foundation
import Translation

// MARK: - Draft translation (the gray text shown while someone is still speaking)
//
// The draft is a convenience: every finished sentence is still translated by the
// cloud service you chose. A draft engine only has to be fast and run on this Mac.
//
// Built-in engines:
//   • localModel        – any OpenAI-compatible server on this Mac (Ollama, LM Studio,
//                         llama.cpp server, mlx-lm …). Default model: translategemma:4b.
//   • appleTranslation  – Apple's on-device Translation framework (macOS 26+).
//   • off               – no draft; the cloud translation appears when a sentence ends.
//
// To add your own engine, write a type that conforms to `DraftTranslationEngine`
// and return it from `DraftEngineConfig.makeEngine()`. See docs/替換本機暫譯引擎.md.

/// One engine translates short spoken fragments between language codes such as
/// "en", "zh-TW" and "ja".
protocol DraftTranslationEngine: Sendable {
    /// Called once when listening starts. Throw a readable error if the engine
    /// is not ready (server not running, model or language pack missing).
    func prepare(from source: String, to target: String) async throws
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}

enum DraftEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case localModel, appleTranslation, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .localModel: "本機模型"
        case .appleTranslation: "Apple 系統翻譯"
        case .off: "不使用"
        }
    }
}

struct DraftEngineConfig: Equatable, Sendable {
    static let defaultEndpoint = "http://127.0.0.1:11434/v1"
    static let defaultModel = "translategemma:4b"

    var kind: DraftEngineKind = .localModel
    var endpoint: String = defaultEndpoint
    var model: String = defaultModel

    func makeEngine() -> (any DraftTranslationEngine)? {
        switch kind {
        case .localModel: LocalModelDraftEngine(endpoint: endpoint, model: model)
        case .appleTranslation: AppleDraftEngine()
        case .off: nil
        }
    }
}

@MainActor
final class LocalDraftTranslator {
    private var config: DraftEngineConfig
    private var engine: (any DraftTranslationEngine)?
    private var generation: UInt = 0
    /// False after a failed preflight: drafts are skipped quietly for this
    /// session instead of failing on every sentence.
    private var available = true

    init(config: DraftEngineConfig = DraftEngineConfig()) {
        self.config = config
        self.engine = config.makeEngine()
    }

    func configure(_ newConfig: DraftEngineConfig) {
        guard newConfig != config else { return }
        config = newConfig
        engine = newConfig.makeEngine()
        available = true
        generation &+= 1
    }

    func preflight(sourceLanguage: String = "auto", targetLanguage: String = "zh-TW") async throws {
        guard let engine else {
            available = false
            throw LocalDraftTranslationFailure.disabled
        }
        let from = TranscriptLanguage.code(sourceLanguage)
        let to = TranscriptLanguage.code(targetLanguage)
        do {
            // "auto" has no fixed source; checking reachability with English is enough.
            try await engine.prepare(from: from == "auto" ? "en" : from, to: to)
            available = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            available = false
            throw error
        }
        try Task.checkCancellation()
    }

    func translate(source: String, sourceLanguage: String = "auto", targetLanguage: String? = nil) async throws -> TranslationResult {
        try Task.checkCancellation()
        // Off or not ready: skip quietly; the cloud translation still arrives.
        guard let engine, available else { throw CancellationError() }
        let from = TranscriptLanguage.identify(source, hint: sourceLanguage)
        let to = targetLanguage.map(TranscriptLanguage.code) ?? (from == "zh-TW" ? "en" : "zh-TW")
        guard ["en", "zh-TW", "ja"].contains(from), ["en", "zh-TW", "ja"].contains(to) else {
            throw LocalDraftTranslationFailure.unsupportedLanguage
        }
        let normalizedSource = TranscriptLanguage.display(source, language: from)
        let text = normalizedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalDraftTranslationFailure.emptySource }
        if from == to {
            return .make(source: normalizedSource, sourceLanguage: from, target: normalizedSource, targetLanguage: to)
        }
        let started = generation
        let translated = try await engine.translate(text, from: from, to: to)
        try Task.checkCancellation()
        // A reset or engine change while waiting makes this draft stale.
        guard started == generation else { throw CancellationError() }
        guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalDraftTranslationFailure.emptyTranslation
        }
        // Character conversion alone keeps mainland vocabulary (本科生); use Taiwan wording.
        let target = to == "zh-TW" ? TaiwanVocabulary.apply(ChineseScript.traditional(translated)) : translated
        return .make(source: normalizedSource, sourceLanguage: from, target: target, targetLanguage: to)
    }

    func reset() {
        generation &+= 1
    }
}

enum DraftLanguage {
    static func englishName(_ code: String) -> String {
        switch code {
        case "zh-TW": "Traditional Chinese (Taiwan)"
        case "ja": "Japanese"
        default: "English"
        }
    }

    static func appleLanguage(_ code: String) -> Locale.Language {
        switch code {
        case "zh-TW": Locale.Language(identifier: "zh-Hant")
        case "ja": Locale.Language(identifier: "ja")
        default: Locale.Language(identifier: "en")
        }
    }
}

// MARK: - Local model through an OpenAI-compatible server on this Mac

struct LocalModelDraftEngine: DraftTranslationEngine {
    let endpoint: String
    let model: String

    /// The prompt follows the TranslateGemma model card; general chat models
    /// (Gemma, Qwen, Llama …) understand it as well. Change it here if a model
    /// you prefer needs a different instruction.
    static func prompt(_ text: String, from source: String, to target: String) -> String {
        let s = DraftLanguage.englishName(source), t = DraftLanguage.englishName(target)
        return """
        You are a professional \(s) (\(source)) to \(t) (\(target)) translator. Your goal is to accurately \
        convey the meaning and nuances of the original \(s) text while adhering to \(t) grammar, vocabulary, \
        and cultural sensitivities. Produce only the \(t) translation, without any additional explanations \
        or commentary. Please translate the following \(s) text into \(t):


        \(text)
        """
    }

    /// Only servers on this Mac are allowed, so spoken text never leaves the
    /// computer through the draft path.
    private func baseURL() throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else {
            throw LocalDraftTranslationFailure.notLoopback
        }
        return url
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return APIEndpointPolicy.session(configuration: configuration)
    }()

    func prepare(from source: String, to target: String) async throws {
        let url = try baseURL().appendingPathComponent("models")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(from: url)
        } catch {
            throw LocalDraftTranslationFailure.serverUnreachable(endpoint)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw LocalDraftTranslationFailure.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Models: Decodable { struct Item: Decodable { let id: String }; let data: [Item] }
        if let list = try? JSONDecoder().decode(Models.self, from: data),
           !list.data.contains(where: { $0.id == model || $0.id == model + ":latest" }) {
            throw LocalDraftTranslationFailure.modelMissing(model)
        }
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        var request = URLRequest(url: try baseURL().appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": Self.prompt(text, from: source, to: target)]],
            "temperature": 0,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch is URLError {
            throw LocalDraftTranslationFailure.serverUnreachable(endpoint)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LocalDraftTranslationFailure.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        let content = try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content ?? ""
        return Self.clean(content)
    }

    /// Some reasoning models wrap their thoughts in <think>…</think>; keep only the answer.
    static func clean(_ content: String) -> String {
        var text = content
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Apple's on-device Translation framework

struct AppleDraftEngine: DraftTranslationEngine {
    /// Sessions are reused per language pair; the lock only guards the dictionary.
    private final class Sessions: @unchecked Sendable {
        let lock = NSLock()
        var byPair: [String: TranslationSession] = [:]
    }
    private let sessions = Sessions()

    private func session(from source: String, to target: String) async throws -> TranslationSession {
        let key = source + ">" + target
        if let existing = sessions.lock.withLock({ sessions.byPair[key] }) { return existing }
        let from = DraftLanguage.appleLanguage(source), to = DraftLanguage.appleLanguage(target)
        let status = await LanguageAvailability().status(from: from, to: to)
        guard status == .installed else { throw LocalDraftTranslationFailure.applePackMissing }
        let created = TranslationSession(installedSource: from, target: to)
        sessions.lock.withLock { sessions.byPair[key] = created }
        return created
    }

    func prepare(from source: String, to target: String) async throws {
        _ = try await session(from: source, to: target)
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let session = try await session(from: source, to: target)
        return try await session.translate(text).targetText
    }
}

private enum LocalDraftTranslationFailure: LocalizedError {
    case disabled, unsupportedLanguage, emptySource, emptyTranslation
    case notLoopback, serverUnreachable(String), modelMissing(String), serverError(Int), applePackMissing

    var errorDescription: String? {
        switch self {
        case .disabled: "本機暫譯已關閉"
        case .unsupportedLanguage: "本機暫譯目前只處理英文、中文與日文"
        case .emptySource: "沒有可暫譯的文字"
        case .emptyTranslation: "本機模型沒有回傳譯文"
        case .notLoopback: "本機模型位址只能是這台 Mac（127.0.0.1 或 localhost）"
        case .serverUnreachable(let endpoint): "連不到本機模型伺服器 \(endpoint)；請先開啟 Ollama 或 LM Studio"
        case .modelMissing(let model): "本機伺服器沒有模型 \(model)；Ollama 可執行 ollama pull \(model)"
        case .serverError(let code): "本機模型伺服器回應錯誤（HTTP \(code)）"
        case .applePackMissing: "尚未下載這組語言的 Apple 翻譯語言包；請到「系統設定 › 一般 › 語言與地區 › 翻譯語言」下載"
        }
    }
}
