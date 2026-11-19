import Foundation

/// Client-side end-of-utterance detection.
///
/// Many speech services end utterances on the server. OpenAI's live transcription model requires `turn_detection: null`, so the
/// client must send `input_audio_buffer.commit`. This type is a
/// service-style endpointer: an adaptive noise floor, hysteresis, a pause
/// threshold, and long-turn limits. It also gates audio: silence before an
/// utterance is not sent (OpenAI bills submitted audio), apart from a short
/// pre-roll so the first syllable is never cut.
struct UtteranceSegmenter: Sendable {
    struct Configuration: Sendable, Equatable {
        var sampleRate: Double = 24_000
        /// Pause that ends an utterance.
        var endSilence: Double = 0.8
        /// After `longTurn` seconds, split at the next shorter breath pause.
        var longTurn: Double = 12
        var longTurnSilence: Double = 0.35
        /// Never let one row grow beyond this.
        var maximumTurn: Double = 25
        /// Audio kept before the detected onset and sent with it.
        var preRoll: Double = 0.3
        /// Shorter voiced bursts (clicks, a cough) are discarded unless text arrived.
        var minimumVoiced: Double = 0.25
        /// Onset requires this margin above the adaptive floor.
        var onsetMarginDB: Double = 9
        /// Speech continues while level stays this far above the floor.
        var holdMarginDB: Double = 5
        /// Below this level nothing counts as speech, regardless of the floor.
        var absoluteMinimumDB: Double = -58
        /// Consecutive loud frames needed for an onset (3 × 20 ms).
        var onsetFrames = 3
        /// Window of the minimum-statistics noise floor.
        var floorWindow: Double = 3
    }

    enum Event: Equatable, Sendable {
        /// Audio to forward to the recognizer (already gated).
        case audio(Data)
        /// The current utterance ended; `start`/`end` are capture times of voiced audio.
        case commit(start: Date, end: Date, forced: Bool)
        /// The detected burst was too short to be speech. Clear what was sent.
        case discard
    }

    private(set) var configuration: Configuration
    private(set) var isSpeaking = false
    /// Extra pause required while the recognized text ends on a word that
    /// cannot end a sentence ("the", "of", 「因為」); set by the pipeline.
    var extraPause: Double = 0
    private(set) var noiseFloorDB: Double = -50
    private(set) var lastLevelDB: Double = -96

