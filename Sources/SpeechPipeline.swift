import Foundation

/// One recognizer callback: interim text (isFinal false) or a finished
/// utterance (isFinal true), keyed by an utterance ID.
struct SpeechUpdate: Sendable, Equatable {
    let id: String
    let text: String
    let isFinal: Bool
    var language: String? = nil
    var addsSentencePunctuation = false
    var speechSpan: SpeechSpan? = nil
}

/// Provider offsets are positions in the submitted stream. Gemini reports
/// offsets; keep capture dates so a row can show when it was spoken.
struct SpeechCaptureClock {
    private struct Anchor {
        let frame: Double
        let date: Date
    }

    let sampleRate: Double
    private var frames = 0
    private var anchors: [Anchor] = []

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    mutating func append(frames count: Int, startedAt observedStart: Date) -> ClosedRange<Date> {
        let duration = Double(count) / sampleRate
        let continuousStart = date(at: Double(frames) / sampleRate)
        let start = continuousStart.map { observedStart.timeIntervalSince($0) > 0.25 ? observedStart : $0 }
            ?? observedStart
        if continuousStart != start {
            anchors.append(Anchor(frame: Double(frames), date: start))
        }
        frames += count
        return start...start.addingTimeInterval(duration)
    }

    func date(at seconds: Double, endBoundary: Bool = false) -> Date? {
        let requestedFrame = seconds * sampleRate
        guard requestedFrame.isFinite, seconds >= 0 else { return nil }
        let rounded = requestedFrame.rounded()
        let frame = abs(requestedFrame - rounded) < 0.001 ? rounded : requestedFrame
        guard frame <= Double(frames),
              let origin = anchors.last(where: { endBoundary && frame > 0 ? $0.frame < frame : $0.frame <= frame })
        else { return nil }
        return origin.date.addingTimeInterval((frame - origin.frame) / sampleRate)
    }

    func geminiSpan(_ transcription: [String: Any]) -> SpeechSpan? {
        guard let start = Self.duration(transcription["startOffset"]), let began = date(at: start) else { return nil }
        let end = Self.duration(transcription["endOffset"]).flatMap { date(at: $0, endBoundary: true) }
        return SpeechSpan(startedAt: began, endedAt: end.flatMap { $0 >= began ? $0 : nil })
    }

    private static func duration(_ value: Any?) -> Double? {
        guard let duration = value as? String, duration.hasSuffix("s") else { return nil }
        return Double(duration.dropLast())
    }
}

/// OpenAI transcription events keyed by `item_id`. Deltas arrive before the
/// client commits; `completed` carries the final text of one committed item.
struct OpenAITranscriptBuffer: Sendable {
    private(set) var partials: [String: String] = [:]
    private var order: [String] = []
    private var completedIDs = Set<String>()
    private var committedIDs = Set<String>()
    private var deltaEvents: [String: Set<String>] = [:]
    private var closed = false

