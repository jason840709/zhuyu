import Foundation
import NaturalLanguage

enum ChineseScript {
    /// Presentation/storage normalization requested for Chinese text. Keep raw ASR in `original`.
    static func traditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? text
    }
    static func isChinese(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if recognizer.dominantLanguage == .traditionalChinese || recognizer.dominantLanguage == .simplifiedChinese { return true }
        let han = text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return han > 0 && (recognizer.dominantLanguage != .english || han * 5 >= letters)
    }
}

/// Mainland → Taiwan wording for machine translations.
/// Many on-device engines only have a Simplified-Chinese model, and the
/// Simplified→Traditional transform converts characters, not vocabulary,
/// so mainland terms such as 本科生 or 視頻 survived in Traditional characters.
/// Words whose mainland form is also correct Taiwan usage in some sense
/// (質量 = mass, 響應 as in 頻率響應, 項目, 支持, 運行, 水平) are deliberately absent.
enum TaiwanVocabulary {
    static let pairs: [(String, String)] = [
        ("本科生", "大學生"), ("本科", "大學部"), ("視頻會議", "視訊會議"), ("視頻", "影片"), ("音頻", "音訊"),
        ("軟件", "軟體"), ("硬件", "硬體"), ("信息", "資訊"), ("互聯網", "網際網路"), ("網絡", "網路"),
        ("數據庫", "資料庫"), ("數據", "資料"), ("默認", "預設"), ("屏幕", "螢幕"), ("鼠標", "滑鼠"),
        ("文件夾", "資料夾"), ("文檔", "文件"), ("程序員", "程式設計師"), ("源代碼", "原始碼"), ("代碼", "程式碼"),
        ("編程", "程式設計"), ("調試", "除錯"), ("線程", "執行緒"), ("計算機", "電腦"), ("筆記本電腦", "筆電"),
        ("打印機", "印表機"), ("打印", "列印"), ("激光器", "雷射"), ("激光", "雷射"), ("博客", "部落格"),
        ("短信", "簡訊"), ("出租車", "計程車"), ("公交車", "公車"), ("自行車", "腳踏車"), ("摩托車", "機車"),
        ("人工智能", "人工智慧"), ("智能", "智慧"), ("芯片", "晶片"), ("內存", "記憶體"), ("硬盤", "硬碟"),
        ("光盤", "光碟"), ("U盤", "隨身碟"), ("服務器", "伺服器"), ("客戶端", "用戶端"), ("登錄", "登入"),
        ("註銷", "登出"), ("鏈接", "連結"), ("帖子", "貼文"), ("高清", "高畫質"), ("分辨率", "解析度"),
        ("插件", "外掛程式"), ("菜單", "選單"), ("窗口", "視窗"), ("界面", "介面"), ("接口", "介面"),
        ("寬帶", "寬頻"), ("帶寬", "頻寬"), ("字符", "字元"), ("字節", "位元組"), ("量子比特", "量子位元"),
        ("比特", "位元"), ("二進制", "二進位"), ("激活", "啟用"), ("信號", "訊號"), ("噪聲", "雜訊"),
        ("傅里葉", "傅立葉"), ("薛定諤", "薛丁格"), ("模擬信號", "類比訊號"), ("數字信號", "數位訊號"),
        ("數字化", "數位化"), ("模擬電路", "類比電路"), ("集成電路", "積體電路"), ("晶體管", "電晶體"),
        ("二極管", "二極體"), ("傳感器", "感測器"), ("探測器", "偵測器"), ("等離子體", "電漿"), ("納米", "奈米"),
        ("郵箱", "電子信箱"), ("幻燈片", "投影片"), ("卸載", "解除安裝"), ("搜索", "搜尋"), ("在線", "線上"),
        ("實時", "即時"), ("交互", "互動"), ("存儲", "儲存"), ("緩存", "快取"), ("反饋", "回饋"),
        ("性價比", "CP 值"), ("土豆", "馬鈴薯"), ("菠蘿", "鳳梨"), ("渠道", "管道"),
        // Proper names: Taiwan's standard transliterations.
        ("斯坦福", "史丹佛"), ("硅谷", "矽谷"), ("悉尼", "雪梨"), ("新西蘭", "紐西蘭"), ("意大利", "義大利"),
        ("奧巴馬", "歐巴馬"), ("特朗普", "川普"), ("普京", "普丁"), ("費馬大定理", "費馬最後定理"),
        ("谷歌", "Google"), ("英偉達", "輝達"), ("尼日利亞", "奈及利亞"), ("沙特", "沙烏地"),
    ].sorted { $0.0.count > $1.0.count }

