import Foundation
import PrompterCore
import os

/// Push-to-talk: records system audio and the microphone while the shortcut is
/// held. The meeting is recognized as English; the microphone runs English and
/// Vietnamese side by side and keeps whichever is more confident.
@MainActor
final class ClipTranscriber {
    private enum Source {
        case others, micEnglish, micVietnamese
    }

    private struct Track {
        var finals: [String] = []
        var volatile = ""
        var weightedConfidence = 0.0
        var length = 0

        var text: String { (finals + [volatile]).filter { !$0.isEmpty }.joined(separator: " ") }
        var confidence: Double { length > 0 ? weightedConfidence / Double(length) : 0 }

        mutating func apply(_ result: SpeechPipeline.Result) {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isFinal {
                volatile = ""
                guard !text.isEmpty else { return }
                finals.append(text)
                weightedConfidence += result.confidence * Double(text.count)
                length += text.count
            } else {
                volatile = text
            }
        }
    }

    /// Live text while recording.
    var onPreview: ((String) -> Void)?
    private(set) var isRecording = false
    /// Set when Vietnamese is not available yet (e.g. still downloading).
    private(set) var notice: String?

    private let capture: AudioCapture
    private let log = Logger(subsystem: "MeetingPrompter", category: "clip")
    private var tracks: [Source: Track] = [:]
    private var pipelines: [SpeechPipeline] = []
    private var setup: Task<Bool, Never>?
    private var vietnameseDownload: Task<Void, Never>?

    init(capture: AudioCapture) {
        self.capture = capture
    }

    func begin() {
        guard !isRecording else { return }
        isRecording = true
        tracks = [:]
        notice = nil
        let sink = ClipSink()
        capture.router.setClip(sink)
        onPreview?("")
        setup = Task {
            do {
                try await capture.acquire()
            } catch {
                notice = "Không thu được âm thanh: \(error.localizedDescription)"
                onPreview?("")
                return false
            }
            do {
                var system: [SpeechPipeline] = []
                var microphone: [SpeechPipeline] = []
                system.append(try await pipeline(.english, for: .others))
                if capture.hasMicrophone {
                    microphone.append(try await pipeline(.english, for: .micEnglish))
                    if await SpeechPipeline.isInstalled(.vietnamese) {
                        microphone.append(try await pipeline(.vietnamese, for: .micVietnamese))
                    } else {
                        downloadVietnamese()
                    }
                }
                pipelines = system + microphone
                sink.attach(system: system, microphone: microphone)
            } catch {
                notice = error.localizedDescription
                log.error("clip setup failed: \(error.localizedDescription)")
            }
            return true
        }
    }

    /// Stops recording and returns the recognized text.
    func end() async -> String {
        guard isRecording else { return "" }
        isRecording = false
        let acquired = await setup?.value ?? false
        setup = nil
        capture.router.setClip(nil)
        for pipeline in pipelines { await pipeline.finish() }
        pipelines = []
        if acquired { await capture.release() }
        return composed
    }

    private var composed: String {
        let others = tracks[.others]?.text ?? ""
        let english = tracks[.micEnglish] ?? Track()
        let vietnamese = tracks[.micVietnamese] ?? Track()
        var mine = !vietnamese.text.isEmpty && (english.text.isEmpty || vietnamese.confidence > english.confidence)
            ? vietnamese.text : english.text
        if EchoFilter.isEcho(mine, of: others) { mine = "" }
        switch (others.isEmpty, mine.isEmpty) {
        case (false, false): return "Others: \(others)\nTôi: \(mine)"
        case (false, true): return "Others: \(others)"
        default: return mine
        }
    }

    private func pipeline(_ language: SpeechPipeline.Language, for source: Source) async throws -> SpeechPipeline {
        try await SpeechPipeline.make(language) { [weak self] result in
            // end() waits for every pipeline to finish, so late results still belong to this clip.
            guard let self else { return }
            tracks[source, default: Track()].apply(result)
            if isRecording { onPreview?(composed) }
        }
    }

    private func downloadVietnamese() {
        guard vietnameseDownload == nil else { return }
        notice = "Đang tải model tiếng Việt, lần này chỉ nhận dạng tiếng Anh."
        vietnameseDownload = Task {
            do {
                try await SpeechPipeline.install(.vietnamese)
            } catch {
                log.error("Vietnamese model download failed: \(error.localizedDescription)")
            }
            vietnameseDownload = nil
        }
    }
}