    /// Text received for items that were not committed yet.
    var hasUncommittedText: Bool {
        partials.contains { !committedIDs.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    var hasOpenItems: Bool { !partials.isEmpty }

    mutating func committed(_ id: String) {
        guard !id.isEmpty else { return }
        committedIDs.insert(id)
        if !order.contains(id) { order.append(id) }
    }

    mutating func delta(_ text: String, id: String, eventID: String? = nil) -> SpeechUpdate? {
        guard !closed, !id.isEmpty, !text.isEmpty, !completedIDs.contains(id) else { return nil }
        if let eventID, !eventID.isEmpty, !deltaEvents[id, default: []].insert(eventID).inserted { return nil }
        if !order.contains(id) { order.append(id) }
        let snapshot = (partials[id] ?? "") + text
        partials[id] = snapshot
        return SpeechUpdate(id: id, text: snapshot, isFinal: false)
    }

    mutating func completed(_ text: String, id: String) -> SpeechUpdate? {
        guard !closed, !id.isEmpty, completedIDs.insert(id).inserted else { return nil }
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (partials[id] ?? "") : text
        partials.removeValue(forKey: id)
        deltaEvents.removeValue(forKey: id)
        order.removeAll { $0 == id }
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SpeechUpdate(id: id, text: final, isFinal: true)
    }

    /// At stop: every item still showing text becomes final with what was heard.
    mutating func drainUnfinished() -> [SpeechUpdate] {
        guard !closed else { return [] }
        closed = true
        let updates = order.compactMap { id -> SpeechUpdate? in
            guard let text = partials[id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SpeechUpdate(id: id, text: text, isFinal: true)
        }
        partials.removeAll()
        order.removeAll()
        return updates
    }
}

/// The dedicated Gemini transcript protocol has no item ID; keep one local ID through its interim/final pair.
struct GeminiTranscriptBuffer: Sendable {
    private(set) var id = UUID().uuidString
    private(set) var preview = ""
    private var closed = false

    mutating func interim(_ text: String) -> SpeechUpdate? {
        guard !closed, !text.isEmpty, text != preview else { return nil }
        preview = text
        return SpeechUpdate(id: id, text: text, isFinal: false)
    }

    mutating func completed(_ text: String) -> SpeechUpdate? {
        guard !closed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let update = SpeechUpdate(id: id, text: text, isFinal: true)
        preview = ""
        id = UUID().uuidString
        return update
    }

    mutating func drainUnfinished() -> SpeechUpdate? {
        guard !closed else { return nil }
        let update = completed(preview)
        closed = true
        return update
    }
}

/// Recognition hints: keywords and a scene prompt sent before audio starts.
struct RecognitionHints: Equatable, Sendable {
    var keywords: [String] = []
    var prompt = ""

    static func keywords(_ text: String, terms: [String], limit: Int = 60) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；\n\r")
        var seen = Set<String>()
        return Array((text.components(separatedBy: separators) + terms).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter {
            !$0.isEmpty && $0.count <= 80 && !$0.contains("<") && !$0.contains(">")
                && !$0.contains("\n") && !$0.contains("\r")
                && seen.insert($0.lowercased()).inserted
        }.prefix(limit))
    }
}

/// Text-aware endpointing: a pause right after a word that cannot end a
/// sentence is usually the speaker searching for the next word, not the end.
enum DanglingEnd {
    static let english: Set<String> = ["the", "a", "an", "of", "to", "in", "on", "at", "for", "with", "from", "by",
        "and", "or", "but", "because", "if", "that", "which", "whose", "is", "are", "was", "were", "will", "would",
        "can", "could", "should", "must", "my", "your", "our", "their", "his", "her", "its", "this", "these", "those",
        "very", "than", "as", "into", "about", "between", "when", "while", "where", "whether"]
    static let chinese = ["的", "和", "跟", "與", "或", "但", "但是", "因為", "所以", "如果", "就是", "然後", "在", "是", "把", "被", "對", "從", "而且", "還有"]

    static func isDangling(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, "?？!！".contains(last) { return false }
        while let last = trimmed.last, ".,，。、…;；:： ".contains(last) { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return false }
        if let last = trimmed.unicodeScalars.last, (0x4E00...0x9FFF).contains(last.value) {
            return chinese.contains { trimmed.hasSuffix($0) }
        }
        let words = trimmed.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map { $0.lowercased() }
        guard let word = words.last else { return false }
        // "there will be no …" continues; a bare "no" can end ("the answer is no") only after a noun phrase.
        if word == "no", words.count >= 2, ["be", "is", "are", "was", "were", "have", "has", "had"].contains(words[words.count - 2]) {
            return true
        }
        return english.contains(word)
    }
}

enum SpeechProtocol {
    /// The live model's language hints (ISO-639-1 plus zh-tw).
    static func openAILanguages(_ settings: AppSettings) -> [String] {
        settings.recognitionLocales.map {
            let language = TranscriptLanguage.code($0)
            return language == "zh-TW" ? "zh-tw" : language
        }
    }

    static func openAITranscription(settings: AppSettings, hints: RecognitionHints) -> [String: Any] {
        let model = settings.openAIASRModel
        var transcription: [String: Any] = ["model": model]
        let live = model.hasPrefix("gpt-live-transcribe")
        let whisper = model == "gpt-realtime-whisper"
        if live || whisper { transcription["delay"] = "low" }
        let languages = openAILanguages(settings)
        if whisper {
            // Realtime Whisper accepts a single language only; pairs use auto-detect.
            if languages.count == 1, let first = languages.first?.split(separator: "-").first {
                transcription["language"] = String(first)
            }
        } else if !languages.isEmpty {
            transcription["languages"] = languages
        }
        if !whisper {
            if !hints.keywords.isEmpty { transcription["keywords"] = hints.keywords }
            if !hints.prompt.isEmpty { transcription["prompt"] = hints.prompt }
        }
        return transcription
    }

    /// The client endpoints every OpenAI model the same way.
    static func openAIConfiguration(settings: AppSettings, hints: RecognitionHints) -> [String: Any] {
        ["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": openAITranscription(settings: settings, hints: hints),
            "turn_detection": NSNull()
        ]]]]
    }

    static func geminiConfiguration(settings: AppSettings, hints: RecognitionHints) -> [String: Any] {
        var transcription: [String: Any] = ["languageCodes": settings.recognitionLocales]
        if !hints.keywords.isEmpty { transcription["customVocabulary"] = hints.keywords }
        return ["setup": ["model": "models/\(settings.geminiASRModel)",
                           "generationConfig": ["responseModalities": ["TEXT"]],
                           "inputAudioTranscription": transcription]]
    }
}

