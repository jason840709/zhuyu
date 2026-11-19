import Foundation

/// One utterance has an ASR boundary and a separate translation boundary.
struct LiveTranscriptState {
    private(set) var segment: TranscriptSegment
    private var draftTargetLength = 0
    private var draftRevision = -1
    private let languageHint: String
    private let chosenTarget: String?
    private let languagePair: RecognitionLanguagePair?

    init(raw: String, sourceLanguageHint: String = "auto", targetLanguage: String? = nil,
         languagePair: RecognitionLanguagePair? = nil) {
        self.languagePair = languagePair
        languageHint = languagePair == nil ? sourceLanguageHint : "auto"
        chosenTarget = targetLanguage.map(TranscriptLanguage.code)
        let from = TranscriptLanguage.identify(raw, hint: languageHint)
        segment = TranscriptSegment(original: raw)
        segment.source = TranscriptLanguage.display(raw, language: from)
        segment.sourceLanguage = from
        segment.targetLanguage = languagePair?.target(for: from) ?? chosenTarget ?? (from == "zh-TW" ? "en" : "zh-TW")
        segment.recognitionFinal = false
    }

    @discardableResult
    mutating func recognize(_ raw: String, final: Bool, detectedLanguage: String? = nil,
                            addsSentencePunctuation: Bool = false, speechSpan: SpeechSpan? = nil) -> Bool {
        guard !segment.isRecognitionFinal, segment.status != .complete else { return false }
        segment.original = raw
        let previousSource = segment.resolvedSourceLanguage
        let previousTarget = segment.resolvedTargetLanguage
        let from = detectedLanguage.map(TranscriptLanguage.code) ?? TranscriptLanguage.identify(raw, hint: languageHint)
        segment.source = final && addsSentencePunctuation ? TranscriptLanguage.finalizedDisplay(raw, language: from)
            : TranscriptLanguage.display(raw, language: from)
        segment.sourceLanguage = from
        segment.targetLanguage = languagePair?.target(for: from) ?? chosenTarget ?? (from == "zh-TW" ? "en" : "zh-TW")
        if previousTarget != segment.resolvedTargetLanguage {
            // A revised language decision changes the target. A draft in the
            // old target language must not be relabelled as the new one.
            segment.translatedText = nil
            segment.english = ""
            segment.chinese = ""
            draftTargetLength = 0
            draftRevision = -1
        }
        if previousSource == "en", from != "en", segment.resolvedTargetLanguage != "en" { segment.english = "" }
        if previousSource == "zh-TW", from != "zh-TW", segment.resolvedTargetLanguage != "zh-TW" { segment.chinese = "" }
        segment.revision += 1
        segment.recognitionFinal = final
        if var speechSpan {
            if !final { speechSpan.endedAt = nil }
            segment.speechSpan = speechSpan
        }
        // Keep the last draft translation while the current source grows.
        return true
    }

    @discardableResult
    mutating func draft(_ result: TranslationResult, revision: Int) -> Bool {
        guard revision <= segment.revision, revision >= draftRevision, !segment.isRecognitionFinal,
              segment.status != .complete else { return false }
        let target = result.translatedText ?? (result.chinese == result.source ? result.english : result.chinese)
        if let language = result.sourceLanguage, TranscriptLanguage.code(language) != segment.resolvedSourceLanguage { return false }
        if let language = result.targetLanguage, TranscriptLanguage.code(language) != segment.resolvedTargetLanguage { return false }
        // A small local model can echo an unfinished Chinese input in its
        // English result. Keep a usable draft until it returns English text.
        if segment.resolvedTargetLanguage == "en", TranscriptLanguage.identify(target) != "en" { return false }
        // A shorter draft never replaces a longer one, so the gray text does not flicker.
        guard !target.isEmpty, target.count >= draftTargetLength else { return false }
        draftTargetLength = target.count
        draftRevision = revision
        segment.english = result.english
        segment.chinese = ChineseScript.traditional(result.chinese)
        segment.translatedText = target
        segment.targetLanguage = result.targetLanguage ?? segment.targetLanguage
        segment.status = .pending
        segment.error = nil
        return true
    }
}

@MainActor
final class LiveTranscriptCoordinator {
    var onChange: ((TranscriptSegment) -> Void)?
    var onFinal: ((TranscriptSegment) -> Void)?
    var onTiming: ((UUID, SpeechSpan) -> Void)?
    var onDraftError: ((String) -> Void)?

