import Foundation
import AVFoundation

/// Offline core tests: endpointing on a noisy scenario file,
/// vocabulary parsing rules, settings migration and recognition hints.
@main
struct CoreRebuildTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ label: String) {
        print(condition ? "PASS" : "FAIL", label)
        if !condition { failures += 1 }
    }

    static func main() throws {
        let args = CommandLine.arguments
        // Optional: a recorded scenario (audio + JSON segment labels). Without it,
        // the synthetic endpointing tests below still run.
        if args.count >= 3 {
            try segmentation(file: URL(fileURLWithPath: args[1]), truth: URL(fileURLWithPath: args[2]))
        } else {
            print("== 未提供情境音檔，略過錄音斷句測試（見 Tests/README.md）")
        }
        synthetic()
        draftEngineRules()
        vocabularyRules()
        settingsMigration()
        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    static func pcm(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Data(bytes: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2)
    }

    struct Segment: Decodable { let label: String; let start: Double; let end: Double }
    struct Truth: Decodable { let segments: [Segment] }

    static func segmentation(file: URL, truth: URL) throws {
        let data = try pcm(file)
        let segments = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: truth)).segments
        var segmenter = UtteranceSegmenter()
        let origin = Date(timeIntervalSince1970: 0)
        let chunk = 2_400 * 2 // 100 ms, like the capture callback
        var sent = 0
        var commits: [(Double, Double, Bool)] = []
        var discards: [Double] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            let start = origin.addingTimeInterval(Double(offset / 2) / 24_000)
            for event in segmenter.consume(data.subdata(in: offset..<end), startedAt: start) {
                switch event {
                case .audio(let bytes): sent += bytes.count
                case .commit(let s, let e, let forced):
                    commits.append((s.timeIntervalSince(origin), e.timeIntervalSince(origin), forced))
                case .discard: discards.append(Double(end / 2) / 24_000)
                }
            }
            offset = end
        }
        let total = Double(data.count / 2) / 24_000
        print("== 情境音檔：\(String(format: "%.1f", total)) 秒")
        for (s, e, forced) in commits {
            let label = segments.first { s >= $0.start - 0.4 && s < $0.end }?.label ?? "?"
            print(String(format: "  句子 %6.2f–%6.2f 秒（%.2f 秒）%@ 起點在 %@", s, e, e - s, forced ? "強制" : "停頓", label))
        }
        print("  丟棄的短雜音：\(discards.map { String(format: "%.1f", $0) })")
        let sentSeconds = Double(sent / 2) / 24_000
        print(String(format: "  送出聲音 %.1f 秒，占全長 %.0f%%", sentSeconds, 100 * sentSeconds / total))

        func inside(_ label: String) -> Segment { segments.first { $0.label == label }! }
        let quiet10 = inside("quiet-noise-10s")
        check(!commits.contains { $0.0 > quiet10.start + 0.5 && $0.0 < quiet10.end - 0.5 },
              "安靜底噪 10 秒內沒有產生句子")
        let chinese = inside("chinese"), english = inside("english")
        check(commits.contains { $0.0 < chinese.start + 1 && $0.0 >= chinese.start - 0.4 }, "中文第一句被偵測到")
        check(commits.contains { $0.0 >= english.start - 0.4 && $0.0 < english.start + 1 }, "1.5 秒停頓後，英文另起一句")
        check(!commits.contains { $0.0 < english.start && $0.1 > english.start + 0.5 }, "中文與英文沒有被併成同一句")
        let bilingual = inside("bilingual-in-loud-noise")
        let inNoise = commits.filter { $0.0 >= bilingual.start - 0.5 && $0.0 < bilingual.end }
        check(!inNoise.isEmpty, "大噪音下的中英混講仍被偵測（\(inNoise.count) 句）")
        // The bilingual clip starts with 1 s of its own silence.
        check(inNoise.first.map { $0.0 <= bilingual.start + 1.6 } == true, "大噪音下的第一句在開口後 0.6 秒內被偵測")
        let step = inside("loud-noise-step-8s")
        check(!commits.contains { $0.0 >= step.start - 0.2 && $0.0 < step.end && $0.1 > step.start + 5 }, "噪音突然變大時，誤判的句子在 5 秒內結束")
        check(commits.allSatisfy { $0.1 - $0.0 <= 25.5 }, "沒有超過 25 秒的句子")
        check(commits.filter { $0.2 }.count <= 2, "強制切句不超過 2 次")
        check(sentSeconds < total * 0.8, "沉默時段沒有全部送出")
    }

    /// Tone bursts: 0.3 s gaps stay inside one sentence, 1.2 s gaps split it.
    static func synthetic() {
        func tone(_ seconds: Double, level: Double) -> Data {
            var data = Data()
            for i in 0..<Int(seconds * 24_000) {
                let value = sin(2 * .pi * 220 * Double(i) / 24_000) * level * (0.6 + 0.4 * sin(2 * .pi * 4 * Double(i) / 24_000))
                withUnsafeBytes(of: Int16(value * 32_767).littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }
        func quiet(_ seconds: Double) -> Data {
            var data = Data()
            var seed: UInt64 = 1
            for _ in 0..<Int(seconds * 24_000) {
                seed = seed &* 6364136223846793005 &+ 1
                let value = Double(Int64(bitPattern: seed >> 11) % 2000 - 1000) / 1000 * 0.002
                withUnsafeBytes(of: Int16(value * 32_767).littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }
        var stream = quiet(1.5)
        for _ in 0..<3 { stream += tone(0.9, level: 0.2) + quiet(0.3) }   // one sentence with short gaps
        stream += quiet(1.2)
        stream += tone(1.5, level: 0.2) + quiet(1.5)                      // second sentence
        stream += tone(0.06, level: 0.3) + quiet(1.5)                     // click: discarded
        var segmenter = UtteranceSegmenter()
        var commits = 0, discards = 0
        let origin = Date()
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 4_800, stream.count)
            for event in segmenter.consume(stream.subdata(in: offset..<end),
                                           startedAt: origin.addingTimeInterval(Double(offset / 2) / 24_000)) {
                if case .commit = event { commits += 1 }
                if case .discard = event { discards += 1 }
            }
            offset = end
        }
        check(commits == 2, "合成音：0.3 秒小停頓不斷句、1.2 秒停頓斷句（得到 \(commits) 句）")
        // A 1.2 s pause after a dangling word ("in the …") is held when the pipeline asks for it.
        var held = UtteranceSegmenter()
        var heldCommits = 0
        var o = 0
        let shortStream = quiet(1.5) + tone(1.0, level: 0.2) + quiet(1.2) + tone(1.0, level: 0.2) + quiet(2.0)
        while o < shortStream.count {
            let e = min(o + 4_800, shortStream.count)
            held.extraPause = 0.8
            for event in held.consume(shortStream.subdata(in: o..<e), startedAt: origin.addingTimeInterval(Double(o / 2) / 24_000)) {
                if case .commit = event { heldCommits += 1 }
            }
            o = e
        }
        check(heldCommits == 1, "懸空句尾：1.2 秒停頓延長後不斷句（得到 \(heldCommits) 句）")
        check(discards == 1, "合成音：60 毫秒的喀聲被丟棄（\(discards) 次）")
    }

    static func vocabularyRules() {
        let a = UUID(), b = UUID()
        let sources = [LearningSource(segmentID: a, text: "我們今天討論低通濾波和傅立葉轉換。", language: "zh-TW"),
                       LearningSource(segmentID: b, text: "提通率播的截止頻率要設好。", language: "zh-TW")]
        let reply = """
        {"scene":"研究討論：訊號處理中的濾波與頻譜","terms":[{"term":"低通濾波","heard":""},{"term":"傅立葉轉換","heard":""},
         {"term":"量子電腦","heard":""},{"term":"research","heard":""},{"term":"AI coding agent","heard":"AI core agent"}],
         "corrections":[{"segment_id":"\(b.uuidString)","wrong":"提通率播","right":"低通濾波"},
                        {"segment_id":"\(a.uuidString)","wrong":"不存在的字","right":"任意"}]}
        """
        let sources2 = sources + [LearningSource(segmentID: UUID(), text: "We built an AI core agent for proofs.", language: "en")]
        let result = VocabularyLearner.parse(reply, sources: sources2, knownTerms: [])
        let names = result.terms.map(\.term)
        check(result.scene == "研究討論：訊號處理中的濾波與頻譜", "情境摘要：一句話")
        check(names.contains("低通濾波") && names.contains("傅立葉轉換"), "情境摘要：原文出現的罕見詞被採用")
        check(!names.contains("量子電腦"), "情境摘要：原文沒有出現、也沒說聽成什麼的詞被拒絕")
        check(!names.contains("research"), "情境摘要：常見詞被拒絕")
        check(result.terms.contains(LearnedTerm(term: "AI coding agent", heard: "AI core agent")), "情境摘要：依上下文推定的英文拼法（聽成 AI core agent）")
        check(result.corrections.count == 1 && result.corrections[0].segmentID == b, "情境摘要：只接受原文確實出現且讀音相近的修正")
        check(VocabularyLearner.soundsAlike("configuration power", "computation power") && !VocabularyLearner.soundsAlike("PhD", "quantum mechanics"),
              "英文讀音相近判斷")
        let taiwan = TaiwanVocabulary.apply(ChineseScript.traditional("也不像你还是高中生或本科生的时候，看视频学软件"))
        check(taiwan.contains("大學生") && taiwan.contains("影片") && taiwan.contains("軟體") && !taiwan.contains("本科"), "台灣用語：\(taiwan)")
        check(TaiwanVocabulary.apply("頻率響應與質量守恆") == "頻率響應與質量守恆", "台灣用語：頻率響應、質量（物理）不被改動")
        check(TranscriptLanguage.display("I think just read  just watch the YouTube video.", language: "en")
              == "I think just read, just watch the YouTube video.", "停頓空格：英文改為逗號")
        check(TranscriptLanguage.display("It's not like that.  You come here.", language: "en")
              == "It's not like that. You come here.", "停頓空格：句號後只留一個空格")
        check(TranscriptLanguage.display("我覺得  這個方法", language: "zh-TW") == "我覺得，這個方法", "停頓空格：中文改為全形逗號")
        check(TranscriptLanguage.display("still speaking  ", language: "en") == "still speaking  ", "停頓空格：句尾還在說話時不加逗號")
        check(TaiwanVocabulary.apply("斯坦福是斯坦福教授") == "史丹佛是史丹佛教授", "台灣用語：斯坦福→史丹佛")
        check(DanglingEnd.isDangling("But there will be no.") && !DanglingEnd.isDangling("The answer is yes, not no.") && DanglingEnd.isDangling("We all know that in the.")
              && DanglingEnd.isDangling("so if") && DanglingEnd.isDangling("我們都知道因為") && !DanglingEnd.isDangling("Is that right?")
              && !DanglingEnd.isDangling("This is the fundamental theorem."), "懸空句尾判斷")
        var store: [VocabularyEntry] = []
        Vocabulary.merge(["低通濾波", "FFT"], into: &store)
        Vocabulary.merge(["低通濾波"], into: &store)
        check(Vocabulary.ranked(store, limit: 1) == ["低通濾波"], "詞彙庫：較常出現的詞排前面")
        let hints = RecognitionHints.keywords("STM, STS\n<bad>", terms: ["stm", "低通濾波"])
        check(hints == ["STM", "STS", "低通濾波"], "辨識提示：去重、排除含角括號的詞（\(hints)）")
    }

    static func settingsMigration() {
        for raw in ["textInactivity", "acoustic"] {
            let json = Data("\"\(raw)\"".utf8)
            let value = try? JSONDecoder().decode(PauseSegmentation.self, from: json)
            check(value == .standard, "舊設定「\(raw)」轉成標準停頓")
        }
        // An archive written by 0.4.19 loads, and the 0.4.x field survives a save for rollback.
        // Settings object copied from the installed 0.4.19 archive (no keys involved).
        let old = Data(#"{"asrProvider": "openAI", "audioSource": "microphone", "bidirectional": true, "claudeTranslationModel": "claude-haiku-5-5", "contextualCorrection": true, "geminiASRModel": "gemini-3.5-transcribe-live", "geminiTranslationModel": "gemini-3.8-flash", "glossary": "", "incognitoMode": false, "openAIASRModel": "gpt-live-transcribe", "openAITranslationModel": "gpt-6-luna", "savedPauseSegmentation": "textInactivity", "sourceLanguage": "en-US", "targetLanguage": "zh-TW", "translationProvider": "openAI"}"#.utf8)
        if var settings = try? JSONDecoder().decode(AppSettings.self, from: old) {
            check(settings.pauseSegmentation == .standard, "0.4.19 設定可讀，停頓預設為標準")
            settings.pauseSegmentation = .long
            let saved = String(decoding: (try? JSONEncoder().encode(settings)) ?? Data(), as: UTF8.self)
            check(saved.contains(#""savedPauseSegmentation":"textInactivity""#) && saved.contains(#""savedPauseLength":"long""#),
                  "存檔保留舊欄位，新設定另存一欄（可退回 0.4.19）")
        } else { check(false, "0.4.19 設定可讀") }
        let config = SpeechProtocol.openAIConfiguration(settings: AppSettings.dialogueDefault,
                                                        hints: RecognitionHints(keywords: ["低通濾波"], prompt: "p"))
        let input = ((config["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any]
        let transcription = input?["transcription"] as? [String: Any]
        check(input?["turn_detection"] is NSNull, "OpenAI：turn_detection 為 null（由本機斷句）")
        check(transcription?["keywords"] as? [String] == ["低通濾波"], "OpenAI：詞彙提示放進 keywords")
        check(transcription?["languages"] as? [String] == ["en", "zh-tw"], "OpenAI：左右兩種語言作為候選")
    }

    static func draftEngineRules() {
        print("== 本機暫譯引擎")
        check(LocalModelDraftEngine.clean("<think>hmm</think>\n 你好 ") == "你好", "去掉推理模型的思考段落")
        let prompt = LocalModelDraftEngine.prompt("hello", from: "en", to: "zh-TW")
        check(prompt.contains("Traditional Chinese (Taiwan)") && prompt.hasSuffix("hello"), "提示詞含目標語言且原文在最後")
        check(AppSettings().draftEngineConfig == DraftEngineConfig(), "舊設定沒有暫譯欄位時用預設引擎")
        let remote = LocalModelDraftEngine(endpoint: "https://example.com/v1", model: "x")
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var refused = false
        Task {
            do { _ = try await remote.translate("hi", from: "en", to: "zh-TW") } catch {
                refused = error.localizedDescription.contains("127.0.0.1")
            }
            semaphore.signal()
        }
        semaphore.wait()
        check(refused, "本機暫譯拒絕連到這台 Mac 以外的位址")

        // Optional live check against a running local server, e.g.
        // ZHUYU_DRAFT_ENDPOINT=http://127.0.0.1:11434/v1 ZHUYU_DRAFT_MODEL=translategemma:4b bash verify.sh
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["ZHUYU_DRAFT_ENDPOINT"] else { return }
        let engine = LocalModelDraftEngine(endpoint: endpoint, model: env["ZHUYU_DRAFT_MODEL"] ?? DraftEngineConfig.defaultModel)
        nonisolated(unsafe) var output = ""
        nonisolated(unsafe) var failure = ""
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                try await engine.prepare(from: "en", to: "zh-TW")
                output = try await engine.translate("The experiment starts tomorrow morning.", from: "en", to: "zh-TW")
            } catch { failure = error.localizedDescription }
            done.signal()
        }
        done.wait()
        print("  本機模型回覆：\(output.isEmpty ? failure : output)")
        check(failure.isEmpty && !output.isEmpty, "本機模型伺服器可以翻譯")
    }
}