/// Streams audio to the selected recognizer and publishes interim/final updates.
///
/// Flow: audio → UtteranceSegmenter (client
/// endpointing for OpenAI, gated audio) → OpenAI deltas/completed; Gemini keeps
/// service-side endpointing.
@MainActor
final class SpeechPipeline {
    var onUtterance: ((SpeechUpdate) -> Void)?
    var onError: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Diagnostics for tests: commits, discards and hint updates.
    var onDiagnostic: ((String) -> Void)?

    /// When text was received but no new text arrived for this long, end the turn.
    static let textStallSeconds: Double = 3.0
    /// A turn that produced no text at all for this long is background noise.
    static let silentTurnSeconds: Double = 6.0

    private enum Input: Sendable {
        case audio(Data, Date)
        case endTurn(reason: String)
    }

    private var capture: AudioCapture?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var input: AsyncStream<Input>.Continuation?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var token: UUID?
    private var settings = AppSettings()
    private var key = ""
    private var hints = RecognitionHints()
    private var pendingHints: RecognitionHints?
    private var segmenter = UtteranceSegmenter()
    private var buffer = OpenAITranscriptBuffer()
    private var geminiBuffer = GeminiTranscriptBuffer()
    private var captureClock = SpeechCaptureClock(sampleRate: 24_000)
    /// Spans of commits sent but not yet acknowledged with an item ID, in order.
    private var commitSpans: [SpeechSpan] = []
    private var itemSpans: [String: SpeechSpan] = [:]
    private var awaitingFinal = 0
    private var turnHasAudio = false
    private var turnOpenedAt: Date?
    private var lastTextAt: Date?
    private var stopping = false
    private var failed = false
    private var geminiVoicePending = false
    private var didSendAudio = false

    private(set) var stats = Stats()
    struct Stats: Sendable, Equatable {
        var audioSecondsSent: Double = 0
        var commits = 0
        var forcedCommits = 0
        var discards = 0
        var hintUpdates = 0
    }

