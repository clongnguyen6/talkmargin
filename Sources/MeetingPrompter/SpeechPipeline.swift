import AVFoundation
import Speech

/// One on-device recognizer fed with captured audio buffers.
final class SpeechPipeline: @unchecked Sendable {
    enum Language {
        /// SpeechTranscriber, best for long-form English.
        case english
        /// DictationTranscriber, the only on-device option for Vietnamese.
        case vietnamese
    }

    struct Result {
        let text: String
        let isFinal: Bool
        /// Mean recognizer confidence (0...1) weighted by text length.
        let confidence: Double
    }

    enum Failure: LocalizedError {
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let locale): "Máy không hỗ trợ nhận dạng giọng nói \(locale) on-device."
            }
        }
    }

    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<Void, Never>
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat,
                 continuation: AsyncStream<AnalyzerInput>.Continuation, results: Task<Void, Never>) {
        self.analyzer = analyzer
        self.format = format
        self.continuation = continuation
        self.results = results
    }

    /// Whether the language model is installed, so `make` will not have to download it.
    static func isInstalled(_ language: Language) async -> Bool {
        switch language {
        case .english: await SpeechTranscriber.installedLocales.contains { $0.identifier == "en_US" }
        case .vietnamese: await DictationTranscriber.installedLocales.contains { $0.identifier == "vi_VN" }
        }
    }

    /// Downloads the language model if it is not installed yet.
    static func install(_ language: Language) async throws {
        let module: any SpeechModule = switch language {
        case .english:
            SpeechTranscriber(locale: Locale(identifier: "en_US"), preset: .transcription)
        case .vietnamese:
            DictationTranscriber(locale: Locale(identifier: "vi_VN"), preset: .shortDictation)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    /// Builds a running recognizer, downloading the model first if needed.
    /// `onResult` is called on the main actor.
    static func make(_ language: Language, onResult: @escaping @MainActor (Result) -> Void) async throws -> SpeechPipeline {
        let module: any SpeechModule
        let resultStream: AsyncThrowingStream<(AttributedString, Bool), Error>
        switch language {
        case .english:
            let locale = Locale(identifier: "en_US")
            guard await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier == locale.identifier }) else {
                throw Failure.unsupported("tiếng Anh")
            }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults], attributeOptions: [.transcriptionConfidence])
            module = transcriber
            resultStream = Self.map(transcriber.results) { ($0.text, $0.isFinal) }
        case .vietnamese:
            let locale = Locale(identifier: "vi_VN")
            guard await DictationTranscriber.supportedLocales.contains(where: { $0.identifier == locale.identifier }) else {
                throw Failure.unsupported("tiếng Việt")
            }
            let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                                   reportingOptions: [.volatileResults], attributeOptions: [.transcriptionConfidence])
            module = transcriber
            resultStream = Self.map(transcriber.results) { ($0.text, $0.isFinal) }
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw Failure.unsupported(language == .english ? "tiếng Anh" : "tiếng Việt")
        }
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: input)

        let results = Task {
            do {
                for try await (text, isFinal) in resultStream {
                    let result = Result(text: String(text.characters), isFinal: isFinal, confidence: Self.confidence(of: text))
                    await onResult(result)
                }
            } catch {
                // The stream ends with an error when the analyzer is cancelled; nothing to report.
            }
        }
        return SpeechPipeline(analyzer: analyzer, format: format, continuation: continuation, results: results)
    }

    func feed(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, converted.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Ends the input and waits until the last results have been delivered.
    func finish() async {
        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results.value
    }

    private static func map<S: AsyncSequence & Sendable>(_ sequence: S, _ transform: @escaping @Sendable (S.Element) -> (AttributedString, Bool))
        -> AsyncThrowingStream<(AttributedString, Bool), Error> where S.Element: Sendable {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in sequence { continuation.yield(transform(element)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func confidence(of text: AttributedString) -> Double {
        var weighted = 0.0
        var length = 0
        for run in text.runs {
            guard let confidence = run.transcriptionConfidence else { continue }
            let count = text[run.range].characters.count
            weighted += confidence * Double(count)
            length += count
        }
        return length > 0 ? weighted / Double(length) : 0
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &description) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                   into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
