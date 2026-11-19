import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum CaptureState: Equatable {
    case loadingHistory, idle, starting, listening, stopping
    var title: String {
        switch self {
        case .loadingHistory: "讀取歷史中"
        case .idle: "準備就緒"
        case .starting: "正在連線"
        case .listening: "正在聆聽"
        case .stopping: "正在結束"
        }
    }
}

@MainActor @Observable
final class AppModel {
    var settings = AppSettings.dialogueDefault {
        didSet {
            if oldValue.isIncognito && !settings.isIncognito {
                // Interim speech may not have reached persist() yet. Record the
                // private interval before a settings-only save can see it.
                archiveProjection.observeWithoutSaving(conversations)
            }
        }
    }
    private(set) var conversations: [Conversation] = []
    private(set) var currentConversationID: UUID?
    private var archiveProjection = ArchiveWriteProjection()
    private(set) var partialText = ""
    private(set) var liveContentRevision = 0
    private(set) var captureState: CaptureState = .idle
    private(set) var audioLevel: Float = 0
    private(set) var navigationInProgress = false
    var errorMessage: String?
    var infoMessage: String?
    var showsSettings = false
    var showsHistory = false
    var showsSemanticEnvironment = false
    private(set) var semanticActivity = ""
    private(set) var semanticError: String?
    private(set) var isAnalyzingSemantics = false
    var historySearch = ""
    let isDemo: Bool
    let dataDirectory: URL
    let modelDirectory = ModelDirectory()
    private(set) var keyDrafts = APIKeyDrafts()

    /// Cross-conversation vocabulary (pinned terms reused as recognition hints).
    private(set) var vocabulary: [VocabularyEntry] = []

    @ObservationIgnored let pipeline = SpeechPipeline()
    @ObservationIgnored private let translator: TranslationClient
    @ObservationIgnored private let learner: VocabularyLearner
    @ObservationIgnored private let draftTranslator: LocalDraftTranslator
    @ObservationIgnored private lazy var liveCoordinator = LiveTranscriptCoordinator { [weak self] segment in
        guard let self else { throw CancellationError() }
        return try await self.draftTranslator.translate(source: segment.source,
                                                       sourceLanguage: segment.resolvedSourceLanguage,
                                                       targetLanguage: segment.resolvedTargetLanguage)
    }
    @ObservationIgnored private var speechConversationID: UUID?
    @ObservationIgnored private let store: ArchiveStore
    @ObservationIgnored private let secretStore: SecretStore
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var historyReady = false
    @ObservationIgnored private var translationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var queue: [WorkItem] = []
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var languageStartTask: Task<Void, Never>?
    @ObservationIgnored private var languageTransitionTask: Task<Void, Never>?
    @ObservationIgnored private var languageIntent = UUID()
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var captureEpoch = UUID()
    @ObservationIgnored private var learningEpoch = UUID()
    @ObservationIgnored private var learningTask: Task<Void, Never>?
    /// Finalized rows of the live conversation not yet given to the learner.
    @ObservationIgnored private var unlearned: [UUID] = []
    /// Scene-update budget: sentences between updates (grows while nothing changes),
    /// the last start time, and starts within the past hour.
    @ObservationIgnored private var learningInterval = LearningBudget.baseInterval
    @ObservationIgnored private var lastLearningStart: Date?
    @ObservationIgnored private var learningStarts: [Date] = []
    /// Requests sent in the current listening session, shown in the 語意環境 panel.
    private(set) var sessionTranslationRequests = 0
    private(set) var sessionContextRequests = 0
    @ObservationIgnored private var semanticEnabled = true

    private struct WorkItem: Sendable {
        let conversationID: UUID
        let segmentID: UUID
        var isPolish = false
    }

    var currentConversation: Conversation? {
        conversations.first { $0.id == currentConversationID }
    }
    var currentSemanticSnapshot: SemanticSnapshot? { currentConversation?.semanticEnvironment?.latest }
    var hasPendingSemanticAnalysis: Bool { learningTask != nil || !unlearned.isEmpty }
    var isRecording: Bool { captureState == .listening }
    var hasPendingTranslations: Bool { !translationTasks.isEmpty || !queue.isEmpty }
    var dialoguePair: RecognitionLanguagePair {
        settings.recognitionPair ?? RecognitionLanguagePair(left: "en", right: "zh-TW")
    }
    var canSwapLanguages: Bool {
        !isBusy && (captureState == .idle || captureState == .listening)
            && TranscriptLanguage.sourceChoices.contains(TranscriptLanguage.locale(settings.sourceLanguage))
            && settings.sourceLanguage != "auto"
            && TranscriptLanguage.code(settings.sourceLanguage) != settings.resolvedTargetLanguage
    }

    func swapLanguages() {
        guard canSwapLanguages else { return }
        changeDialoguePair(RecognitionLanguagePair(left: dialoguePair.right, right: dialoguePair.left),
                           startWhenIdle: false)
    }

    func selectDialogueLanguage(_ language: String, onLeft: Bool) {
        guard !isBusy, TranscriptLanguage.code(language) != "auto",
              TranscriptLanguage.sourceChoices.contains(TranscriptLanguage.locale(language)) else { return }
        var selected = settings
        selected.setDialogueLanguage(language, onLeft: onLeft)
        guard let pair = selected.recognitionPair, pair != dialoguePair else { return }
        changeDialoguePair(pair, startWhenIdle: true)
    }

    private func cancelLanguageStart() {
        languageIntent = UUID()
        languageStartTask?.cancel()
        languageStartTask = nil
    }

    private func applyDialoguePair(_ pair: RecognitionLanguagePair) {
        // Keep unrelated settings changed while the old session was draining.
        settings.sourceLanguage = TranscriptLanguage.locale(pair.left)
        settings.targetLanguage = TranscriptLanguage.locale(pair.right)
        settings.bidirectional = true
        settingsChanged()
    }