    func start(settings: AppSettings, secrets: [Provider: String], hints: RecognitionHints,
               pauseSeconds: Double? = nil, testAudioFile: URL? = nil) async throws {
        await stop()
        guard settings.asrProvider != .claude else {
            throw ProviderFailure.message("Claude 只提供文字翻譯，請選 OpenAI 或 Gemini 辨識語音。")
        }
        let secret = (secrets[settings.asrProvider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw ProviderFailure.message("請先設定語音辨識服務 API 金鑰。") }
        let id = UUID()
        token = id
        self.settings = settings
        self.hints = hints
        key = secret
        pendingHints = nil
        stopping = false
        failed = false
        didSendAudio = false
        geminiVoicePending = false
        buffer = OpenAITranscriptBuffer()
        geminiBuffer = GeminiTranscriptBuffer()
        commitSpans = []
        itemSpans = [:]
        awaitingFinal = 0
        turnHasAudio = false
        turnOpenedAt = nil
        lastTextAt = nil
        stats = Stats()
        let sampleRate = settings.asrProvider == .openAI ? 24_000.0 : 16_000.0
        var configuration = UtteranceSegmenter.Configuration(sampleRate: sampleRate)
        configuration.endSilence = pauseSeconds ?? settings.pauseSegmentation.seconds
        segmenter = UtteranceSegmenter(configuration: configuration)
        captureClock = SpeechCaptureClock(sampleRate: sampleRate)
        let capture = AudioCapture()
        self.capture = capture

        var request: URLRequest
        if settings.asrProvider == .openAI {
            request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        } else {
            var components = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
            components.queryItems = [URLQueryItem(name: "key", value: secret)]
            request = URLRequest(url: components.url!)
        }
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.urlCache = nil
        urlConfiguration.timeoutIntervalForRequest = 20
        urlConfiguration.timeoutIntervalForResource = 24 * 60 * 60
        try APIEndpointPolicy.validate(request.url, provider: settings.asrProvider)
        let session = APIEndpointPolicy.session(configuration: urlConfiguration)
        self.session = session
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
        self.socket = socket
        socket.resume()

        let deadline = Task {
            do { try await Task.sleep(for: .seconds(18)) } catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        do {
            let setup = settings.asrProvider == .openAI
                ? SpeechProtocol.openAIConfiguration(settings: settings, hints: hints)
                : SpeechProtocol.geminiConfiguration(settings: settings, hints: hints)
            try await send(setup, on: socket)
            var ready = false
            while !ready {
                let object = try await receiveObject(on: socket)
                guard token == id, !Task.isCancelled else { throw CancellationError() }
                if let error = serviceError(object) { throw ProviderFailure.message(error) }
                ready = settings.asrProvider == .openAI
                    ? object["type"] as? String == "session.updated"
                    : object["setupComplete"] != nil
            }
            deadline.cancel()
            receiver = Task { [weak self] in await self?.receiveLoop(socket: socket, sessionID: id) }
            let pair = AsyncStream<Input>.makeStream(bufferingPolicy: .bufferingOldest(400))
            input = pair.continuation
            let continuation = pair.continuation
            capture.onTimedPCM = { [weak self] bytes, start in
                if case .dropped = continuation.yield(.audio(bytes, start)) {
                    Task { @MainActor [weak self] in
                        guard let self, self.token == id else { return }
                        self.fail("網路傳送跟不上收音，已停止以避免逐字稿缺漏。請檢查網路後重新開始。")
                    }
                }
            }
            capture.onLevel = { [weak self] level in
                Task { @MainActor [weak self] in
                    guard let self, self.token == id else { return }
                    self.onLevel?(level)
                }
            }
            capture.onError = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.token == id else { return }
                    self.fail(message)
                }
            }
            sender = Task { [weak self] in await self?.sendLoop(pair.stream, socket: socket, sessionID: id) }
            if settings.asrProvider == .openAI {
                watchdog = Task { [weak self] in await self?.watchTurns(sessionID: id) }
            }
            if let testAudioFile {
                try await capture.replayAudioFile(testAudioFile, sampleRate: sampleRate)
            } else {
                try await capture.start(source: settings.audioSource, sampleRate: sampleRate)
            }
            guard token == id, !Task.isCancelled else { throw CancellationError() }
        } catch {
            deadline.cancel()
            let cancelled = error is CancellationError || Task.isCancelled || token != id
            let message = networkMessage(error)
            await capture.stop()
            if token == id { await teardown() }
            if cancelled { throw CancellationError() }
            throw ProviderFailure.message(message)
        }
    }

    /// Replace keywords/prompt without pausing audio. Hints are refreshed
    /// during a session as the scene summary changes, applied
    /// between utterances and never awaited.
    func updateHints(_ new: RecognitionHints) {
        guard token != nil, settings.asrProvider == .openAI,
              settings.openAIASRModel != "gpt-realtime-whisper", new != hints else { return }
        pendingHints = new
        if !segmenter.isSpeaking { flushHints() }
    }