    static func apply(_ text: String) -> String {
        var result = text
        for (mainland, taiwan) in pairs where mainland != taiwan && result.contains(mainland) {
            result = result.replacingOccurrences(of: mainland, with: taiwan)
        }
        return result
    }
}

/// UI locales, provider hints and model codes are distinct.
enum TranscriptLanguage {
    static let sourceChoices = ["auto", "zh-TW", "en-US", "ja-JP"]
    static let targetChoices = ["zh-TW", "en-US"]

    static func code(_ locale: String) -> String {
        let value = locale.replacingOccurrences(of: "_", with: "-").lowercased()
        if value.hasPrefix("zh") || value == "cmn" { return "zh-TW" }
        if value.hasPrefix("ja") { return "ja" }
        if value.hasPrefix("en") { return "en" }
        return value == "auto" ? "auto" : value
    }
    static func name(_ locale: String) -> String {
        switch code(locale) {
        case "zh-TW": "繁體中文"
        case "en": "英文"
        case "ja": "日文"
        case "auto": "自動辨識"
        default: locale
        }
    }
    static func modelCode(_ locale: String) -> String {
        let value = code(locale)
        return value == "zh-TW" ? "zh" : value
    }
    static func locale(_ language: String) -> String {
        switch code(language) {
        case "en": "en-US"
        case "ja": "ja-JP"
        default: code(language)
        }
    }
    static func identify(_ text: String, hint: String = "auto") -> String {
        let fixed = code(hint)
        if fixed != "auto" { return fixed }
        let hasKana = text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0xFF66...0xFF9F).contains($0.value) })
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .traditionalChinese, .simplifiedChinese, .japanese]
        recognizer.processString(text)
        if recognizer.dominantLanguage == .japanese {
            // Han-only text is acoustically ambiguous without the provider's
            // language metadata. Use Chinese as the UI's common-language fallback;
            // an explicit Japanese source still preserves those characters.
            return hasKana ? "ja" : (ChineseScript.isChinese(text) ? "zh-TW" : "en")
        }
        if recognizer.dominantLanguage == .traditionalChinese || recognizer.dominantLanguage == .simplifiedChinese {
            return "zh-TW"
        }
        if recognizer.dominantLanguage != .english, hasKana { return "ja" }
        return ChineseScript.isChinese(text) ? "zh-TW" : "en"
    }
    static func display(_ text: String, language: String? = nil) -> String {
        let given = language.map(code)
        let actual = given == nil || given == "auto" ? identify(text) : given!
        // Latin text can contain Chinese names or code-switched phrases. Apply
        // character conversion there too, while preserving Japanese orthography.
        let marked = markPauses(text, latin: actual == "en")
        return actual == "ja" ? marked : ChineseScript.traditional(marked)
    }

    /// The live recognizer leaves a run of spaces where the speaker paused or a
    /// word was cut off ("just read  just watch"). Shown as plain spaces the
    /// restart disappears and translation reads one run-on clause, so a pause
    /// between words becomes a comma; after punctuation it is one space.
    static func markPauses(_ text: String, latin: Bool) -> String {
        guard text.contains("  ") else { return text }
        let pattern = try! NSRegularExpression(pattern: "(\\S)[ \\t\\u3000]{2,}(?=\\S)")
        var result = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let before = Range(match.range(at: 1), in: text) else { continue }
            result += text[last..<before.upperBound]
            let previous = text[before]
            if ",，、。.!?！？;；:：—-(（「『".contains(previous) {
                result += latin ? " " : ""
            } else {
                result += latin ? ", " : "，"
            }
            last = range.upperBound
        }
        result += text[last...]
        return result
    }

    static func finalizedDisplay(_ text: String, language: String) -> String {
        let display = display(text, language: language).trimmingCharacters(in: .whitespacesAndNewlines)
        let closingMarks = CharacterSet(charactersIn: "」』）】〉》”’\"')")
        let terminal = ".!?。！？…"
        let visibleEnd = display.trimmingCharacters(in: closingMarks).last
        guard let visibleEnd, !terminal.contains(visibleEnd) else { return display }
        let punctuation = code(language) == "en" ? "." : "。"
        if let last = display.last, ",，、;；:：".contains(last) {
            return String(display.dropLast()) + punctuation
        }
        return display + punctuation
    }
}