    private func changeDialoguePair(_ pair: RecognitionLanguagePair, startWhenIdle: Bool) {
        cancelLanguageStart()
        if isRecording {
            navigationInProgress = true
            languageTransitionTask = Task { [weak self] in
                guard let self else { return }
                defer { navigationInProgress = false; languageTransitionTask = nil }
                // The old pair stays in effect through final audio callbacks.
                // Stop first, then switch the pair, and stay idle.
                await stop()
                applyDialoguePair(pair)
            }
            return
        }
        guard captureState == .idle else { return }
        applyDialoguePair(pair)
        guard startWhenIdle, !isDemo else { return }
        let intent = languageIntent, conversationID = currentConversationID
        // Wait 500 ms before starting an idle selection.
        // Unlike a selection, swapping the two sides does not start capture.
        languageStartTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, languageIntent == intent else { return }
            languageStartTask = nil
            guard currentConversationID == conversationID, captureState == .idle,
                  !isBusy, dialoguePair == pair else { return }
            await start()
        }
    }

    func finishForTermination() async {
        cancelLanguageStart()
        if let languageTransitionTask { await languageTransitionTask.value }
        await stop()
    }
    var isBusy: Bool { navigationInProgress || captureState == .loadingHistory || captureState == .starting || captureState == .stopping }
    var history: [Conversation] {
        guard !settings.isIncognito else { return [] }
        return (isDemo ? conversations : archiveProjection.saved).filter { conversation in
            guard conversation.hasContent else { return false }
            let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty || conversation.title.localizedCaseInsensitiveContains(query)
                || conversation.segments.contains {
                    $0.source.localizedCaseInsensitiveContains(query)
                        || $0.english.localizedCaseInsensitiveContains(query)
                        || $0.chinese.localizedCaseInsensitiveContains(query)
                        || $0.translatedCopyText.localizedCaseInsensitiveContains(query)
                }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var learnedTerms: [String] {
        guard let conversation = currentConversation else { return [] }
        return conversation.semanticEnvironment?.latest?.groundedTerms(in: conversation.segments).map(\.text) ?? []
    }
    var wordCount: Int {
        currentConversation?.segments.reduce(0) { $0 + $1.source.count } ?? 0
    }

    init(dataDirectory: URL? = nil, credentialDirectory: URL? = nil,
         translationClient: TranslationClient? = nil, learner: VocabularyLearner? = nil,
         draftEngine: DraftEngineConfig? = nil,
         demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        self.isDemo = demo
        self.translator = translationClient ?? TranslationClient()
        self.learner = learner ?? VocabularyLearner()
        // The demo shows sample data only and never contacts a server, local or remote.
        self.draftTranslator = LocalDraftTranslator(config: demo ? DraftEngineConfig(kind: .off) : draftEngine ?? DraftEngineConfig())
        self.dataDirectory = dataDirectory ?? URL.applicationSupportDirectory
            .appendingPathComponent("app.zhuyu.mac", isDirectory: true)
        self.store = ArchiveStore(directory: self.dataDirectory)
        self.secretStore = SecretStore(directory: credentialDirectory ?? self.dataDirectory.appendingPathComponent("Private", isDirectory: true))
        if demo {
            installDemo()
            historyReady = true
            #if UI_ACCEPTANCE
            modelDirectory.installPreview()
            #endif
        } else {
            // Build the window first and preserve unread history if the load fails.
            captureState = .loadingHistory
        }
        pipeline.onUtterance = { [weak self] event in self?.liveCoordinator.receive(event) }
        liveCoordinator.onChange = { [weak self] segment in self?.upsertSpeechSegment(segment) }
        liveCoordinator.onFinal = { [weak self] segment in self?.translateRecognizedSegment(segment) }
        liveCoordinator.onDraftError = { [weak self] message in self?.infoMessage = message }
        pipeline.onLevel = { [weak self] level in self?.audioLevel = level }
        pipeline.onWarning = { [weak self] message in self?.infoMessage = message }
        pipeline.onError = { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            Task { await self.stop() }
        }
    }

    func onFirstAppearance() {
        guard !started else { return }
        started = true
        guard !isDemo else { return }
        Task {
            do {
                if let archive = try await ArchiveLoader().load(store) {
                    settings = archive.settings
                    settings.enableDialogueLayout()
                    conversations = archive.conversations
                    for ci in conversations.indices {
                        for si in conversations[ci].segments.indices {
                            let from = conversations[ci].segments[si].resolvedSourceLanguage
                            conversations[ci].segments[si].source = TranscriptLanguage.display(conversations[ci].segments[si].source, language: from)
                            conversations[ci].segments[si].chinese = ChineseScript.traditional(conversations[ci].segments[si].chinese)
                            if let target = conversations[ci].segments[si].translatedText {
                                conversations[ci].segments[si].translatedText = TranscriptLanguage.display(target, language: conversations[ci].segments[si].resolvedTargetLanguage)
                            }
                        }
                    }
                    vocabulary = archive.vocabulary ?? []
                    archiveProjection = ArchiveWriteProjection(loaded: conversations)
                    currentConversationID = settings.isIncognito ? nil : archive.currentConversationID
                    revision = archive.revision
                }
            } catch {
                writable = false
                errorMessage = error.localizedDescription
            }
            if currentConversation == nil {
                let conversation = Conversation()
                conversations.append(conversation)
                currentConversationID = conversation.id
            }
            recoverPendingTranslations()
            historyReady = true
            captureState = .idle
        }
    }

    func settingsChanged() {
        settings.enableDialogueLayout()
        if semanticEnabled != settings.contextualCorrection {
            semanticEnabled = settings.contextualCorrection
            resetLearning()
            pipeline.updateHints(recognitionHints())
        }
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.persist()
        }
    }

    func toggleRecording() {
        cancelLanguageStart()
        guard !isBusy else { return }
        Task {
            if isRecording { await stop() } else { await start() }
        }
    }

    func start(testAudioFile: URL? = nil) async {
        cancelLanguageStart()
        guard captureState == .idle, !isDemo else { return }
        guard writable else {
            errorMessage = "歷史紀錄需要先修復，目前無法開始收音。請先匯出內容，並在設定中開啟資料夾檢查原檔。"
            return
        }
        captureState = .starting
        let startEpoch = UUID()
        captureEpoch = startEpoch
        errorMessage = nil
        infoMessage = nil
        do {
            let speechKey = try secretStore.read(settings.asrProvider) ?? ""
            guard !speechKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                captureState = .idle
                showsSettings = true
                errorMessage = "請先設定 \(settings.asrProvider.title) 的 API 金鑰。"
                return
            }
            var keys: [Provider: String] = [settings.asrProvider: speechKey]
            if settings.translationProvider != settings.asrProvider {
                keys[settings.translationProvider] = try secretStore.read(settings.translationProvider) ?? ""
            }
            let requiresTranslation = TranscriptLanguage.code(settings.sourceLanguage) == "auto"
                || TranscriptLanguage.code(settings.sourceLanguage) != settings.resolvedTargetLanguage
            guard !requiresTranslation || !(keys[settings.translationProvider] ?? "").isEmpty else {
                captureState = .idle
                showsSettings = true
                errorMessage = "請先設定 \(settings.translationProvider.title) 的翻譯 API 金鑰。"
                return
            }
            liveCoordinator.reset()
            resetLearning()
            sessionTranslationRequests = 0
            sessionContextRequests = 0
            // Streaming deltas are shown at once; drafts keep a 300 ms debounce.
            liveCoordinator.configure(sourceLanguage: settings.sourceLanguage, targetLanguage: settings.resolvedTargetLanguage,
                                      languagePair: settings.recognitionPair,
                                      publishesSourceImmediately: true)
            speechConversationID = currentConversationID
            if !isDemo { draftTranslator.configure(settings.draftEngineConfig) }
            if !isDemo, settings.draftEngineConfig.kind != .off {
                do {
                    try await draftTranslator.preflight(sourceLanguage: settings.sourceLanguage, targetLanguage: settings.resolvedTargetLanguage)
                    if let pair = settings.recognitionPair {
                        try await draftTranslator.preflight(sourceLanguage: pair.right, targetLanguage: pair.left)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The draft is a convenience; the cloud translation still runs per sentence.
                    infoMessage = "本機暫譯無法使用，定稿後仍會顯示正式譯文：\(error.localizedDescription)"
                }
            }
            guard captureEpoch == startEpoch, captureState == .starting else { return }
            // Recognition hints are sent before audio starts.
            try await pipeline.start(settings: settings, secrets: keys, hints: recognitionHints(),
                                     testAudioFile: testAudioFile)
            guard captureEpoch == startEpoch, captureState == .starting else {
                return
            }
            captureState = .listening
            persist()
        } catch {
            guard captureEpoch == startEpoch else { return }
            await pipeline.stop()
            guard captureEpoch == startEpoch else { return }
            liveCoordinator.reset()
            draftTranslator.reset()
            captureState = .idle
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        cancelLanguageStart()
        if let stopTask { await stopTask.value; return }
        guard captureState != .idle else { return }
        captureEpoch = UUID()
        captureState = .stopping
        let work = Task {
            await pipeline.stop()
            liveCoordinator.reset()
            draftTranslator.reset()
            partialText = ""
            audioLevel = 0
            captureState = .idle
            learnPendingRows(force: true)
            persist()
        }
        stopTask = work
        await work.value
        stopTask = nil
    }

    func newConversation() {
        cancelLanguageStart()
        guard !isBusy else { return }
        navigationInProgress = true
        Task {
            defer { navigationInProgress = false }
            await stop()
            if currentConversation?.hasContent == false {
                partialText = ""
                return
            }
            let conversation = Conversation()
            resetLearning()
            conversations.append(conversation)
            currentConversationID = conversation.id
            partialText = ""
            infoMessage = nil
            persist()
        }
    }

    func selectConversation(_ id: UUID) {
        cancelLanguageStart()
        guard !isBusy, !settings.isIncognito else { return }
        navigationInProgress = true
        Task {
            defer { navigationInProgress = false }
            await stop()
            resetLearning()
            if let saved = archiveProjection.saved.first(where: { $0.id == id }),
               let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index] = saved
            }
            currentConversationID = id
            showsHistory = false
            partialText = ""
            persist()
        }
    }

    func renameCurrent(_ name: String) {
        guard let id = currentConversationID else { return }
        renameConversation(id, name: name)
    }

    func renameConversation(_ id: UUID, name: String) {
        guard historyReady, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let title = TranscriptLanguage.display(name).trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[index].name = title.isEmpty ? nil : title
        persist()
    }

    /// Called only after the conversation actions confirm the named deletion.
    func deleteConversation(_ id: UUID) {
        cancelLanguageStart()
        guard !isBusy, historyReady, conversations.contains(where: { $0.id == id }) else { return }
        navigationInProgress = true
        Task {
            defer { navigationInProgress = false }
            let deletingCurrent = currentConversationID == id
            if deletingCurrent { await stop() }
            if deletingCurrent { resetLearning() }
            queue.removeAll { $0.conversationID == id }
            conversations.removeAll { $0.id == id }
            if deletingCurrent {
                if let next = conversations.max(by: { $0.updatedAt < $1.updatedAt }) {
                    currentConversationID = next.id
                } else {
                    let empty = Conversation()
                    conversations.append(empty)
                    currentConversationID = empty.id
                }
                speechConversationID = nil
                partialText = ""
            }
            // Already-running callbacks locate their original conversation ID.
            // Removing it prevents late results from recreating deleted history.
            persist()
        }
    }

    func receiveFinal(_ text: String) {
        receiveTranscript(SpeechUpdate(id: UUID().uuidString, text: text, isFinal: true))
    }

    /// Captured/imported updates use the same coordinator callbacks as live speech.
    /// The live pipeline retains its separate session-conversation binding.
    func receiveTranscript(_ update: SpeechUpdate) {
        speechConversationID = currentConversationID
        liveCoordinator.configure(sourceLanguage: settings.sourceLanguage, targetLanguage: settings.resolvedTargetLanguage,
                                  languagePair: settings.recognitionPair)
        liveCoordinator.receive(update)
    }

    private func upsertSpeechSegment(_ segment: TranscriptSegment) {
        guard let id = speechConversationID,
              let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let si = conversations[index].segments.firstIndex(where: { $0.id == segment.id }) {
            let old = conversations[index].segments[si]
            // Same identity for interim/local/final. A late local callback cannot
            // overwrite either the recognition boundary or a completed cloud result.
            guard old.status != .complete,
                  !(old.isRecognitionFinal && !segment.isRecognitionFinal) else { return }
            conversations[index].segments[si] = segment
        } else {
            conversations[index].segments.append(segment)
        }
        conversations[index].updatedAt = Date()
        liveContentRevision &+= 1
        if segment.isRecognitionFinal, !unlearned.contains(segment.id) {
            unlearned.append(segment.id)
            learnPendingRows(force: false)
        }
    }

    private func groundedSemanticSnapshot(_ value: SemanticSnapshot, in segments: [TranscriptSegment]) -> SemanticSnapshot {
        var copy = value
        copy.terms = value.groundedTerms(in: segments)
        copy.topic = value.groundedTopic(in: segments)
        if copy.topic.isEmpty { copy.topicEvidence = nil }
        copy.application = nil
        return copy
    }

    // MARK: - Recognition hints and vocabulary learning

    /// Recognition context (0.6.4): the scene sentence as the transcription
    /// prompt, and as keywords the glossary, pinned words and this
    /// conversation's rare terms (at most 12). Nothing else carries over from
    /// earlier conversations, so one lecture's words cannot bias the next meeting.
    func recognitionHints() -> RecognitionHints {
        var terms: [String] = vocabulary.filter(\.pinned).map(\.text)
        var prompt: [String] = []
        if settings.recognitionLocales.contains(where: { TranscriptLanguage.code($0) == "zh-TW" }) {
            prompt.append("中文請以台灣繁體字書寫。")
        }
        if settings.contextualCorrection, let conversation = currentConversation,
           let snapshot = conversation.semanticEnvironment?.latest {
            terms += snapshot.groundedTerms(in: conversation.segments).prefix(VocabularyLearner.maximumTerms).map(\.text)
            let scene = snapshot.groundedTopic(in: conversation.segments)
            if !scene.isEmpty { prompt.append(scene) }
        }
        return RecognitionHints(keywords: RecognitionHints.keywords(settings.glossary, terms: terms, limit: 40),
                                prompt: prompt.joined(separator: " "))
    }


    private func resetLearning() {
        learningEpoch = UUID()
        learningTask?.cancel()
        learningTask = nil
        unlearned = []
        learningInterval = LearningBudget.baseInterval
        lastLearningStart = nil
        isAnalyzingSemantics = false
        semanticError = nil
        semanticActivity = ""
    }

    /// Analyze a few finalized rows at a time; at stop, also a smaller remainder.
    private func learnPendingRows(force: Bool) {
        guard !isDemo, writable, historyReady, settings.contextualCorrection, learningTask == nil,
              let conversationID = speechConversationID ?? currentConversationID,
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let rows = conversation.segments.filter { unlearned.contains($0.id) && $0.isRecognitionFinal }
        // First update after 3 sentences so the scene is known early; then every
        // `learningInterval` sentences, at least a minute apart, at most 30 per hour.
        let first = conversation.semanticEnvironment?.latest == nil
        let threshold = force ? 2 : (first ? LearningBudget.firstAfter : learningInterval)
        guard rows.count >= threshold else { return }
        let now = Date()
        learningStarts.removeAll { now.timeIntervalSince($0) > 3_600 }
        guard learningStarts.count < LearningBudget.perHour else { return }
        if !force, !first, let last = lastLearningStart, now.timeIntervalSince(last) < LearningBudget.minimumGap { return }
        lastLearningStart = now
        learningStarts.append(now)
        let batch = Array(rows.prefix(VocabularyLearner.batchSize * 2))
        unlearned.removeAll { id in batch.contains { $0.id == id } }
        analyze(batch, in: conversationID)
    }

    /// Manual action from the vocabulary panel: analyze the latest rows again.
    func refreshSemanticEnvironment() {
        guard !isDemo, settings.contextualCorrection, learningTask == nil,
              let conversation = currentConversation else { return }
        let rows = Array(conversation.segments.filter(\.isRecognitionFinal).suffix(VocabularyLearner.batchSize * 2))
        guard !rows.isEmpty else { return }
        analyze(rows, in: conversation.id)
    }

    private func analyze(_ rows: [TranscriptSegment], in conversationID: UUID) {
        let sources = rows.map { LearningSource(segmentID: $0.id, text: $0.sourceCopyText, language: $0.resolvedSourceLanguage) }
            .filter { !$0.text.isEmpty }
        guard !sources.isEmpty else { return }
        let revisions = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.revision) })
        let conversation = conversations.first { $0.id == conversationID }
        let previous = conversation?.semanticEnvironment?.latest.map { groundedSemanticSnapshot($0, in: conversation?.segments ?? []) }
        let knownTerms = previous?.terms.map(\.text) ?? []
        let knownTopic = previous?.topic ?? ""
        let epoch = learningEpoch
        let requestSettings = settings
        isAnalyzingSemantics = true
        semanticActivity = "正在整理情境與詞彙"
        sessionContextRequests += 1
        semanticError = nil
        learningTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if learningEpoch == epoch {
                    learningTask = nil
                    isAnalyzingSemantics = false
                    if captureState == .listening { learnPendingRows(force: false) }
                }
            }
            do {
                let key = try secretStore.read(requestSettings.translationProvider) ?? ""
                let result = try await learner.analyze(sources, knownTopic: knownTopic, knownTerms: knownTerms,
                                                       settings: requestSettings, key: key)
                guard !Task.isCancelled, learningEpoch == epoch else { return }
                apply(result, to: conversationID, revisions: revisions, previous: previous, settings: requestSettings)
            } catch is CancellationError {
            } catch {
                guard learningEpoch == epoch else { return }
                semanticError = error.localizedDescription
                semanticActivity = "詞彙更新未完成，收音會繼續"
            }
        }
    }

    private func apply(_ result: LearningResult, to conversationID: UUID, revisions: [UUID: Int],
                       previous: SemanticSnapshot?, settings requestSettings: AppSettings) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        // 1. Clear mishearings: change only rows unchanged since the request.
        var corrected: [TranscriptSegment] = []
        var correctionNotes: [String: String] = [:]
        if !settings.isIncognito {
            for correction in result.corrections {
                guard let si = conversations[ci].segments.firstIndex(where: { $0.id == correction.segmentID }),
                      conversations[ci].segments[si].revision == revisions[correction.segmentID],
                      conversations[ci].segments[si].source.contains(correction.wrong) else { continue }
                var row = conversations[ci].segments[si]
                row.source = row.source.replacingOccurrences(of: correction.wrong, with: correction.right)
                row.revision += 1
                row.status = .pending
                row.error = nil
                conversations[ci].segments[si] = row
                correctionNotes[correction.right] = correction.wrong
                corrected.append(row)
            }
        }
        // 1b. Homophones of known terms (no model judgement involved).
        if !settings.isIncognito {
            let known = result.terms.map(\.term) + (previous?.terms.map(\.text) ?? []) + vocabulary.filter(\.pinned).map(\.text)
            for (id, revision) in revisions {
                guard let si = conversations[ci].segments.firstIndex(where: { $0.id == id }),
                      conversations[ci].segments[si].revision == revision + (corrected.contains { $0.id == id } ? 1 : 0),
                      conversations[ci].segments[si].resolvedSourceLanguage == "zh-TW" else { continue }
                let fixes = MandarinSound.homophoneFixes(in: conversations[ci].segments[si].source, terms: known)
                guard !fixes.isEmpty else { continue }
                var row = conversations[ci].segments[si]
                for fix in fixes {
                    row.source = row.source.replacingOccurrences(of: fix.wrong, with: fix.right)
                    correctionNotes[fix.right] = fix.wrong
                }
                if !corrected.contains(where: { $0.id == id }) { row.revision += 1 }
                row.status = .pending
                row.error = nil
                conversations[ci].segments[si] = row
                corrected.removeAll { $0.id == id }
                corrected.append(row)
            }
        }
        // 2. Scene and terms replace the previous state (no accumulation).
        let segments = conversations[ci].segments
        let batchRows = segments.filter { revisions[$0.id] != nil }
        var terms: [SemanticTerm] = []
        for learned in result.terms.prefix(VocabularyLearner.maximumTerms) {
            if let wrong = correctionNotes[learned.term],
               let row = batchRows.first(where: { SemanticEvidence.containsLiteral(learned.term, in: $0.sourceCopyText) }) {
                terms.append(SemanticTerm(text: learned.term,
                    evidence: SemanticEvidence(segmentID: row.id, quote: learned.term, wasRecognitionFinal: true),
                    correction: SemanticCorrection(surface: wrong, rationale: VocabularyLearner.appliedRationale)))
            } else if !learned.heard.isEmpty,
                      let row = batchRows.first(where: { $0.sourceCopyText.contains(learned.heard) }) {
                terms.append(SemanticTerm(text: learned.term,
                    evidence: SemanticEvidence(segmentID: row.id, quote: learned.heard, wasRecognitionFinal: true),
                    correction: SemanticCorrection(surface: learned.heard, rationale: VocabularyLearner.spellingRationale)))
            } else if let row = batchRows.first(where: { SemanticEvidence.containsLiteral(learned.term, in: $0.sourceCopyText) }) {
                terms.append(SemanticTerm(text: learned.term,
                    evidence: SemanticEvidence(segmentID: row.id, quote: learned.term, wasRecognitionFinal: true)))
            } else if let kept = previous?.terms.first(where: { $0.text.lowercased() == learned.term.lowercased() }) {
                terms.append(kept)
            }
        }
        var topic = result.scene.isEmpty ? (previous?.topic ?? "") : result.scene
        var topicEvidence = previous?.topicEvidence
        if topic != previous?.topic {
            if let row = batchRows.last(where: { !$0.sourceCopyText.isEmpty }) {
                topicEvidence = SemanticEvidence(segmentID: row.id, quote: String(row.sourceCopyText.prefix(24)),
                                                 wasRecognitionFinal: true)
            } else { topic = previous?.topic ?? "" }
        }
        let snapshot = SemanticSnapshot(topic: topic, topicEvidence: topic.isEmpty ? nil : topicEvidence, terms: terms,
                                        provider: requestSettings.translationProvider,
                                        model: VocabularyLearner.model(for: requestSettings))
        let changed = previous.map { $0.topic != snapshot.topic || $0.terms.map(\.text) != snapshot.terms.map(\.text) } ?? true
        // Back off while the scene holds still; return to the base rate when it moves.
        learningInterval = changed ? LearningBudget.baseInterval : min(learningInterval * 2, LearningBudget.maximumInterval)
        if changed, !snapshot.terms.isEmpty || !snapshot.topic.isEmpty {
            var environment = conversations[ci].semanticEnvironment ?? SemanticEnvironment()
            environment.snapshots.append(snapshot)
            environment.snapshots = Array(environment.snapshots.suffix(40))
            conversations[ci].semanticEnvironment = environment
        }
        // 3. Record terms for the user to pin later (not sent automatically), then update live hints.
        if !settings.isIncognito { Vocabulary.merge(terms.map(\.text), into: &vocabulary) }
        if conversationID == speechConversationID { pipeline.updateHints(recognitionHints()) }

        semanticActivity = corrected.isEmpty
            ? (topic.isEmpty ? "尚未判斷出情境" : "情境與詞彙已更新")
            : "已依上下文修正 \(corrected.count) 句的辨識錯字"
        liveContentRevision &+= 1
        if corrected.isEmpty { persist() } else { corrected.forEach(translateRecognizedSegment) }
    }

    func removeVocabulary(_ entry: VocabularyEntry) {
        vocabulary.removeAll { $0.id == entry.id }
        persist()
        if captureState == .listening { pipeline.updateHints(recognitionHints()) }
    }

    func togglePinned(_ entry: VocabularyEntry) {
        guard let index = vocabulary.firstIndex(where: { $0.id == entry.id }) else { return }
        vocabulary[index].pinned.toggle()
        persist()
    }

    private func translateRecognizedSegment(_ segment: TranscriptSegment) {
        guard let id = speechConversationID else { return }
        persist()
        if !queue.contains(where: { $0.conversationID == id && $0.segmentID == segment.id }) {
            queue.append(WorkItem(conversationID: id, segmentID: segment.id))
        }
        drainQueue()
    }

    func revise(_ segment: TranscriptSegment, source: String) {
        guard let id = currentConversationID,
              let ci = conversations.firstIndex(where: { $0.id == id }),
              let si = conversations[ci].segments.firstIndex(where: { $0.id == segment.id }) else { return }
        let clean = TranscriptLanguage.display(source.trimmingCharacters(in: .whitespacesAndNewlines),
                                              language: conversations[ci].segments[si].resolvedSourceLanguage)
        guard !clean.isEmpty else { return }
        if clean != conversations[ci].segments[si].source {
            conversations[ci].segments[si].contextualRevision = nil
            conversations[ci].segments[si].english = ""
            conversations[ci].segments[si].chinese = ""
            conversations[ci].segments[si].translatedText = nil
        }
        conversations[ci].segments[si].source = clean
        let target = settings.target(for: conversations[ci].segments[si].resolvedSourceLanguage)
        if conversations[ci].segments[si].resolvedTargetLanguage != target {
            conversations[ci].segments[si].translatedText = nil
        }
        conversations[ci].segments[si].targetLanguage = target
        conversations[ci].segments[si].revision += 1
        conversations[ci].segments[si].status = .pending
        conversations[ci].segments[si].error = nil
        conversations[ci].updatedAt = Date()
        persist()
        if !queue.contains(where: { $0.conversationID == id && $0.segmentID == segment.id }) {
            queue.append(WorkItem(conversationID: id, segmentID: segment.id))
        }
        drainQueue()
    }

    func retry(_ segment: TranscriptSegment) {
        guard let current = currentConversation?.segments.first(where: { $0.id == segment.id }) else { return }
        revise(current, source: current.source)
    }

    func polish(_ segment: TranscriptSegment) {
        guard let id = currentConversationID,
              let ci = conversations.firstIndex(where: { $0.id == id }),
              let si = conversations[ci].segments.firstIndex(where: { $0.id == segment.id }),
              conversations[ci].segments[si].status == .complete,
              !conversations[ci].segments[si].translatedCopyText.isEmpty,
              conversations[ci].segments[si].resolvedSourceLanguage != conversations[ci].segments[si].resolvedTargetLanguage else { return }
        conversations[ci].segments[si].revision += 1
        conversations[ci].segments[si].status = .pending
        conversations[ci].segments[si].error = nil
        persist()
        queue.append(WorkItem(conversationID: id, segmentID: segment.id, isPolish: true))
        drainQueue()
    }

    private func drainQueue() {
        guard !isDemo else { return }
        // Each finished utterance launches its own cloud request.
        // Do not make later utterances wait for one long final result.
        // Bound public-API concurrency; interim/local translation is independent.
        while translationTasks.count < 3, !queue.isEmpty {
            let work = queue.removeFirst()
            guard let ci = conversations.firstIndex(where: { $0.id == work.conversationID }),
                  let si = conversations[ci].segments.firstIndex(where: { $0.id == work.segmentID }) else { continue }
            let segment = conversations[ci].segments[si]
            // The three preceding finalized sentences and their translations
            // go along as context. Pauses
            // split one thought across rows; context keeps the Chinese readable.
            let reference = Array(conversations[ci].segments[..<si].filter { $0.isRecognitionFinal && !$0.source.isEmpty }.suffix(3))
            let showPartials = segment.contextualRevision == nil || segment.translatedCopyText.isEmpty
            var pairSettings = settings
            pairSettings.sourceLanguage = TranscriptLanguage.locale(segment.resolvedSourceLanguage)
            pairSettings.targetLanguage = segment.resolvedTargetLanguage
            pairSettings.bidirectional = false // This row already owns its detected direction.
            let requestSettings = pairSettings
            let environment = settings.contextualCorrection
                ? conversations[ci].semanticEnvironment?.latest.map {
                    groundedSemanticSnapshot($0, in: conversations[ci].segments)
                } : nil
            let requestID = UUID()
            if segment.resolvedSourceLanguage != requestSettings.resolvedTargetLanguage { sessionTranslationRequests += 1 }
            translationTasks[requestID] = Task { [weak self] in
                guard let self else { return }
                defer {
                    translationTasks[requestID] = nil
                    drainQueue()
                }
                do {
                    let needsRemote = segment.resolvedSourceLanguage != requestSettings.resolvedTargetLanguage
                    let key = needsRemote ? (try secretStore.read(requestSettings.translationProvider) ?? "") : ""
                    guard !needsRemote || !key.isEmpty else { throw AppError.missingKey(requestSettings.translationProvider.title) }
                    let partial: TranslationPartialHandler = { [weak self] value in
                        if showPartials {
                            await self?.applyCloudPartial(value, work: work, revision: segment.revision)
                        }
                    }
                    let result: TranslationResult
                    if work.isPolish {
                        result = try await translator.polish(source: segment.source, english: segment.english,
                                                             chinese: segment.chinese, existingTarget: segment.translatedCopyText,
                                                             settings: requestSettings, key: key,
                                                             environment: environment,
                                                             onPartial: partial)
                    } else {
                        result = try await translator.translate(source: segment.source, context: reference,
                                                                 settings: requestSettings, key: key,
                                                                 environment: environment, onPartial: partial)
                    }
                    apply(result, work: work, revision: segment.revision)
                    persist()
                } catch {
                    update(work: work, revision: segment.revision) { item in
                        item.status = .failed
                        item.error = error.localizedDescription
                    }
                }
                persist()
            }
        }
    }

    private func applyCloudPartial(_ result: TranslationResult, work: WorkItem, revision: Int) {
        guard let ci = conversations.firstIndex(where: { $0.id == work.conversationID }),
              let si = conversations[ci].segments.firstIndex(where: { $0.id == work.segmentID }),
              conversations[ci].segments[si].revision == revision,
              conversations[ci].segments[si].status != .complete else { return }
        // iOS appends cloud chunks to the same Dialog ID. The public-provider
        // decoder supplies an accumulated target snapshot, never a final flag.
        if !result.english.isEmpty { conversations[ci].segments[si].english = result.english }
        if !result.chinese.isEmpty { conversations[ci].segments[si].chinese = ChineseScript.traditional(result.chinese) }
        conversations[ci].segments[si].translatedText = result.translatedText.map { result.targetLanguage.map(TranscriptLanguage.code) == "zh-TW" ? TaiwanVocabulary.apply($0) : $0 }
        conversations[ci].segments[si].sourceLanguage = result.sourceLanguage ?? conversations[ci].segments[si].sourceLanguage
        conversations[ci].segments[si].targetLanguage = result.targetLanguage ?? conversations[ci].segments[si].targetLanguage
        conversations[ci].segments[si].status = .pending
        conversations[ci].segments[si].error = nil
        conversations[ci].updatedAt = Date()
        liveContentRevision &+= 1
        // Save at completion/error/navigation, not once per generated token.
    }

    private func apply(_ result: TranslationResult, work: WorkItem, revision: Int) {
        update(work: work, revision: revision) { item in
            item.source = TranscriptLanguage.display(result.source.isEmpty ? item.source : result.source,
                                                    language: result.sourceLanguage ?? item.resolvedSourceLanguage)
            if !result.english.isEmpty { item.english = result.english }
            if !result.chinese.isEmpty { item.chinese = ChineseScript.traditional(result.chinese) }
            item.translatedText = result.translatedText.map { result.targetLanguage.map(TranscriptLanguage.code) == "zh-TW" ? TaiwanVocabulary.apply($0) : $0 }
            item.sourceLanguage = result.sourceLanguage ?? item.sourceLanguage
            item.targetLanguage = result.targetLanguage ?? item.targetLanguage
            item.terms = result.terms
            item.status = .complete
            item.error = nil
        }
        liveContentRevision &+= 1
    }

    private func update(work: WorkItem, revision: Int, change: (inout TranscriptSegment) -> Void) {
        guard let ci = conversations.firstIndex(where: { $0.id == work.conversationID }),
              let si = conversations[ci].segments.firstIndex(where: { $0.id == work.segmentID }),
              conversations[ci].segments[si].revision == revision else { return }
        change(&conversations[ci].segments[si])
        conversations[ci].updatedAt = Date()
    }

    private func recoverPendingTranslations() {
        for ci in conversations.indices {
            for si in conversations[ci].segments.indices where conversations[ci].segments[si].status == .pending || !conversations[ci].segments[si].isRecognitionFinal {
                let interrupted = !conversations[ci].segments[si].isRecognitionFinal
                conversations[ci].segments[si].recognitionFinal = true
                conversations[ci].segments[si].status = .failed
                conversations[ci].segments[si].error = interrupted
                    ? "上次收音在定稿前結束，已保留暫稿；可編輯或重新翻譯。"
                    : "上次翻譯尚未完成，可按重試。原始辨識已保留。"
            }
        }
    }

    func prepareKeyDraft(_ provider: Provider) {
        let store = secretStore
        let demo = isDemo
        do {
            try keyDrafts.prepare(provider) { demo ? nil : try store.read(provider) }
        } catch { errorMessage = error.localizedDescription }
    }

    func updateKeyDraft(_ value: String, provider: Provider) {
        guard keyDrafts.value(for: provider) != value else { return }
        keyDrafts.edit(value, for: provider)
        modelDirectory.invalidate(provider)
    }

    @discardableResult
    func saveKey(_ value: String, provider: Provider) -> Bool {
        guard !isDemo else { return false }
        updateKeyDraft(value, provider: provider)
        do {
            try secretStore.save(value, for: provider)
            keyDrafts.didSave(value, for: provider)
            errorMessage = nil
            infoMessage = "\(provider.title) 金鑰已儲存。"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func saveKeyDrafts() -> Bool {
        guard !isDemo else { return true }
        for provider in Provider.allCases where keyDrafts.hasChanges(provider) {
            guard saveKey(keyDrafts.value(for: provider), provider: provider) else { return false }
        }
        return true
    }

    func export(_ conversation: Conversation, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.title = "匯出雙語逐字稿"
        panel.nameFieldStringValue = TranscriptExporter.filename(conversation, format: format)
        panel.allowedContentTypes = format == .markdown ? [UTType(filenameExtension: "md") ?? .plainText] : [.plainText]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(TranscriptExporter.content(conversation, format: format).utf8).write(to: url, options: [])
                self?.infoMessage = "已匯出 \(url.lastPathComponent)"
            } catch { self?.errorMessage = "匯出失敗：\(error.localizedDescription)" }
        }
    }

    func revealData() { NSWorkspace.shared.open(dataDirectory) }

    func persist() {
        guard !isDemo, writable, historyReady else { return }
        revision += 1
        let saved = archiveProjection.project(conversations, incognito: settings.isIncognito)
        let selected = saved.contains(where: { $0.id == currentConversationID })
            ? currentConversationID : saved.first?.id
        let archive = TranscriptArchive(revision: revision, settings: settings,
                                        conversations: saved, currentConversationID: selected,
                                        vocabulary: vocabulary)
        do {
            try store.save(archive)
            archiveProjection.commit(observed: conversations, saved: saved)
        }
        catch {
            writable = false
            errorMessage = "儲存失敗，已停止後續自動寫入以保留上一份紀錄。請先匯出目前逐字稿，再檢查硬碟：\(error.localizedDescription)"
            if captureState == .listening { Task { await self.stop() } }
        }
    }

    private func installDemo() {
        var conversation = Conversation()
        conversation.name = "研究討論 · 示範資料"
        let samples = [
            ("我們先看這個系統的共振頻率，再比較不同阻尼條件下的響應。",
             "Let's examine the system's resonance frequency, then compare its response under different damping conditions.", ["resonance frequency", "damping"]),
            ("如果濾波器的截止頻率設得太低，高頻訊號就會跟著被削弱。",
             "If the filter's cutoff frequency is set too low, the high-frequency signal will also be attenuated.", ["cutoff frequency", "attenuation"]),
            ("接下來用頻譜分析確認，這個峰值是訊號本身，還是量測雜訊。",
             "Next, we'll use spectral analysis to determine whether this peak comes from the signal itself or from measurement noise.", ["spectral analysis", "measurement noise"])
        ]
        for (index, sample) in samples.enumerated() {
            var segment = TranscriptSegment(original: sample.0, createdAt: Date().addingTimeInterval(Double(index - 3) * 15))
            segment.english = sample.1
            segment.chinese = sample.0
            segment.terms = sample.2
            segment.status = .complete
            let start = segment.createdAt
            segment.speechSpan = SpeechSpan(startedAt: start, endedAt: start.addingTimeInterval(Double(6 + index * 2) + 0.4))
            conversation.segments.append(segment)
        }
        // Demo environment: topic, terms and one fix made from later context.
        let rows = conversation.segments
        func evidence(_ row: Int, _ quote: String) -> SemanticEvidence {
            SemanticEvidence(segmentID: rows[row].id, quote: quote, wasRecognitionFinal: true)
        }
        conversation.semanticEnvironment = SemanticEnvironment(snapshots: [SemanticSnapshot(
            topic: "研究討論：比較系統共振頻率、阻尼與濾波器截止頻率，並以頻譜分析判斷峰值來源", topicEvidence: evidence(0, "共振頻率"),
            terms: [SemanticTerm(text: "共振頻率", evidence: evidence(0, "共振頻率")),
                    SemanticTerm(text: "阻尼", evidence: evidence(0, "阻尼")),
                    SemanticTerm(text: "截止頻率", evidence: evidence(1, "截止頻率")),
                    SemanticTerm(text: "濾波器", evidence: evidence(1, "濾波器")),
                    SemanticTerm(text: "頻譜分析", evidence: evidence(2, "頻譜分析"),
                                 correction: SemanticCorrection(surface: "評譜分析", rationale: "依上下文修正辨識錯字"))],
            provider: .openAI, model: "gpt-6-luna")])
        vocabulary = [VocabularyEntry(text: "頻譜分析", count: 4, pinned: true),
                      VocabularyEntry(text: "共振頻率", count: 3), VocabularyEntry(text: "截止頻率", count: 2),
                      VocabularyEntry(text: "阻尼振盪器", count: 2), VocabularyEntry(text: "傅立葉轉換", count: 1)]
        conversations = [conversation]
        currentConversationID = conversation.id
    }

    private enum AppError: LocalizedError {
        case missingKey(String)
        var errorDescription: String? {
            switch self { case .missingKey(let provider): "請在設定中填入 \(provider) API 金鑰，再重試翻譯。" }
        }
    }
}

private actor ArchiveLoader {
    func load(_ store: ArchiveStore) throws -> TranscriptArchive? { try store.load() }
}