    func stop() async {
        guard let id = token else { return }
        stopping = true
        watchdog?.cancel()
        watchdog = nil
        let activeCapture = capture
        await activeCapture?.stop()
        guard token == id else { return }
        activeCapture?.onTimedPCM = nil
        activeCapture?.onLevel = nil
        activeCapture?.onError = nil
        if settings.asrProvider == .openAI {
            input?.yield(.endTurn(reason: "stop"))
        }
        input?.finish()
        input = nil
        let activeSocket = socket
        let drainDeadline = Task {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            activeSocket?.cancel(with: .goingAway, reason: nil)
        }
        if let sender { await sender.value }
        if let socket, !failed {
            do {
                if settings.asrProvider == .gemini, didSendAudio {
                    try await send(["realtimeInput": ["audioStreamEnd": true]], on: socket)
                }
                let end = ContinuousClock.now.advanced(by: .seconds(4))
                let minimum = ContinuousClock.now.advanced(by: .milliseconds(settings.asrProvider == .gemini ? 600 : 0))
                while ContinuousClock.now < end, token == id,
                      awaitingFinal > 0 || geminiVoicePending || !geminiBuffer.preview.isEmpty
                        || ContinuousClock.now < minimum {
                    try await Task.sleep(for: .milliseconds(80))
                }
            } catch {
                onWarning?("停止時未收到完整定稿；已保留目前辨識出的文字。")
            }
        }
        drainDeadline.cancel()
        guard token == id else { return }
        let tail: [SpeechUpdate]
        if settings.asrProvider == .openAI {
            tail = buffer.drainUnfinished()
        } else {
            tail = geminiBuffer.drainUnfinished().map { [$0] } ?? []
        }
        for var update in tail {
            update.speechSpan = itemSpans[update.id]
            onUtterance?(update)
        }
        if !tail.isEmpty { onWarning?("最後一段尚未收到服務定稿，已保留目前辨識文字，請核對尾句。") }
        await teardown()
    }

    // MARK: - Sending

    private func sendLoop(_ stream: AsyncStream<Input>, socket: URLSessionWebSocketTask, sessionID id: UUID) async {
        let openAI = settings.asrProvider == .openAI
        let packetBytes = Int(segmenter.configuration.sampleRate / 10) * 2
        var packet = Data()
        do {
            for await item in stream {
                guard token == id else { break }
                switch item {
                case .audio(let data, let start):
                    if openAI {
                        for event in segmenter.consume(data, startedAt: start) {
                            try await apply(event, packet: &packet, packetBytes: packetBytes, socket: socket)
                        }
                    } else {
                        _ = captureClock.append(frames: data.count / 2, startedAt: start)
                        if UtteranceSegmenter.levelDB(data) > -50 { geminiVoicePending = true }
                        didSendAudio = true
                        try await send(["realtimeInput": ["audio": ["data": data.base64EncodedString(),
                                                                    "mimeType": "audio/pcm;rate=16000"]]], on: socket)
                    }
                case .endTurn(let reason):
                    guard openAI else { continue }
                    var events = segmenter.forceEnd(at: Date())
                    if reason == "no-text" {
                        // Noise kept the level high but nothing was said: drop it.
                        events = events.map { if case .commit = $0 { return .discard } else { return $0 } }
                    }
                    if events.isEmpty, reason == "stop", turnHasAudio || buffer.hasUncommittedText {
                        try await apply(.commit(start: turnOpenedAt ?? Date(), end: Date(), forced: true),
                                        packet: &packet, packetBytes: packetBytes, socket: socket)
                    }
                    for event in events {
                        try await apply(event, packet: &packet, packetBytes: packetBytes, socket: socket)
                    }
                    onDiagnostic?("end-turn:\(reason)")
                }
            }
        } catch {
            if token == id, !stopping { fail(networkMessage(error)) }
        }
    }