/// Both languages go to recognition; the translation goes to the right side
/// when the detected source is the left language, otherwise to the left.
struct RecognitionLanguagePair: Codable, Equatable, Sendable {
    let left: String
    let right: String
    init(left: String, right: String) {
        self.left = TranscriptLanguage.code(left)
        self.right = TranscriptLanguage.code(right)
    }
    func target(for source: String) -> String {
        TranscriptLanguage.code(source) == left ? right : left
    }
}

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, gemini, claude
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .claude: "Claude"
        }
    }
    static var speechProviders: [Provider] { [.openAI, .gemini] }
}

enum AudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone, system
    var id: String { rawValue }
    var title: String { self == .microphone ? "麥克風" : "電腦播放聲音" }
    var symbol: String { self == .microphone ? "mic" : "speaker.wave.2" }
}

/// How long a pause ends an utterance. Used by the client endpointer for
/// OpenAI recognition; Gemini ends utterances on the service side.
enum PauseSegmentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case short, standard, long
    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .short: 0.5
        case .standard: 0.8
        case .long: 1.2
        }
    }
    var title: String {
        switch self {
        case .short: "短（停 0.5 秒換行）"
        case .standard: "標準（停 0.8 秒換行）"
        case .long: "長（停 1.2 秒換行）"
        }
    }
    init(from decoder: Decoder) throws {
        // 0.4.x stored "textInactivity" / "acoustic"; both map to the new default.
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .standard
    }
}

/// Cross-conversation vocabulary; pinned entries become recognition hints.
struct VocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    var text: String
    var count = 1
    var lastUsed = Date()
    var pinned = false
    var id: String { text.lowercased() }
}

