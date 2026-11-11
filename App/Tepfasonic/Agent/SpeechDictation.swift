import AVFoundation
import Observation
import Speech

/// Microphone dictation for the Claude composer. Transcription runs entirely on
/// this Mac (`requiresOnDeviceRecognition`), so audio never leaves the machine,
/// in keeping with the rest of the app. The composer owns the text: this type
/// streams the running transcript back through an `onUpdate` closure and the
/// view decides where it lands.
@MainActor
@Observable
final class SpeechDictation {
    enum Status: Equatable { case idle, listening }

    private(set) var status: Status = .idle
    private(set) var transcript = ""
    private(set) var errorMessage: String?

    var isListening: Bool { status == .listening }

    /// On-device dictation is possible for the current language. When false the
    /// view hides the microphone rather than offer a server round-trip.
    var isAvailable: Bool { recognizer?.supportsOnDeviceRecognition == true }

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: ((String) -> Void)?

    func toggle(onUpdate: @escaping (String) -> Void) {
        isListening ? stop() : start(onUpdate: onUpdate)
    }

    func start(onUpdate: @escaping (String) -> Void) {
        guard !isListening else { return }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            errorMessage = "On-device dictation isn't available for your language."
            return
        }
        self.onUpdate = onUpdate
        errorMessage = nil
        transcript = ""
        // Request authorization off the main actor and come back with Task { @MainActor }.
        // Resuming a @MainActor continuation directly from the TCC permission callback
        // traps on macOS 26/27 (swift_task_isCurrentExecutorWithFlags →
        // dispatch_assert_queue_fail), so this path uses no `await` across that callback.
        Self.requestPermissions { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .granted:
                guard !self.isListening, let recognizer = self.recognizer else { return }
                self.beginSession(recognizer)
            case .denied(let message):
                self.errorMessage = message
                self.onUpdate = nil
            }
        }
    }

    func stop() {
        guard isListening else { teardown(); return }
        status = .idle
        request?.endAudio()          // flush remaining audio → a final result arrives
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // `task` is left to deliver its final transcript; the result handler tears it down.
    }

    // MARK: - Session

    private func beginSession(_ recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // audio never leaves this Mac
        request.taskHint = .dictation
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            errorMessage = "No microphone was found."
            teardown()
            return
        }

        // The tap block runs on a realtime audio thread. SFSpeechAudioBufferRecognitionRequest
        // is designed to be fed buffers from there, so the unchecked capture is safe.
        nonisolated(unsafe) let sink = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            errorMessage = "The microphone could not be started."
            teardown()
            return
        }
        status = .listening

        // The result handler is called off the main actor; hop back with Sendable values only.
        nonisolated(unsafe) weak var me = self
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in me?.handleResult(text: text, isFinal: isFinal, failed: failed) }
        }
    }

    private func handleResult(text: String?, isFinal: Bool, failed: Bool) {
        if let text, !text.isEmpty {
            transcript = text
            onUpdate?(text)
        }
        if isFinal || failed { teardown() }
    }

    private func teardown() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        task?.cancel()
        task = nil
        request = nil
        status = .idle
    }

    // MARK: - Authorization

    private enum PermissionOutcome: Sendable { case granted, denied(String) }

    /// Requests Speech then Microphone access with completion handlers and hands the
    /// result back on the main actor via `Task { @MainActor }`. The TCC callbacks fire
    /// on a background queue; nothing here is actor-isolated, so they do no main-actor
    /// executor check. Crossing that callback with `await` on a `@MainActor` function
    /// instead traps on macOS 26/27 (`swift_task_isCurrentExecutorWithFlags` →
    /// `dispatch_assert_queue_fail`), which is what crashed the composer's microphone.
    private static func requestPermissions(_ completion: @escaping @MainActor (PermissionOutcome) -> Void) {
        let speechDenied = "Allow Speech Recognition for Tepfasonic in System Settings › Privacy & Security."
        let micDenied = "Allow Microphone access for Tepfasonic in System Settings › Privacy & Security."
        @Sendable func finish(_ outcome: PermissionOutcome) { Task { @MainActor in completion(outcome) } }
        @Sendable func afterSpeech(_ granted: Bool) {
            guard granted else { finish(.denied(speechDenied)); return }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                finish(.granted)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { finish($0 ? .granted : .denied(micDenied)) }
            default:
                finish(.denied(micDenied))
            }
        }
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            afterSpeech(true)
        } else {
            SFSpeechRecognizer.requestAuthorization { afterSpeech($0 == .authorized) }
        }
    }
}
