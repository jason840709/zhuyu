import Foundation
import Observation

enum ModelSlot: String, Identifiable, CaseIterable, Sendable {
    case openAISpeech, geminiSpeech, openAITranslation, geminiTranslation, claudeTranslation
    var id: String { rawValue }
    var provider: Provider {
        switch self {
        case .openAISpeech, .openAITranslation: .openAI
        case .geminiSpeech, .geminiTranslation: .gemini
        case .claudeTranslation: .claude
        }
    }
    var isSpeech: Bool { self == .openAISpeech || self == .geminiSpeech }
    var title: String { "\(provider.title) \(isSpeech ? "即時辨識" : "文字翻譯")" }
    static func speech(_ provider: Provider) -> Self { provider == .gemini ? .geminiSpeech : .openAISpeech }
    static func translation(_ provider: Provider) -> Self {
        switch provider { case .openAI: .openAITranslation; case .gemini: .geminiTranslation; case .claude: .claudeTranslation }
    }
}

extension AppSettings {
    func model(for slot: ModelSlot) -> String {
        switch slot {
        case .openAISpeech: openAIASRModel
        case .geminiSpeech: geminiASRModel
        case .openAITranslation: openAITranslationModel
        case .geminiTranslation: geminiTranslationModel
        case .claudeTranslation: claudeTranslationModel
        }
    }
    mutating func setModel(_ value: String, for slot: ModelSlot) {
        switch slot {
        case .openAISpeech: openAIASRModel = value
        case .geminiSpeech: geminiASRModel = value
        case .openAITranslation: openAITranslationModel = value
        case .geminiTranslation: geminiTranslationModel = value
        case .claudeTranslation: claudeTranslationModel = value
        }
    }
}

