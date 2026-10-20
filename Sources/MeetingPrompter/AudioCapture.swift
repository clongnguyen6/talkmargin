import AVFoundation
import ScreenCaptureKit
import os
import PrompterCore

/// One ScreenCaptureKit stream for system audio (other participants) and the
/// microphone. It runs only while something holds it, e.g. a push-to-talk clip.
@MainActor
final class AudioCapture {
    enum Failure: LocalizedError {
        case noDisplay

        var errorDescription: String? { tr(.audioNoDisplay) }
    }

    let router = AudioRouter()
    private(set) var hasMicrophone = false
    private let log = Logger(subsystem: "MeetingPrompter", category: "audio")
    private var stream: SCStream?
    private var holders = 0
    private var starting: Task<Void, Error>?

    /// Starts capturing if needed. Balance every successful call with `release()`.
    func acquire() async throws {
        holders += 1
        do {
            if stream == nil {
                let task = starting ?? Task { try await startStream() }
                starting = task
                defer { starting = nil }
                try await task.value
            }
        } catch {
            holders -= 1
            throw error
        }
    }

    func release() async {
        holders = max(0, holders - 1)
        guard holders == 0, let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            log.error("stopCapture failed: \(error.localizedDescription)")
        }
    }

    private func startStream() async throws {
        hasMicrophone = await AVCaptureDevice.requestAccess(for: .audio)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw Failure.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = hasMicrophone
        config.sampleRate = 48_000
        config.channelCount = 1
        // Video is required by the API but unused; keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        let queue = DispatchQueue(label: "MeetingPrompter.audio")
        try stream.addStreamOutput(router, type: .audio, sampleHandlerQueue: queue)
        if hasMicrophone {
            try stream.addStreamOutput(router, type: .microphone, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
    }
}

/// Sends captured audio to the recording clip, if any.
final class AudioRouter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var clip: ClipSink?

    func setClip(_ sink: ClipSink?) {
        lock.withLock { clip = sink }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let clip = lock.withLock { self.clip }
        switch type {
        case .audio: clip?.feedSystem(sampleBuffer)
        case .microphone: clip?.feedMicrophone(sampleBuffer)
        default: break
        }
    }
}

/// Buffers a clip's audio until its recognizers are ready, then streams into them.
final class ClipSink: @unchecked Sendable {
    private let lock = NSLock()
    private var system: [SpeechPipeline]?
    private var microphone: [SpeechPipeline]?
    private var pendingSystem: [CMSampleBuffer] = []
    private var pendingMicrophone: [CMSampleBuffer] = []

    func attach(system: [SpeechPipeline], microphone: [SpeechPipeline]) {
        let (bufferedSystem, bufferedMicrophone) = lock.withLock {
            self.system = system
            self.microphone = microphone
            defer {
                pendingSystem = []
                pendingMicrophone = []
            }
            return (pendingSystem, pendingMicrophone)
        }
        for buffer in bufferedSystem { system.forEach { $0.feed(buffer) } }
        for buffer in bufferedMicrophone { microphone.forEach { $0.feed(buffer) } }
    }

    func feedSystem(_ buffer: CMSampleBuffer) {
        let targets: [SpeechPipeline]? = lock.withLock {
            if system == nil { pendingSystem.append(buffer) }
            return system
        }
        targets?.forEach { $0.feed(buffer) }
    }

    func feedMicrophone(_ buffer: CMSampleBuffer) {
        let targets: [SpeechPipeline]? = lock.withLock {
            if microphone == nil { pendingMicrophone.append(buffer) }
            return microphone
        }
        targets?.forEach { $0.feed(buffer) }
    }
}