    private func apply(_ event: UtteranceSegmenter.Event, packet: inout Data, packetBytes: Int,
                       socket: URLSessionWebSocketTask) async throws {
        switch event {
        case .audio(let data):
            if !turnHasAudio {
                turnHasAudio = true
                turnOpenedAt = Date()
                lastTextAt = nil
                onDiagnostic?("onset")
            }
            packet.append(data)
            while packet.count >= packetBytes {
                try await appendAudio(Data(packet.prefix(packetBytes)), socket: socket)
                packet.removeFirst(packetBytes)
            }
        case .commit(let start, let end, let forced):
            if !packet.isEmpty {
                try await appendAudio(packet, socket: socket)
                packet.removeAll(keepingCapacity: true)
            }
            guard turnHasAudio else { return }
            turnHasAudio = false
            turnOpenedAt = nil
            commitSpans.append(SpeechSpan(startedAt: start, endedAt: end))
            awaitingFinal += 1
            stats.commits += 1
            if forced { stats.forcedCommits += 1 }
            try await send(["type": "input_audio_buffer.commit", "event_id": "commit_" + UUID().uuidString], on: socket)
            onDiagnostic?("commit:\(forced ? "forced" : "pause")")
            flushHints()
        case .discard:
            packet.removeAll(keepingCapacity: true)
            guard turnHasAudio else { return }
            turnHasAudio = false
            turnOpenedAt = nil
            if buffer.hasUncommittedText {
                // The service already heard words in it: finalize instead of dropping them.
                commitSpans.append(SpeechSpan(startedAt: Date(), endedAt: Date(), isEstimated: true))
                awaitingFinal += 1
                stats.commits += 1
                try await send(["type": "input_audio_buffer.commit"], on: socket)
            } else {
                stats.discards += 1
                try await send(["type": "input_audio_buffer.clear"], on: socket)
                onDiagnostic?("discard")
            }
            flushHints()
        }
    }