enum Vocabulary {
    /// Most useful entries first: pinned, then frequent, then recent.
    static func ranked(_ entries: [VocabularyEntry], limit: Int) -> [String] {
        entries.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.lastUsed > $1.lastUsed
        }.prefix(limit).map(\.text)
    }

    static func merge(_ terms: [String], into entries: inout [VocabularyEntry], at date: Date = Date()) {
        for term in terms {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 40 else { continue }
            if let index = entries.firstIndex(where: { $0.id == clean.lowercased() }) {
                entries[index].count += 1
                entries[index].lastUsed = date
            } else {
                entries.append(VocabularyEntry(text: clean, lastUsed: date))
            }
        }
        // Bound the store: keep pinned words and the 300 most useful others.
        if entries.count > 300 {
            let keep = Set(ranked(entries, limit: 300).map { $0.lowercased() })
            entries.removeAll { !$0.pinned && !keep.contains($0.id) }
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var asrProvider: Provider = .openAI
    var translationProvider: Provider = .openAI
    var sourceLanguage = "auto"
    /// Optional makes missing fields in older archives decodable.
    var targetLanguage: String? = "zh-TW"
    var resolvedTargetLanguage: String { TranscriptLanguage.code(targetLanguage ?? "zh-TW") }
    var bidirectional: Bool? = false
    var canUseBidirectionalRecognition: Bool {
        TranscriptLanguage.sourceChoices.contains(TranscriptLanguage.locale(sourceLanguage))
            && sourceLanguage != "auto" && TranscriptLanguage.code(sourceLanguage) != resolvedTargetLanguage
    }
    var recognitionPair: RecognitionLanguagePair? {
        bidirectional == true && canUseBidirectionalRecognition
            ? RecognitionLanguagePair(left: sourceLanguage, right: resolvedTargetLanguage) : nil
    }
    var recognitionLocales: [String] {
        if let pair = recognitionPair { return [pair.left, pair.right].map(TranscriptLanguage.locale) }
        return sourceLanguage == "auto" ? [] : [TranscriptLanguage.locale(sourceLanguage)]
    }
    func target(for source: String) -> String { recognitionPair?.target(for: source) ?? resolvedTargetLanguage }
    /// Legacy source/target fields remain the per-request wire contract. The
    /// application presents a two-language dialogue; old archives migrate once
    /// loaded without changing any segment's recorded direction or raw speech.
    static var dialogueDefault: Self {
        var value = Self()
        value.enableDialogueLayout()
        return value
    }
    mutating func enableDialogueLayout() {
        let choices = TranscriptLanguage.sourceChoices.filter { $0 != "auto" }.map(TranscriptLanguage.code)
        var left = TranscriptLanguage.code(sourceLanguage)
        var right = resolvedTargetLanguage
        if !choices.contains(right) { right = "zh-TW" }
        if !choices.contains(left) || left == right { left = right == "en" ? "zh-TW" : "en" }
        sourceLanguage = TranscriptLanguage.locale(left)
        targetLanguage = TranscriptLanguage.locale(right)
        bidirectional = true
    }
    var leftLanguage: String { TranscriptLanguage.code(sourceLanguage) }
    var rightLanguage: String { resolvedTargetLanguage }
    mutating func setDialogueLanguage(_ language: String, onLeft: Bool) {
        let value = TranscriptLanguage.code(language)
        if onLeft {
            let previous = leftLanguage
            sourceLanguage = TranscriptLanguage.locale(value)
            if rightLanguage == value { targetLanguage = TranscriptLanguage.locale(previous) }
        } else {
            let previous = rightLanguage
            targetLanguage = TranscriptLanguage.locale(value)
            if leftLanguage == value { sourceLanguage = TranscriptLanguage.locale(previous) }
        }
        enableDialogueLayout()
    }
    var audioSource: AudioSource = .microphone
    /// 0.4.x field, kept verbatim so an older build can still read this archive.
    private var savedPauseSegmentation: String?
    /// 0.5.0 pause length; unknown to older builds, which ignore extra keys.
    private var savedPauseLength: PauseSegmentation?
    var pauseSegmentation: PauseSegmentation {
        get { savedPauseLength ?? .standard }
        set { savedPauseLength = newValue }
    }
    /// OpenAI turns are ended by the app; Gemini ends them on the service side.
    var supportsPauseSegmentation: Bool { asrProvider == .openAI }
    /// Missing in older archives; mode controls writes, never microphone state.
    var incognitoMode: Bool? = nil
    var isIncognito: Bool {
        get { incognitoMode == true }
        set { incognitoMode = newValue }
    }
    var contextualCorrection = true
    var glossary = ""
    /// Optional scene for translation ("graduate lecture in English"). Optional keeps old archives readable.
    var translationNote: String?
    var openAIASRModel = "gpt-live-transcribe"
    var geminiASRModel = "gemini-3.5-transcribe-live"
    var openAITranslationModel = "gpt-6-luna"
    var geminiTranslationModel = "gemini-3.8-flash"
    var claudeTranslationModel = "claude-haiku-5-5"
    /// Draft engine for the gray text shown while speaking. Optional keeps old settings readable.
    var draftEngine: DraftEngineKind?
    var draftModelEndpoint: String?
    var draftModelName: String?
    var draftEngineConfig: DraftEngineConfig {
        DraftEngineConfig(kind: draftEngine ?? .localModel,
                          endpoint: draftModelEndpoint ?? DraftEngineConfig.defaultEndpoint,
                          model: draftModelName ?? DraftEngineConfig.defaultModel)
    }
}

enum SegmentStatus: String, Codable, Sendable {
    case pending, complete, failed
}

struct SpeechSpan: Codable, Equatable, Sendable {
    let startedAt: Date
    var endedAt: Date?
    var isEstimated = false
}

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    /// Legacy rows only have createdAt, which is when the row appeared.
    var speechSpan: SpeechSpan?
    /// The original speech recognition is retained even after contextual revision.
    var original: String
    var source: String
    var contextualRevision: SemanticRevision?
    var english = ""
    var chinese = ""
    var status: SegmentStatus = .pending
    var error: String?
    var terms: [String] = []
    var revision = 0
    var sourceLanguage: String?
    var targetLanguage: String?
    var translatedText: String?
    /// Independent from translation completion. nil is a final row from an older archive.
    var recognitionFinal: Bool?
    var isRecognitionFinal: Bool { recognitionFinal ?? true }

    var resolvedSourceLanguage: String {
        if let sourceLanguage { return TranscriptLanguage.code(sourceLanguage) }
        // Older archives were Chinese/English. Preserve that interpretation;
        // Japanese script in imported old rows remains identifiable by kana.
        if source.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
        return ChineseScript.isChinese(source) ? "zh-TW" : "en"
    }
    var resolvedTargetLanguage: String {
        targetLanguage.map(TranscriptLanguage.code) ?? (resolvedSourceLanguage == "zh-TW" ? "en" : "zh-TW")
    }

    var sourceCopyText: String { TranscriptLanguage.display(source, language: resolvedSourceLanguage) }

    var originalBeforeContentEdit: String? {
        let raw = TranscriptLanguage.display(original, language: resolvedSourceLanguage)
        guard raw != sourceCopyText,
              TranscriptLanguage.finalizedDisplay(raw, language: resolvedSourceLanguage) != sourceCopyText else { return nil }
        return raw
    }

    var translatedCopyText: String {
        if resolvedSourceLanguage == resolvedTargetLanguage { return sourceCopyText }
        if let translatedText, !translatedText.isEmpty {
            return TranscriptLanguage.display(translatedText, language: targetLanguage)
        }
        switch resolvedTargetLanguage {
        case "en": return TranscriptLanguage.display(english, language: "en")
        case "zh-TW": return ChineseScript.traditional(chinese)
        default: return ""
        }
    }
    var combinedCopyText: String {
        var seen = Set<String>()
        return [sourceCopyText, resolvedSourceLanguage == "en" ? "" : TranscriptLanguage.display(english, language: "en"),
                resolvedSourceLanguage == "zh-TW" ? "" : ChineseScript.traditional(chinese), translatedCopyText]
            .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n\n")
    }

    init(original: String, createdAt: Date = Date()) {
        self.original = original
        self.source = original
        self.createdAt = createdAt
    }
}