struct CloudModel: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var methods: [String] = []

    // The models API returns IDs, not an endpoint-capability or quota test.
    // Limit selection to the families handled by the public API adapters.
    func supports(_ slot: ModelSlot) -> Bool {
        let name = id.lowercased()
        if slot.isSpeech {
            return slot.provider == .openAI
                ? ["gpt-live-transcribe", "gpt-realtime-whisper", "gpt-transcribe"].contains(name)
                : name == "gemini-3.5-transcribe-live"
        }
        let specialized = ["audio", "transcrib", "embedding", "image", "tts", "realtime", "live", "search", "cyber", "deep-research", "moderation"]
        switch slot.provider {
        case .openAI:
            let base = name.hasPrefix("ft:") ? String(name.split(separator: ":").dropFirst().first ?? "") : name
            guard !(specialized + ["chat", "codex", "computer-use"]).contains(where: { base.contains($0) }) else { return false }
            // GPT-5/6 text families use Responses. Legacy GPT-3.5/GPT-4 and
            // ChatGPT-only aliases must not enter a Responses-only selector.
            if base.range(of: #"^gpt-[56](?:\.\d+)?(?:-|$)"#, options: .regularExpression) != nil { return true }
            // o1-pro and o4-mini are marked shut down in the model reference.
            let responsesAliases = ["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini", "o1", "o3", "o3-mini", "o3-pro"]
            return responsesAliases.contains { alias in
                base == alias || (base.hasPrefix(alias + "-") && String(base.dropFirst(alias.count + 1))
                    .range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
            }
        case .gemini:
            return name.hasPrefix("gemini-") && methods.contains("generateContent")
                && !(specialized + ["robotics", "computer-use"]).contains { name.contains($0) }
        case .claude:
            return name.hasPrefix("claude-") && !specialized.contains { name.contains($0) }
        }
    }
}

struct ModelCatalogClient: Sendable {
    private let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = session ?? APIEndpointPolicy.session(configuration: config)
    }

    func fetch(provider: Provider, key: String) async throws -> [CloudModel] {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ProviderFailure.message("請先輸入 \(provider.title) API 金鑰。") }
        var result: [CloudModel] = []
        var ids = Set<String>()
        var cursor: String?
        var cursors = Set<String>()
        let end = ContinuousClock.now.advanced(by: .seconds(45))
        for _ in 0..<24 {
            try Task.checkCancellation()
            guard ContinuousClock.now < end else { throw ProviderFailure.message("取得模型清單逾時，請重試。") }
            let request = Self.request(provider: provider, key: clean, cursor: cursor)
            try APIEndpointPolicy.validate(request.url, provider: provider)
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ProviderFailure.message("無法連上 \(provider.title)，請確認網路後重試。") }
            guard let http = response as? HTTPURLResponse else { throw ProviderFailure.message("模型服務沒有傳回 HTTP 回應。") }
            try APIEndpointPolicy.validate(http.url, provider: provider)
            guard (200..<300).contains(http.statusCode) else {
                throw ProviderFailure.message(TranslationClient.httpError(http.statusCode, provider: provider))
            }
            let page = try Self.parse(data, provider: provider)
            for model in page.models where ids.insert(model.id).inserted { result.append(model) }
            guard let next = page.next else {
                return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            }
            guard cursors.insert(next).inserted else { throw ProviderFailure.message("模型服務回傳重複分頁，請稍後重試。") }
            cursor = next
        }
        throw ProviderFailure.message("模型清單超過可處理的頁數，請稍後重試。")
    }

    static func request(provider: Provider, key: String, cursor: String?) -> URLRequest {
        let endpoint: String
        switch provider {
        case .openAI: endpoint = "https://api.openai.com/v1/models"
        case .gemini: endpoint = "https://generativelanguage.googleapis.com/v1beta/models"
        case .claude: endpoint = "https://api.anthropic.com/v1/models"
        }
        var parts = URLComponents(string: endpoint)!
        if provider == .gemini {
            parts.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if let cursor { parts.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor)) }
        } else if provider == .claude {
            parts.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let cursor { parts.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
        }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch provider {
        case .openAI: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .claude:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    static func parse(_ data: Data, provider: Provider) throws -> (models: [CloudModel], next: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object[provider == .gemini ? "models" : "data"] as? [[String: Any]] else {
            throw ProviderFailure.message("模型服務傳回無法讀取的清單。")
        }
        let models: [CloudModel] = rows.compactMap { row in
            guard var id = row[provider == .gemini ? "name" : "id"] as? String else { return nil }
            if provider == .gemini, id.hasPrefix("models/") { id.removeFirst(7) }
            guard !id.isEmpty, id.count <= 256, !id.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
            let displayName = row[provider == .gemini ? "displayName" : "display_name"] as? String ?? id
            return CloudModel(id: id, displayName: displayName, methods: row["supportedGenerationMethods"] as? [String] ?? [])
        }
        let next: String?
        if provider == .gemini { next = object["nextPageToken"] as? String }
        else if provider == .claude, object["has_more"] as? Bool == true {
            guard let id = object["last_id"] as? String, !id.isEmpty else {
                throw ProviderFailure.message("模型清單缺少分頁位置，請重試。")
            }
            next = id
        } else { next = nil }
        return (models, next?.isEmpty == false ? next : nil)
    }
}

enum ModelConnectionState: Equatable {
    case idle, loading, connected(Int), failed(String), preview
    var message: String {
        switch self {
        case .idle: "尚未測試連線"
        case .loading: "正在驗證金鑰並取得模型…"
        case .connected: "已連線"
        case .failed(let message): message
        case .preview: "介面驗收 · 合成模型清單"
        }
    }
    var isLoading: Bool { self == .loading }
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

@MainActor @Observable
final class ModelDirectory {
    private(set) var models: [Provider: [CloudModel]] = [:]
    private(set) var states: [Provider: ModelConnectionState] = [:]
    @ObservationIgnored private let client: ModelCatalogClient
    @ObservationIgnored private var tasks: [Provider: Task<Void, Never>] = [:]
    @ObservationIgnored private var requests: [Provider: UUID] = [:]

    init(client: ModelCatalogClient = ModelCatalogClient()) { self.client = client }
    #if UI_ACCEPTANCE
    func installPreview() {
        for provider in Provider.allCases {
            let slots = ModelSlot.allCases.filter { $0.provider == provider }
            models[provider] = slots.flatMap { ModelRates.choices($0) }.map {
                CloudModel(id: $0.id, displayName: $0.id, methods: provider == .gemini ? ["generateContent"] : [])
            }
            states[provider] = .preview
        }
    }
    #endif
    func state(_ provider: Provider) -> ModelConnectionState { states[provider] ?? .idle }

    func invalidate(_ provider: Provider) {
        tasks[provider]?.cancel()
        tasks[provider] = nil
        requests[provider] = nil
        states[provider] = .idle
        models[provider] = nil
    }

    func fetch(provider: Provider, key: String) {
        invalidate(provider)
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            states[provider] = .failed("請先輸入 \(provider.title) API 金鑰。")
            return
        }
        let id = UUID()
        requests[provider] = id
        states[provider] = .loading
        tasks[provider] = Task { [weak self, client] in
            do {
                let list = try await client.fetch(provider: provider, key: key)
                guard let self, requests[provider] == id, !Task.isCancelled else { return }
                models[provider] = list
                states[provider] = .connected(list.count)
                tasks[provider] = nil
            } catch {
                guard let self, requests[provider] == id, !Task.isCancelled else { return }
                states[provider] = .failed(error.localizedDescription)
                tasks[provider] = nil
            }
        }
    }
}