    private func appendAudio(_ data: Data, socket: URLSessionWebSocketTask) async throws {
        didSendAudio = true
        stats.audioSecondsSent += Double(data.count / 2) / segmenter.configuration.sampleRate
        try await send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()], on: socket)
    }

    private func flushHints() {
        guard let new = pendingHints, let socket, token != nil else { return }
        pendingHints = nil
        hints = new
        stats.hintUpdates += 1
        let message: [String: Any] = ["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "transcription": SpeechProtocol.openAITranscription(settings: settings, hints: new)
        ]]]]
        onDiagnostic?("hints:\(new.keywords.count)")
        Task { [weak self] in
            do { try await self?.send(message, on: socket) } catch {}
        }
    }

    /// Text-stall safety net (the user's "3 seconds without new text" rule) and
    /// a guard against background noise mistaken for speech.
    private func watchTurns(sessionID id: UUID) async {
        while token == id, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard token == id, !stopping, segmenter.isSpeaking else { continue }
            let now = Date()
            if let lastTextAt, buffer.hasUncommittedText, now.timeIntervalSince(lastTextAt) >= Self.textStallSeconds {
                self.lastTextAt = nil
                input?.yield(.endTurn(reason: "text-stall"))
            } else if !buffer.hasUncommittedText, let opened = turnOpenedAt,
                      now.timeIntervalSince(opened) >= Self.silentTurnSeconds {
                turnOpenedAt = now
                input?.yield(.endTurn(reason: "no-text"))
            }
        }
    }

    // MARK: - Receiving

    private func receiveLoop(socket: URLSessionWebSocketTask, sessionID id: UUID) async {
        do {
            while !Task.isCancelled, token == id {
                let object = try await receiveObject(on: socket)
                guard token == id else { break }
                if let detail = object["error"] as? [String: Any] {
                    let code = detail["code"] as? String ?? ""
                    if code == "input_audio_buffer_commit_empty" || code == "input_audio_buffer_commit_too_small" {
                        awaitingFinal = max(0, awaitingFinal - 1)
                        if !commitSpans.isEmpty { commitSpans.removeFirst() }
                        continue
                    }
                    throw ProviderFailure.message(serviceError(object) ?? "語音服務錯誤。")
                }
                handle(object)
            }
        } catch {
            if token == id, !stopping { fail(networkMessage(error)) }
        }
    }

    private func handle(_ object: [String: Any]) {
        if settings.asrProvider == .openAI {
            guard let type = object["type"] as? String else { return }
            let id = object["item_id"] as? String ?? ""
            switch type {
            case "input_audio_buffer.committed":
                buffer.committed(id)
                if !commitSpans.isEmpty, itemSpans[id] == nil { itemSpans[id] = commitSpans.removeFirst() }
            case "conversation.item.input_audio_transcription.delta":
                if var update = buffer.delta(object["delta"] as? String ?? "", id: id,
                                             eventID: object["event_id"] as? String) {
                    if lastTextAt == nil { onDiagnostic?("first-text") }
                    lastTextAt = Date()
                    segmenter.extraPause = DanglingEnd.isDangling(update.text) ? 0.8 : 0
                    update.speechSpan = itemSpans[id].map { SpeechSpan(startedAt: $0.startedAt) }
                        ?? turnOpenedAt.map { SpeechSpan(startedAt: $0, isEstimated: true) }
                    onUtterance?(update)
                }
            case "conversation.item.input_audio_transcription.completed":
                awaitingFinal = max(0, awaitingFinal - 1)
                onDiagnostic?("final")
                if var update = buffer.completed(object["transcript"] as? String ?? "", id: id) {
                    update.language = (object["languages"] as? [[String: Any]])?.first?["code"] as? String
                    update.addsSentencePunctuation = true
                    update.speechSpan = itemSpans.removeValue(forKey: id)
                    onUtterance?(update)
                }
            case "conversation.item.input_audio_transcription.failed":
                awaitingFinal = max(0, awaitingFinal - 1)
                if var update = buffer.completed("", id: id) {
                    update.speechSpan = itemSpans.removeValue(forKey: id)
                    onUtterance?(update)
                }
                onWarning?("有一段語音辨識失敗，已保留收到的文字。")
            default: break
            }
        } else if let content = object["serverContent"] as? [String: Any] {
            if let interim = content["interimInputTranscription"] as? [String: Any], let text = interim["text"] as? String {
                geminiVoicePending = true
                if var update = geminiBuffer.interim(text) {
                    update.speechSpan = captureClock.geminiSpan(interim)
                    onUtterance?(update)
                }
            }
            if let final = content["inputTranscription"] as? [String: Any], let text = final["text"] as? String, !text.isEmpty {
                if var update = geminiBuffer.completed(text) {
                    geminiVoicePending = false
                    update.addsSentencePunctuation = true
                    update.speechSpan = captureClock.geminiSpan(final)
                    onUtterance?(update)
                }
            }
        }
        if object["goAway"] != nil {
            fail("語音服務即將結束這次連線。已收到的逐字稿會保留，請按開始重新連線。")
        }
    }

    // MARK: - Utilities

    private func teardown() async {
        token = nil
        watchdog?.cancel()
        sender?.cancel()
        receiver?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        watchdog = nil
        sender = nil
        receiver = nil
        socket = nil
        session = nil
        input = nil
        capture = nil
        key = ""
        onLevel?(0)
        stopping = false
    }

    private func send(_ object: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveObject(on socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data = switch message {
        case .data(let value): value
        case .string(let value): Data(value.utf8)
        @unknown default: Data()
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.message("語音服務回傳無法辨識的資料。")
        }
        return result
    }

    private func serviceError(_ object: [String: Any]) -> String? {
        guard let error = object["error"] as? [String: Any] else { return nil }
        var message = String((error["message"] as? String ?? "請檢查金鑰、模型與帳戶額度。").prefix(500))
        if !key.isEmpty { message = message.replacingOccurrences(of: key, with: "[已隱藏]") }
        return "\(settings.asrProvider.title) 語音服務：\(message)"
    }

    private func networkMessage(_ error: Error) -> String {
        if let failure = error as? ProviderFailure { return failure.localizedDescription }
        return "\(settings.asrProvider.title) 語音連線中斷或逾時。請檢查網路、API 金鑰、模型權限與帳戶額度後重新開始。"
    }

    private func fail(_ message: String) {
        guard !failed, !stopping else { return }
        failed = true
        onError?(message)
    }
}