/// A language column is independent of ASR/translation completion. Original
/// speech appears on its own side immediately, even if the other side fails.
struct BilingualCell: Equatable, Sendable {
    enum Role: Equatable, Sendable { case original, translation, unrecorded }
    let language: String
    let role: Role
    let text: String

    init(segment: TranscriptSegment, language: String) {
        self.language = TranscriptLanguage.code(language)
        if self.language == segment.resolvedSourceLanguage {
            role = .original
            text = segment.sourceCopyText
        } else if self.language == segment.resolvedTargetLanguage {
            role = .translation
            text = segment.translatedCopyText
        } else {
            role = .unrecorded
            switch self.language {
            case "en": text = TranscriptLanguage.display(segment.english, language: "en")
            case "zh-TW": text = ChineseScript.traditional(segment.chinese)
            default: text = ""
            }
        }
    }
    func isWaitingForTranslation(in segment: TranscriptSegment) -> Bool {
        role == .translation && segment.resolvedSourceLanguage != segment.resolvedTargetLanguage
            && segment.status == .pending
    }
}

struct SemanticEvidence: Codable, Equatable, Sendable {
    var segmentID: UUID
    var quote: String
    var wasRecognitionFinal: Bool

    func matches(_ segment: TranscriptSegment) -> Bool {
        segment.id == segmentID && !quote.isEmpty
            && Self.containsLiteral(quote, in: segment.sourceCopyText)
    }

    static func containsLiteral(_ value: String, in source: String) -> Bool {
        literalRange(of: value, in: source) != nil
    }

    /// Shares the same word boundaries with local quotation extraction, so a
    /// missing API quote cannot turn an acronym inside another word into proof.
    static func literalRange(of value: String, in source: String) -> Range<String.Index>? {
        guard !value.isEmpty else { return nil }
        func asciiWord(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isASCII && (character.isLetter || character.isNumber || character == "_")
        }
        var start = source.startIndex
        while start < source.endIndex,
              let match = source.range(of: value, options: [.caseInsensitive, .diacriticInsensitive],
                                       range: start..<source.endIndex) {
            let before = match.lowerBound == source.startIndex ? nil : source[source.index(before: match.lowerBound)]
            let after = match.upperBound == source.endIndex ? nil : source[match.upperBound]
            if !(asciiWord(value.first) && asciiWord(before)) && !(asciiWord(value.last) && asciiWord(after)) {
                return match
            }
            start = source.index(after: match.lowerBound)
        }
        return nil
    }
}

struct SemanticCorrection: Codable, Equatable, Sendable {
    var surface: String
    var rationale: String
}

struct SemanticRevision: Codable, Equatable, Sendable {
    var surface: String
    var term: String
    var prior: SemanticEvidence
    var confirmation: SemanticEvidence
    var rationale: String
}

struct SemanticTerm: Identifiable, Codable, Equatable, Sendable {
    var text: String
    var evidence: SemanticEvidence
    // A contextual spelling proposal is never represented as a literal quote.
    // Optional for compatibility with all existing conversation archives.
    var correction: SemanticCorrection? = nil
    var id: String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }

    func matches(_ segment: TranscriptSegment) -> Bool {
        !text.isEmpty && text.count <= 80
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !text.contains("<") && !text.contains(">")
            && evidence.matches(segment)
            && (SemanticEvidence.containsLiteral(text, in: evidence.quote)
                || correction.map { SemanticEvidence.containsLiteral($0.surface, in: evidence.quote) } == true)
    }
}

enum SemanticApplicationState: String, Codable, Sendable {
    case queued, waiting, submitted, applied, nextStart, unsupported, failed, superseded
    var title: String {
        switch self {
        case .queued: "等待語音停頓後更新"
        case .waiting: "等待辨識服務確認"
        case .submitted: "詞彙提示已送出"
        case .applied: "辨識提示已更新"
        case .nextStart: "下次開始辨識時載入"
        case .unsupported: "目前辨識模型不支援詞彙提示"
        case .failed: "辨識提示更新失敗"
        case .superseded: "已由新的語意環境取代"
        }
    }
}