    private let frameBytes: Int
    private let frameDuration: Double
    private var pending = Data()
    private var pendingStart: Date?
    private var preRoll: [(data: Data, start: Date)] = []
    private var onsetRun: [(data: Data, start: Date)] = []
    private var blockLevels: [Double] = []
    private var blockAccumulator: [Double] = []
    private var turnStart = Date.distantPast
    private var lastVoiceEnd = Date.distantPast
    private var voicedSeconds: Double = 0
    private var silenceRun: Double = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        let samples = Int(configuration.sampleRate * 0.02)
        frameBytes = samples * 2
        frameDuration = Double(samples) / configuration.sampleRate
    }

    /// Current utterance length (0 while idle).
    func turnDuration(at date: Date) -> Double {
        isSpeaking ? max(0, date.timeIntervalSince(turnStart)) : 0
    }

    /// Feed mono little-endian Int16 PCM captured starting at `startedAt`.
    mutating func consume(_ pcm: Data, startedAt: Date) -> [Event] {
        guard !pcm.isEmpty else { return [] }
        if pending.isEmpty { pendingStart = startedAt }
        pending.append(pcm)
        var events: [Event] = []
        var offset = 0
        let base = pendingStart ?? startedAt
        while pending.count - offset >= frameBytes {
            let frame = pending.subdata(in: offset..<(offset + frameBytes))
            let frameStart = base.addingTimeInterval(Double(offset / 2) / configuration.sampleRate)
            events += process(frame, start: frameStart)
            offset += frameBytes
        }
        if offset > 0 {
            pending.removeSubrange(0..<offset)
            pendingStart = base.addingTimeInterval(Double(offset / 2) / configuration.sampleRate)
        }
        return events
    }

    /// End the current utterance now (used when the recognizer's text stalls or capture stops).
    mutating func forceEnd(at date: Date) -> [Event] {
        guard isSpeaking else { return [] }
        return finishTurn(forced: true, at: date)
    }

    mutating func reset() {
        isSpeaking = false
        pending.removeAll()
        pendingStart = nil
        preRoll.removeAll()
        onsetRun.removeAll()
        silenceRun = 0
        voicedSeconds = 0
    }

    // MARK: - Frame processing

    private mutating func process(_ frame: Data, start: Date) -> [Event] {
        let level = Self.levelDB(frame)
        lastLevelDB = level
        updateFloor(with: level)
        let end = start.addingTimeInterval(frameDuration)
        let onset = level > max(noiseFloorDB + configuration.onsetMarginDB, configuration.absoluteMinimumDB)
        let hold = level > max(noiseFloorDB + configuration.holdMarginDB, configuration.absoluteMinimumDB - 4)

        guard isSpeaking else {
            if onset {
                onsetRun.append((frame, start))
                if onsetRun.count >= configuration.onsetFrames { return beginTurn(lastFrameEnd: end) }
            } else {
                // A broken onset run returns to the pre-roll history.
                for item in onsetRun { pushPreRoll(item.data, start: item.start) }
                onsetRun.removeAll()
                pushPreRoll(frame, start: start)
            }
            return []
        }

        var events: [Event] = [.audio(frame)]
        if hold {
            silenceRun = 0
            voicedSeconds += frameDuration
            lastVoiceEnd = end
        } else {
            silenceRun += frameDuration
        }
        let duration = end.timeIntervalSince(turnStart)
        let pause = duration >= configuration.longTurn
            ? configuration.longTurnSilence + min(extraPause, 0.4)
            : configuration.endSilence + extraPause
        if silenceRun >= pause {
            events += finishTurn(forced: false, at: end)
        } else if duration >= configuration.maximumTurn {
            events += finishTurn(forced: true, at: end)
        }
        return events
    }

    private mutating func beginTurn(lastFrameEnd: Date) -> [Event] {
        isSpeaking = true
        silenceRun = 0
        voicedSeconds = Double(onsetRun.count) * frameDuration
        let audio = preRoll + onsetRun
        turnStart = onsetRun.first?.start ?? lastFrameEnd
        lastVoiceEnd = lastFrameEnd
        preRoll.removeAll()
        onsetRun.removeAll()
        var data = Data()
        for item in audio { data.append(item.data) }
        return [.audio(data)]
    }

    private mutating func finishTurn(forced: Bool, at date: Date) -> [Event] {
        isSpeaking = false
        extraPause = 0
        silenceRun = 0
        let voiced = voicedSeconds
        voicedSeconds = 0
        guard forced || voiced >= configuration.minimumVoiced else { return [.discard] }
        let end = min(max(lastVoiceEnd, turnStart), date)
        return [.commit(start: turnStart, end: end, forced: forced)]
    }

    private mutating func pushPreRoll(_ frame: Data, start: Date) {
        preRoll.append((frame, start))
        let keep = max(1, Int((configuration.preRoll / frameDuration).rounded()))
        if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
    }

    /// Minimum statistics over 100 ms blocks: speech always contains dips, while a
    /// steady fan or air conditioner raises every block and so raises the floor.
    private mutating func updateFloor(with level: Double) {
        blockAccumulator.append(level)
        guard blockAccumulator.count >= 5 else { return }
        let mean = blockAccumulator.reduce(0, +) / Double(blockAccumulator.count)
        blockAccumulator.removeAll(keepingCapacity: true)
        blockLevels.append(mean)
        let keep = max(5, Int(configuration.floorWindow / 0.1))
        if blockLevels.count > keep { blockLevels.removeFirst(blockLevels.count - keep) }
        let minimum = blockLevels.min() ?? mean
        // Fall quickly to a quieter room, rise smoothly to a louder one. The floor
        // keeps adapting inside an utterance: speech has dips within 3 s, while a
        // fan that switches on raises every block and so ends a false turn.
        let target = max(-80, minimum)
        noiseFloorDB += (target < noiseFloorDB ? 0.5 : 0.25) * (target - noiseFloorDB)
    }

    static func levelDB(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return -96 }
        var sum: Double = 0
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
                sum += sample * sample
            }
        }
        let rms = (sum / Double(count)).squareRoot()
        return rms > 0 ? max(-96, 20 * log10(rms)) : -96
    }
}
