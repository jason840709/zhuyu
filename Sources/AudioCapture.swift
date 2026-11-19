import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia

/// Captures one selected source. Audio stays in memory; no recordings are written.
@MainActor
final class AudioCapture {
    var onPCM: (@Sendable (Data) -> Void)?
    var onTimedPCM: (@Sendable (Data, Date) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private var engine: AVAudioEngine?
    private var hasMicrophoneTap = false
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var processor: AudioPCMProcessor?
    private var operationID: UUID?
    private let systemAudioQueue = DispatchQueue(label: "zhuyu.system-audio", qos: .userInitiated)

    func start(source: AudioSource, sampleRate: Double) async throws {
        await stop()
        guard sampleRate == 16_000 || sampleRate == 24_000 else {
            throw AudioCaptureFailure.message("語音服務的取樣率必須是 16 kHz 或 24 kHz。")
        }
        let token = UUID()
        operationID = token
        let processor = try AudioPCMProcessor(
            sampleRate: sampleRate,
            onPCM: onPCM,
            onLevel: onLevel,
            onError: onError,
            onTimedPCM: onTimedPCM
        )
        self.processor = processor
        do {
            switch source {
            case .microphone:
                try await startMicrophone(processor: processor, token: token)
            case .system:
                try await startSystemAudio(processor: processor, token: token)
            }
            try Task.checkCancellation()
            guard operationID == token else { throw CancellationError() }
        } catch {
            // A newer start owns its own capture objects; never stop that session.
            if operationID == token { await stop() }
            throw error
        }
    }

    func stop() async {
        operationID = nil
        let oldProcessor = processor
        processor = nil

        let oldEngine = engine
        let hadTap = hasMicrophoneTap
        engine = nil
        hasMicrophoneTap = false
        oldEngine?.stop()
        if hadTap { oldEngine?.inputNode.removeTap(onBus: 0) }
        oldEngine?.reset()

        // No more microphone buffers can enter. finish() gates any remaining
        // SCStream callbacks and emits the converter's owned tail synchronously,
        // before SpeechPipeline closes its PCM continuation.
        oldProcessor?.finish()

        let oldStream = stream
        let oldOutput = streamOutput
        stream = nil
        streamOutput = nil
        if let oldStream {
            do {
                try await oldStream.stopCapture()
            } catch {
                onError?("停止電腦音訊擷取時發生錯誤：\(error.localizedDescription)")
            }
            if let oldOutput {
                do {
                    try oldStream.removeStreamOutput(oldOutput, type: .audio)
                } catch {
                    onError?("釋放電腦音訊輸出時發生錯誤：\(error.localizedDescription)")
                }
            }
        }
        onLevel?(0)
    }

    /// Diagnostic input only: replay a project-local fixture through the same
    /// converter and PCM callbacks as live capture. No microphone is opened.
    func replayAudioFile(_ url: URL, sampleRate: Double) async throws {
        await stop()
        let id = UUID()
        operationID = id
        let processor = try AudioPCMProcessor(sampleRate: sampleRate, onPCM: onPCM,
                                               onLevel: onLevel, onError: onError, onTimedPCM: onTimedPCM)
        self.processor = processor
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0, file.length > 0,
              Double(file.length) / format.sampleRate <= 120,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(format.sampleRate / 10)) else {
            throw AudioCaptureFailure.message("測試音訊必須為 120 秒以內的有效音訊檔。")
        }
        let recordedAt = Date()
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard operationID == id else { throw CancellationError() }
            let inputStart = recordedAt.addingTimeInterval(Double(file.framePosition) / format.sampleRate)
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            guard buffer.frameLength > 0 else { break }
            processor.consume(buffer, startedAt: inputStart)
            try await Task.sleep(for: .seconds(Double(buffer.frameLength) / format.sampleRate))
        }
        processor.finish()
    }

    private func startMicrophone(processor: AudioPCMProcessor, token: UUID) async throws {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            authorized = false
        }
        try Task.checkCancellation()
        guard operationID == token else { throw CancellationError() }
        guard authorized else {
            throw AudioCaptureFailure.message("尚未允許麥克風。請到「系統設定 → 隱私權與安全性 → 麥克風」允許逐語，再重新開始。")
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioCaptureFailure.message("找不到可用的麥克風。請確認輸入裝置已連接，並在系統音效設定中選好裝置。")
        }

        // The tap borrows AVAudioEngine's buffer. Convert synchronously here,
        // then send an owned Data value rather than sharing that buffer.
        Self.installMicrophoneTap(on: input, format: format, processor: processor)
        self.engine = engine
        hasMicrophoneTap = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureFailure.message("無法啟動麥克風：\(error.localizedDescription)")
        }
    }

    static func installMicrophoneTap(on input: AVAudioNode, format: AVAudioFormat,
                                     processor: AudioPCMProcessor) {
        // AVAudioNodeTapBlock is a legacy non-Sendable callback. Explicitly
        // mark this closure Sendable so it cannot inherit MainActor isolation.
        // Only the synchronized processor is captured; borrowed audio is consumed here.
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { @Sendable buffer, time in
            let seconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
            processor.consume(buffer, startedAt: seconds.flatMap { processor.captureDate(hostSeconds: $0) })
        }
    }

    private func startSystemAudio(processor: AudioPCMProcessor, token: UUID) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AudioCaptureFailure.message("無法取得電腦播放聲音：\(error.localizedDescription)。請到「系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製」允許逐語；首次授權後可能需要重新開啟 App。")
        }
        try Task.checkCancellation()
        guard operationID == token else { throw CancellationError() }
        guard let display = content.displays.first else {
            throw AudioCaptureFailure.message("沒有可用的螢幕音訊來源。請確認目前有登入中的桌面工作階段。")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // Only the .audio output is registered. These minimal screen settings
        // avoid requesting useful video frames or allocating a large video queue.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let output = CaptureStreamOutput(processor: processor)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: systemAudioQueue)
        self.stream = stream
        self.streamOutput = output
        do {
            try await stream.startCapture()
        } catch {
            throw AudioCaptureFailure.message("無法啟動電腦音訊擷取：\(error.localizedDescription)")
        }
    }
}