struct SemanticApplicationReceipt: Codable, Equatable, Sendable {
    var snapshotID: UUID
    var provider: Provider
    var model: String
    var state: SemanticApplicationState
    var keywords: [String]
    var updatedAt = Date()
    var error: String?

    var displayState: String {
        if keywords.isEmpty && (state == .applied || state == .submitted) {
            return "目前沒有辨識詞彙提示"
        }
        return state.title
    }
}

struct SemanticSnapshot: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var topic: String
    var topicEvidence: SemanticEvidence?
    var terms: [SemanticTerm]
    var provider: Provider
    var model: String
    var application: SemanticApplicationReceipt?
    // A decoded proposal is checked against the live rows before it can be stored.
    var proposedRevisions: [SemanticRevision] = []
    var proposedRevision: SemanticRevision? { proposedRevisions.first }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, topic, topicEvidence, terms, provider, model, application
    }

    /// A saved hint is usable only while its cited speech still exists unchanged.
    func groundedTerms(in segments: [TranscriptSegment]) -> [SemanticTerm] {
        terms.filter { term in segments.contains { term.matches($0) } }
    }

    func groundedTopic(in segments: [TranscriptSegment]) -> String {
        guard let topicEvidence, segments.contains(where: { topicEvidence.matches($0) }) else { return "" }
        return topic
    }
}

struct SemanticEnvironment: Codable, Equatable, Sendable {
    // Preserve meaningful topic/vocabulary changes, not every transcript delta.
    var snapshots: [SemanticSnapshot] = []
    var latest: SemanticSnapshot? { snapshots.last }

    /// Historical words remain local after a topic change. Supply only a
    /// bounded, still-grounded set to the next semantic request, never directly
    /// to ASR. The selected active list remains the generator's responsibility.
    func knownTerms(in segments: [TranscriptSegment]) -> [SemanticTerm] {
        let rows = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        var words: [SemanticTerm] = []
        var indices: [String: Int] = [:]
        for snapshot in snapshots.reversed() {
            for term in snapshot.terms {
                if let index = indices[term.id] {
                    // Prefer a directly spoken spelling over an older guess
                    // of that same word, without changing its recency rank.
                    if words[index].correction != nil, term.correction == nil,
                       let row = rows[term.evidence.segmentID], term.matches(row) {
                        words[index] = term
                    }
                    continue
                }
                guard words.count < 24, let row = rows[term.evidence.segmentID], term.matches(row) else { continue }
                indices[term.id] = words.count
                words.append(term)
            }
        }
        return words
    }
}

struct Conversation: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var updatedAt = Date()
    var name: String?
    var segments: [TranscriptSegment] = []
    /// Optional so existing user archives remain readable without migration.
    var semanticEnvironment: SemanticEnvironment?
    var title: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        guard let text = segments.first?.source, !text.isEmpty else { return "新的對話" }
        return TranscriptLanguage.display(String(text.prefix(28)), language: segments.first?.resolvedSourceLanguage)
    }
    var hasContent: Bool { !segments.isEmpty }
}

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown, text
    var id: String { rawValue }
    var title: String { self == .markdown ? "Markdown" : "TXT" }
    var fileExtension: String { self == .markdown ? "md" : "txt" }
}