    private let translateDraft: @MainActor (TranscriptSegment) async throws -> TranslationResult
    private var states: [String: LiveTranscriptState] = [:]
    private var finishedIDs: [String: UUID] = [:]
    private var debounce: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var pendingDraft: (id: String, segment: TranscriptSegment)?
    private var deliveries: [String: Task<Void, Never>] = [:]
    private var epoch = UUID()
    private var reportedDraftError = false
    private var sourceLanguageHint = "auto"
    private var targetLanguage: String?
    private var publishesSourceImmediately = false
    private var languagePair: RecognitionLanguagePair?

    init(translateDraft: @escaping @MainActor (TranscriptSegment) async throws -> TranslationResult) {
        self.translateDraft = translateDraft
    }

    func configure(sourceLanguage: String, targetLanguage: String, languagePair: RecognitionLanguagePair? = nil,
                   publishesSourceImmediately: Bool = false) {
        sourceLanguageHint = sourceLanguage
        self.targetLanguage = targetLanguage
        self.languagePair = languagePair
        self.publishesSourceImmediately = publishesSourceImmediately
    }

    func receive(_ event: SpeechUpdate) {
        let raw = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, finishedIDs[event.id] == nil else { return }
        if states[event.id] == nil {
            states[event.id] = LiveTranscriptState(raw: raw, sourceLanguageHint: event.language ?? sourceLanguageHint,
                                                 targetLanguage: targetLanguage, languagePair: languagePair)
        }
        guard states[event.id]?.recognize(raw, final: event.isFinal, detectedLanguage: event.language,
                                          addsSentencePunctuation: event.addsSentencePunctuation,
                                          speechSpan: event.speechSpan) == true else { return }

        if event.isFinal {
            // Mark the utterance final first. Every delayed local callback must respect it.
            if let state = states[event.id] {
                finishedIDs[event.id] = state.segment.id
                onChange?(state.segment)
                onFinal?(state.segment)
            }
            states[event.id] = nil
            for kind in ["source", "translation"] {
                let key = event.id + ":" + kind
                deliveries.removeValue(forKey: key)?.cancel()
            }
            if pendingDraft?.id == event.id { pendingDraft = nil }
            return
        }

        // Streaming recognition can publish source text immediately. Keep a
        // 300 ms debounce for local translation and other source modes.
        if publishesSourceImmediately, let segment = states[event.id]?.segment {
            onChange?(segment)
        }
        debounce?.cancel()
        let generation = epoch
        let revision = states[event.id]!.segment.revision
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, epoch == generation,
                  let state = states[event.id], !state.segment.isRecognitionFinal,
                  state.segment.revision == revision else { return }
            if !publishesSourceImmediately { deliverLater(event.id, kind: "source", epoch: generation) }
            pendingDraft = (event.id, state.segment)
            drainDrafts(epoch: generation)
        }
    }

    func receiveTiming(itemID: String, span: SpeechSpan) {
        guard let segmentID = finishedIDs[itemID] else { return }
        onTiming?(segmentID, span)
    }

    private func drainDrafts(epoch generation: UUID) {
        guard draftTask == nil else { return }
        // A later recognizing event does not cancel an already-running translation.
        // This loop bounds the work to one request plus the latest pending
        // snapshot, so a slow local model cannot grow an unbounded work queue.
        draftTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == generation { draftTask = nil } }
            while epoch == generation, !Task.isCancelled, let work = pendingDraft {
                pendingDraft = nil
                guard states[work.id]?.segment.isRecognitionFinal == false else { continue }
                do {
                    let result = try await translateDraft(work.segment)
                    try Task.checkCancellation()
                    guard epoch == generation else { return }
                    if states[work.id]?.draft(result, revision: work.segment.revision) == true {
                        deliverLater(work.id, kind: "translation", epoch: generation)
                    }
                } catch is CancellationError { return }
                catch {
                    guard epoch == generation else { return }
                    if !reportedDraftError, states[work.id]?.segment.isRecognitionFinal == false {
                        reportedDraftError = true
                        onDraftError?("本機暫稿翻譯失敗：\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func deliverLater(_ id: String, kind: String, epoch generation: UUID) {
        let key = id + ":" + kind
        deliveries[key]?.cancel()
        // An additional 300 ms delay merges bursts of updates into one redraw.
        deliveries[key] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, epoch == generation,
                  let segment = states[id]?.segment, !segment.isRecognitionFinal else { return }
            onChange?(segment)
            deliveries[key] = nil
        }
    }

    func reset() {
        epoch = UUID()
        debounce?.cancel()
        debounce = nil
        draftTask?.cancel()
        draftTask = nil
        pendingDraft = nil
        for task in deliveries.values { task.cancel() }
        deliveries.removeAll()
        states.removeAll()
        finishedIDs.removeAll()
        reportedDraftError = false
    }
}