private enum AudioCaptureFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

/// An AVAudioConverter is stateful and not Sendable. All access, including
/// shutdown and callback emission, is protected by this one lock. No borrowed
/// buffer or pointer escapes consume(). The unchecked conformance covers only
/// this synchronized callback bridge, not unsynchronized audio objects.
nonisolated final class AudioPCMProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private let onPCM: (@Sendable (Data) -> Void)?
    private let onTimedPCM: (@Sendable (Data, Date) -> Void)?
    private let onLevel: (@Sendable (Float) -> Void)?
    private let onError: (@Sendable (String) -> Void)?
    private let hostOrigin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    private let wallOrigin = Date()
    private var nextOutputAt: Date?
    private var converter: AVAudioConverter?
    private var active = true
    private var errorReported = false

    init(
        sampleRate: Double,
        onPCM: (@Sendable (Data) -> Void)?,
        onLevel: (@Sendable (Float) -> Void)?,
        onError: (@Sendable (String) -> Void)?,
        onTimedPCM: (@Sendable (Data, Date) -> Void)? = nil
    ) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                        sampleRate: sampleRate,
                                        channels: 1,
                                        interleaved: true) else {
            throw AudioCaptureFailure.message("無法建立語音輸入格式。")
        }
        outputFormat = format
        self.onPCM = onPCM
        self.onTimedPCM = onTimedPCM
        self.onLevel = onLevel
        self.onError = onError
    }

    func disable() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        converter = nil
    }

    /// Graceful end of input: stop accepting new buffers, then drain frames
    /// buffered by the sample-rate converter before releasing it. Callback
    /// emission shares the same lock as consume(), so nothing can arrive later.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        active = false
        guard let converter else { return }
        defer { self.converter = nil }
        do {
            // Bound an unexpected converter failure to terminate. Normal live
            // chunks require one small tail; 32 buffers allows over five seconds
            // of output even at 24 kHz without an unbounded loop on shutdown.
            for _ in 0..<32 {
                guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else {
                    throw AudioCaptureFailure.message("無法配置停止時的音訊緩衝區。")
                }
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let conversionError { throw conversionError }
                guard status != .error else {
                    throw AudioCaptureFailure.message("停止時無法完成剩餘音訊轉換。")
                }
                emit(output)
                if status == .endOfStream || output.frameLength == 0 { return }
            }
            throw AudioCaptureFailure.message("音訊轉換器未能在預期時間內結束。")
        } catch {
            if !errorReported {
                errorReported = true
                onError?("音訊收尾失敗：\(error.localizedDescription)")
            }
        }
    }

    func fail(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard active, !errorReported else { return }
        errorReported = true
        active = false
        onError?(message)
    }

    func captureDate(hostSeconds: Double) -> Date? {
        let offset = hostSeconds - CMClockGetTime(CMClockGetHostTimeClock()).seconds
        guard offset.isFinite, (-5...1).contains(offset) else { return nil }
        return wallOrigin.addingTimeInterval(hostSeconds - hostOrigin)
    }

    func consume(_ input: AVAudioPCMBuffer, startedAt: Date? = nil) {
        let inputStart = startedAt ?? Date().addingTimeInterval(-Double(input.frameLength) / input.format.sampleRate)
        lock.lock()
        defer { lock.unlock() }
        guard active, input.frameLength > 0 else { return }
        do {
            if converter == nil || converter?.inputFormat != input.format {
                guard let next = AVAudioConverter(from: input.format, to: outputFormat) else {
                    throw AudioCaptureFailure.message("無法轉換音訊裝置的取樣格式。")
                }
                next.primeMethod = .none
                converter = next
            }
            guard let converter else { return }
            if nextOutputAt.map({ inputStart.timeIntervalSince($0) > 0.25 }) ?? true {
                nextOutputAt = inputStart
            }
            let ratio = outputFormat.sampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw AudioCaptureFailure.message("無法配置音訊轉換緩衝區。")
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            guard status != .error else {
                throw AudioCaptureFailure.message("音訊格式轉換失敗。")
            }
            emit(output)
        } catch {
            if !errorReported {
                errorReported = true
                onError?("音訊處理失敗：\(error.localizedDescription)")
            }
        }
    }

    /// Called only with lock held, from consume() or graceful finish().
    private func emit(_ output: AVAudioPCMBuffer) {
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let count = Int(output.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let normalized = Float(samples[index]) / 32_768
            sum += normalized * normalized
        }
        // macOS runs on little-endian CPUs. Copying here owns the bytes before
        // AVAudioEngine / CMSampleBuffer reuses the source memory.
        let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        onLevel?(min(1, sqrt(sum / Float(count))))
        onPCM?(data)
        if let start = nextOutputAt {
            onTimedPCM?(data, start)
            nextOutputAt = start.addingTimeInterval(Double(count) / outputFormat.sampleRate)
        }
    }
}

private nonisolated final class CaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let processor: AudioPCMProcessor

    init(processor: AudioPCMProcessor) {
        self.processor = processor
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let description = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription) else { return }
        do {
            try sampleBuffer.withAudioBufferList { bufferList, retainedBlockBuffer in
                // Conversion completes inside this scope while CoreMedia owns
                // the AudioBufferList and retainedBlockBuffer's backing memory.
                withExtendedLifetime(retainedBlockBuffer) {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                       bufferListNoCopy: bufferList.unsafePointer) else {
                        processor.fail("無法讀取電腦音訊緩衝區。")
                        return
                    }
                    processor.consume(buffer, startedAt: processor.captureDate(hostSeconds: sampleBuffer.presentationTimeStamp.seconds))
                }
            }
        } catch {
            processor.fail("無法讀取電腦音訊：\(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        processor.fail("電腦音訊擷取已停止：\(error.localizedDescription)")
    }
}
