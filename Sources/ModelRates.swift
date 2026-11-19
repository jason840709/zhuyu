import Foundation

struct ModelRate: Sendable {
    let id: String
    let label: String
    let price: String
    let detail: String?
}

enum ModelRates {
    // Standard paid-tier prices, checked against each provider's reference page.
    // Keep prices on exact IDs: a snapshot or a new cloud ID must not inherit a guessed rate.
    static let checkedOn = "2026-11-17"
    static func reference(_ provider: Provider) -> URL {
        let address = switch provider {
        case .openAI: "https://developers.openai.com/api/docs/pricing"
        case .gemini: "https://aistudio.google.com/docs/pricing"
        case .claude: "https://platform.claude.com/docs/en/about-claude/pricing"
        }
        return URL(string: address)!
    }
    static func choices(_ slot: ModelSlot, now: Date = Date()) -> [ModelRate] {
        switch slot {
        case .openAISpeech:
            return [ModelRate(id: "gpt-live-transcribe", label: "說話中回字", price: "US$0.017／分鐘", detail: "辨識約 US$1.02／小時；另計文字翻譯"),
                    ModelRate(id: "gpt-realtime-whisper", label: "說話中回字", price: "US$0.017／分鐘", detail: "辨識約 US$1.02／小時；另計文字翻譯"),
                    ModelRate(id: "gpt-transcribe", label: "停頓後回字", price: "US$0.0045／分鐘", detail: "辨識約 US$0.27／小時；另計文字翻譯")]
        case .geminiSpeech:
            return [ModelRate(id: "gemini-3.5-transcribe-live", label: "即時辨識", price: "約 US$0.009／分鐘", detail: "官方估算；每百萬音訊輸入 tokens US$3.50、文字輸出 tokens US$21。另計翻譯。")]
        case .openAITranslation:
            let detail = "短上下文標準費率；長上下文另計"
            return [text("gpt-6-luna", "低成本", "0.10", "0.50", detail: detail),
                    text("gpt-6.1-terra", "快速", "1", "5", detail: detail),
                    text("gpt-6.1-sol", "通用", "2", "10", detail: detail),
                    text("gpt-6-astra", "較高階", "10", "50", detail: detail)]
        case .geminiTranslation:
            // The published price changes specify calendar dates; apply them at UTC midnight.
            let flashPromotion = now < Date(timeIntervalSince1970: 1_798_761_600) // 2027-01-01 00:00 UTC
            let frontierPromotion = now < Date(timeIntervalSince1970: 1_796_083_200) // 2026-12-01 00:00 UTC
            let flashDetail = flashPromotion
                ? "優惠至 2026-12-31；之後輸入 US$1.50、輸出 US$7.50／百萬文字 tokens；輸出含思考 tokens"
                : "輸出含思考 tokens"
            let frontierDetail = frontierPromotion
                ? "優惠至 2026-11-30；之後輸入 US$4、輸出 US$20／百萬文字 tokens；輸出含思考 tokens"
                : "輸出含思考 tokens"
            return [text("gemini-3.5-flash-lite", "低成本", "0.30", "2.50"),
                    text("gemini-3.8-flash", "通用", flashPromotion ? "0.75" : "1.50", flashPromotion ? "3.75" : "7.50", detail: flashDetail),
                    text("gemini-4-argon", "快速推理", frontierPromotion ? "2" : "4", frontierPromotion ? "10" : "20", detail: frontierDetail),
                    text("gemini-4-carbon", "較高階", frontierPromotion ? "2" : "4", frontierPromotion ? "10" : "20", detail: frontierDetail)]
        case .claudeTranslation:
            return [text("claude-haiku-5-5", "低成本", "0.10", "0.50", detail: "輸入不超過十萬 tokens；超過時輸入 US$0.50、輸出 US$2.50／百萬文字 tokens"),
                    text("claude-sonnet-5-5", "較高階", "2", "10")]
        }
    }
    static func rate(_ id: String, slot: ModelSlot, now: Date = Date()) -> ModelRate? {
        choices(slot, now: now).first { $0.id == id }
    }
    static func relevant(_ models: [CloudModel], slot: ModelSlot, current: String, includeOther: Bool = false) -> [CloudModel] {
        let order = choices(slot).map(\.id)
        var seen = Set<String>()
        // Recommendations are a view of the cloud result, never synthetic availability.
        // Expanded browsing applies only to text models, with the same adapter check.
        return models.filter {
            $0.supports(slot) && (order.contains($0.id) || $0.id == current || (includeOther && !slot.isSpeech))
                && seen.insert($0.id).inserted
        }.sorted {
            let a = order.firstIndex(of: $0.id) ?? Int.max
            let b = order.firstIndex(of: $1.id) ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }
    private static func text(_ id: String, _ label: String, _ input: String, _ output: String, detail: String? = nil) -> ModelRate {
        ModelRate(id: id, label: label, price: "輸入 US$\(input)／輸出 US$\(output) · 每百萬文字 tokens", detail: detail)
    }
}