enum TranscriptExporter {
    static func content(_ conversation: Conversation, format: ExportFormat) -> String {
        let markdown = format == .markdown
        var lines: [String] = [markdown ? "# \(conversation.title)" : conversation.title,
                               "", "開始時間：\(dateString(conversation.createdAt))", ""]
        for (index, segment) in conversation.segments.enumerated() {
            let label = "\(index + 1) · \(speechTime(segment))"
            lines.append(markdown ? "## \(label)" : "[\(label)]")
            lines.append("")
            append("原文", segment.sourceCopyText, markdown: markdown, to: &lines)
            if let rawDisplay = segment.originalBeforeContentEdit {
                append("原始辨識", rawDisplay, markdown: markdown, to: &lines)
                if let revision = segment.contextualRevision {
                    append("術語修正", revision.surface + " → " + revision.term, markdown: markdown, to: &lines)
                    append("後文依據", revision.confirmation.quote, markdown: markdown, to: &lines)
                }
            }
            if !segment.english.isEmpty || segment.resolvedTargetLanguage == "en" || segment.targetLanguage == nil {
                let english = segment.resolvedSourceLanguage == "en" ? segment.sourceCopyText
                    : segment.resolvedTargetLanguage == "en" ? segment.translatedCopyText
                    : TranscriptLanguage.display(segment.english, language: "en")
                append("English", english.isEmpty ? "（尚未完成翻譯）" : english,
                       markdown: markdown, to: &lines)
            }
            let chinese = segment.resolvedTargetLanguage == "zh-TW" ? segment.translatedCopyText : ChineseScript.traditional(segment.chinese)
            if !chinese.isEmpty {
                append("繁體中文", chinese, markdown: markdown, to: &lines)
            }
            if !["en", "zh-TW"].contains(segment.resolvedTargetLanguage), !segment.translatedCopyText.isEmpty {
                append(TranscriptLanguage.name(segment.resolvedTargetLanguage), segment.translatedCopyText, markdown: markdown, to: &lines)
            }
            if !segment.terms.isEmpty {
                append("術語", segment.terms.joined(separator: "、"), markdown: markdown, to: &lines)
            }
            if segment.status != .complete {
                let status = segment.status == .pending ? "翻譯待處理" : "翻譯失敗"
                append("狀態", status + (segment.error.map { "：\($0)" } ?? ""),
                       markdown: markdown, to: &lines)
            }
            lines.append("")
        }
        if let environment = conversation.semanticEnvironment, !environment.snapshots.isEmpty {
            lines.append(markdown ? "## 語意環境紀錄" : "[語意環境紀錄]")
            lines.append("")
            for snapshot in environment.snapshots {
                append("更新時間", timeString(snapshot.createdAt), markdown: markdown, to: &lines)
                append("主題", snapshot.topic.isEmpty ? "未定主題" : snapshot.topic, markdown: markdown, to: &lines)
                append("詞彙", snapshot.terms.map(\.text).joined(separator: "、"), markdown: markdown, to: &lines)
                if let evidence = snapshot.topicEvidence {
                    append("主題來源", evidence.quote, markdown: markdown, to: &lines)
                }
                for term in snapshot.terms {
                    let origin = conversation.segments.first { $0.id == term.evidence.segmentID }
                    let stamp = origin.map { timeString($0.speechSpan?.startedAt ?? $0.createdAt) + " " } ?? ""
                    if let correction = term.correction {
                        append("語境推定", correction.surface + " → " + term.text, markdown: markdown, to: &lines)
                        append("推定依據", correction.rationale, markdown: markdown, to: &lines)
                    }
                    append(term.text + "的來源", stamp + term.evidence.quote, markdown: markdown, to: &lines)
                }
                if let receipt = snapshot.application {
                    append("辨識提示", receipt.displayState, markdown: markdown, to: &lines)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func filename(_ conversation: Conversation, format: ExportFormat) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\n\r\t")
        let safe = conversation.title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = ISO8601DateFormatter().string(from: conversation.createdAt)
            .replacingOccurrences(of: ":", with: "-")
        return "\(stamp)_\(safe.isEmpty ? "逐字稿" : String(safe.prefix(48))).\(format.fileExtension)"
    }

    private static func append(_ label: String, _ text: String, markdown: Bool, to lines: inout [String]) {
        lines.append(markdown ? "**\(label)**" : "\(label)：")
        lines.append(text)
        lines.append("")
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: date)
    }

    static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func speechTime(_ segment: TranscriptSegment) -> String {
        guard let speech = segment.speechSpan else { return "顯示於 \(timeString(segment.createdAt))" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.S"
        let start = formatter.string(from: speech.startedAt)
        guard let end = speech.endedAt, end >= speech.startedAt else { return "\(start) 開始" }
        let duration = String(format: "%.1f", end.timeIntervalSince(speech.startedAt))
        let estimated = speech.isEstimated ? "約 " : ""
        return "\(start)–\(formatter.string(from: end)) · \(estimated)\(duration) 秒"
    }
}

struct TranscriptArchive: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var revision = 0
    var settings = AppSettings()
    var conversations: [Conversation] = []
    var currentConversationID: UUID?
    /// Optional: archives before 0.5.0 have no vocabulary store.
    var vocabulary: [VocabularyEntry]?
}

/// Each transcript write is guarded by incognito mode.
/// Whole-archive storage needs a durable view separate from the live transcript:
/// disabling the guard must not flush rows that were skipped while it was on.
struct ArchiveWriteProjection: Sendable {
    private(set) var saved: [Conversation]
    private var observed: [Conversation]

    init(loaded: [Conversation] = []) { saved = loaded; observed = loaded }

    func project(_ current: [Conversation], incognito: Bool) -> [Conversation] {
        // Preserve the original whole-archive path when no write was skipped.
        if !incognito, observed == saved { return current }
        let currentIDs = Set(current.map(\.id))
        var result = saved.filter { currentIDs.contains($0.id) }
        let previous = Dictionary(uniqueKeysWithValues: observed.map { ($0.id, $0) })
        for item in current {
            let old = previous[item.id]
            let oldRows = Dictionary(uniqueKeysWithValues: (old?.segments ?? []).map { ($0.id, $0) })
            let changed = item.segments.filter { oldRows[$0.id] != $0 }
            let liveIDs = Set(item.segments.map(\.id))
            let existing = result.firstIndex { $0.id == item.id }
            // Even in incognito, explicit deletions must not resurrect saved rows.
            if let existing { result[existing].segments.removeAll { !liveIDs.contains($0.id) } }
            guard !incognito else { continue }
            if old == nil {
                result.append(item)
                continue
            }
            guard existing != nil || !changed.isEmpty else { continue }
            var target = existing.map { result[$0] } ?? Conversation()
            if existing == nil {
                target.id = item.id; target.createdAt = item.createdAt
                target.name = item.name != old?.name ? item.name : nil
            } else if item.name != old?.name { target.name = item.name }
            var eligible = Dictionary(uniqueKeysWithValues: target.segments.map { ($0.id, $0) })
            for row in changed { eligible[row.id] = row }
            target.segments = item.segments.compactMap { eligible[$0.id] }
            // Keep prior public history. A newly changed semantic record may be
            // saved only when every quoted source is present in the durable rows.
            if item.semanticEnvironment != old?.semanticEnvironment {
                let oldSnapshots = Dictionary(uniqueKeysWithValues: (old?.semanticEnvironment?.snapshots ?? []).map { ($0.id, $0) })
                let durable = Dictionary(uniqueKeysWithValues: (target.semanticEnvironment?.snapshots ?? []).map { ($0.id, $0) })
                let selected = (item.semanticEnvironment?.snapshots ?? []).compactMap { snapshot -> SemanticSnapshot? in
                    if snapshot == oldSnapshots[snapshot.id] { return durable[snapshot.id] }
                    let valid = snapshot.groundedTerms(in: target.segments).count == snapshot.terms.count
                        && (snapshot.topic.isEmpty || !snapshot.groundedTopic(in: target.segments).isEmpty)
                    // A public quote can become historical after a normal edit.
                    // Still save its withdrawal/acknowledgement status, provided
                    // no topic, terms, correction or quote changed with it.
                    var provenance = snapshot
                    provenance.application = nil
                    var prior = durable[snapshot.id]
                    prior?.application = nil
                    return valid || provenance == prior ? snapshot : durable[snapshot.id]
                }
                target.semanticEnvironment = selected.isEmpty ? nil : SemanticEnvironment(snapshots: selected)
            }
            if target != (existing.map { result[$0] }) { target.updatedAt = item.updatedAt }
            if let existing { result[existing] = target } else { result.append(target) }
        }
        return result
    }

    mutating func commit(observed: [Conversation], saved: [Conversation]) {
        self.observed = observed; self.saved = saved
    }

    mutating func observeWithoutSaving(_ current: [Conversation]) {
        observed = current
    }
}

/// Two alternating complete snapshots preserve the previous valid save if a write is interrupted.
/// Writes are ordinary file writes, without hard links, lock files, or atomic temp-file replacement.
struct ArchiveStore: Sendable {
    let directory: URL

    func load() throws -> TranscriptArchive? {
        let files = (0...1).map { directory.appendingPathComponent("archive-\($0).json") }
        var archives: [TranscriptArchive] = []
        var errors: [String] = []
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            do {
                let archive = try JSONDecoder().decode(TranscriptArchive.self, from: Data(contentsOf: url))
                guard archive.schemaVersion == 1 else {
                    throw StoreError.unsupportedVersion(archive.schemaVersion)
                }
                archives.append(archive)
            } catch {
                errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if let archive = archives.max(by: { $0.revision < $1.revision }) { return archive }
        if !errors.isEmpty { throw StoreError.unreadable(errors.joined(separator: "；")) }
        return nil
    }

    func save(_ archive: TranscriptArchive) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        let url = directory.appendingPathComponent("archive-\(archive.revision % 2).json")
        try data.write(to: url, options: [])
    }

    enum StoreError: LocalizedError {
        case unreadable(String)
        case unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .unreadable(let details): "歷史紀錄無法讀取，原檔已保留。\(details)"
            case .unsupportedVersion(let version): "不支援資料格式 \(version)"
            }
        }
    }
}
