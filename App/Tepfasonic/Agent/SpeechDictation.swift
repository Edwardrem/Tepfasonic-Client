import Accelerate
import AVFoundation
import Observation
import os
import Speech

/// The microphone's input level while dictating. The audio thread writes it,
/// the composer's meter reads it a few times a second; nothing here touches the
/// main actor, so the realtime thread never waits on the UI.
final class DictationMeter: Sendable {
    private struct Levels { var level: Float = 0; var peak: Float = 0 }
    private let state = OSAllocatedUnfairLock(initialState: Levels())

    /// 0 (silence) to 1 (loud), from the most recent audio buffer.
    var level: Float { state.withLock { $0.level } }
    /// The loudest level since the session began.
    var peak: Float { state.withLock { $0.peak } }

    func reset() { state.withLock { $0 = Levels() } }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let level = min(max((decibels + 55) / 45, 0), 1)   // −55 dB → 0, −10 dB → 1
        state.withLock {
            $0.level = level
            $0.peak = max($0.peak, level)
        }
    }
}

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
    /// Why dictation could not start, stopped, or heard nothing.
    private(set) var errorMessage: String?
    /// When the current recording began, for the elapsed-time readout.
    private(set) var startedAt: Date?

    /// Live input level, so the composer can show that the microphone is picking sound up.
    let meter = DictationMeter()

    var isListening: Bool { status == .listening }

    /// On-device dictation is possible for the current language. When false the
    /// view hides the microphone rather than offer a server round-trip.
    var isAvailable: Bool { recognizer?.supportsOnDeviceRecognition == true }

    private let recognizer = SpeechDictation.makeRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: ((String) -> Void)?
    /// Counts recordings, so a late result from an earlier one is ignored.
    private var generation = 0
    private var silenceCheck: Task<Void, Never>?

    /// Below this peak the microphone delivered no sound at all (muted, wrong input).
    private static let silentPeak: Float = 0.02
    private static let silentMicrophone = "No sound is reaching the microphone. Check the input device and its level in System Settings › Sound › Input."
    private static let nothingRecognised = "No speech was recognised, so nothing was added. Try again and speak once the red meter moves."

    /// The recognizer for the user's language, or the nearest one that can
    /// transcribe on this Mac: a region without its own on-device model
    /// (en_ZW, say) falls back through the preferred languages to US English.
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        let candidates = [Locale.current] + Locale.preferredLanguages.map(Locale.init(identifier:)) + [Locale(identifier: "en-US")]
        var first: SFSpeechRecognizer?
        for locale in candidates {
            guard let recognizer = SFSpeechRecognizer(locale: locale) else { continue }
            if recognizer.supportsOnDeviceRecognition { return recognizer }
            first = first ?? recognizer
        }
        return first
    }

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

    /// Stops recording and drops whatever the recognizer still delivers: the
    /// composer is sending the text it already has.
    func finish() {
        onUpdate = nil
        stop()
    }

    func stop() {
        guard isListening else { teardown(); return }
        status = .idle
        startedAt = nil
        silenceCheck?.cancel()
        request?.endAudio()          // flush remaining audio → a final result arrives
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // `task` is left to deliver its final transcript; the result handler tears it down.
    }

    // MARK: - Session

    private func beginSession(_ recognizer: SFSpeechRecognizer) {
        task?.cancel()   // an earlier recording still flushing its last words
        generation += 1
        let generation = generation
        meter.reset()
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

        Self.installTap(on: input, format: format, feeding: request, meter: meter)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            errorMessage = "The microphone could not be started."
            teardown()
            return
        }
        status = .listening
        startedAt = .now

        // The result handler is called off the main actor; hop back with Sendable values only.
        nonisolated(unsafe) weak var me = self
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in me?.handleResult(text: text, isFinal: isFinal, failure: failure, generation: generation) }
        }

        // A few seconds in, say so if the microphone has delivered nothing but
        // silence: otherwise a muted or wrong input looks exactly like recording.
        silenceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.isListening, self.generation == generation else { return }
            if self.meter.peak < Self.silentPeak { self.errorMessage = Self.silentMicrophone }
        }
    }

    /// The tap block runs on a realtime audio thread, so it is built outside the
    /// main actor and captures only the request (designed to be fed buffers from
    /// there) and the lock-protected meter.
    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, feeding request: SFSpeechAudioBufferRecognitionRequest, meter: DictationMeter) {
        nonisolated(unsafe) let sink = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
            meter.ingest(buffer)
        }
    }

    private func handleResult(text: String?, isFinal: Bool, failure: String?, generation: Int) {
        guard generation == self.generation else { return }
        if let text, !text.isEmpty {
            transcript = text
            onUpdate?(text)
            if errorMessage == Self.silentMicrophone { errorMessage = nil }
        }
        guard isFinal || failure != nil else { return }
        let endedOnItsOwn = isListening
        let reporting = onUpdate != nil
        teardown()
        // Say why nothing (or nothing more) landed in the message; silence here
        // would leave the user guessing whether the recording was heard.
        guard reporting else { return }
        if endedOnItsOwn, let failure {
            let reason = failure.hasSuffix(".") ? String(failure.dropLast()) : failure
            errorMessage = "Dictation stopped: \(reason). If this keeps happening, turn on Dictation in System Settings › Keyboard so macOS installs the speech model for your language."
        } else if transcript.isEmpty {
            errorMessage = meter.peak < Self.silentPeak ? Self.silentMicrophone : Self.nothingRecognised
        }
    }

    private func teardown() {
        silenceCheck?.cancel()
        silenceCheck = nil
        startedAt = nil
        onUpdate = nil
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

#if DEBUG
extension SpeechDictation {
    /// `--qa-dictation-demo`: the recording state without a microphone, so the
    /// composer's meter can be screenshotted.
    func showListeningForQA() {
        status = .listening
        startedAt = .now.addingTimeInterval(-7)
        meter.setLevelForQA(0.5)
    }
}

extension DictationMeter {
    func setLevelForQA(_ level: Float) {
        state.withLock {
            $0.level = level
            $0.peak = level
        }
    }
}
#endif
