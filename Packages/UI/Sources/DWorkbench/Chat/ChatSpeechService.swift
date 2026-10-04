@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation
import Synchronization

public enum ChatSpeechError: Error, Sendable, Equatable {
    case invalidFile
    case invalidTimeout
    case busy
    case authorizationRequired
    case authorizationDenied
    case localeUnsupported
    case onDeviceUnavailable
    case recognizerUnavailable
    case timedOut
    case recognitionFailed(String)
    case emptyText
    case voiceUnavailable
    case invalidRate
}

extension ChatSpeechError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose a recording stored on this Mac."
        case .invalidTimeout: "Choose a recognition timeout between 1 and 600 seconds."
        case .busy: "Speech is still in use. Try again when it has stopped."
        case .authorizationRequired: "Allow speech recognition before transcribing."
        case .authorizationDenied: "Speech recognition is disabled for this app. Check its system permission."
        case .localeUnsupported: "Speech recognition is unavailable for this language."
        case .onDeviceUnavailable: "On-device speech recognition is unavailable for this language."
        case .recognizerUnavailable: "Speech recognition is currently unavailable."
        case .timedOut: "Speech recognition took too long and was stopped."
        case .recognitionFailed(let message): message
        case .emptyText: "Enter text to read aloud."
        case .voiceUnavailable: "The selected system voice is unavailable."
        case .invalidRate: "Choose a reading speed within the system voice range."
        }
    }
}

public enum ChatSpeechAuthorization: Sendable, Equatable {
    case notDetermined, denied, restricted, authorized

    init(_ status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .authorized: self = .authorized
        @unknown default: self = .restricted
        }
    }
}

/// The two explicit recognition choices for this release. TTS voices remain independent.
public enum ChatSpeechRecognitionLanguage: String, CaseIterable, Identifiable, Sendable {
    case mandarin = "zh-CN"
    case english = "en-US"

    public var id: String { rawValue }

    public init?(identifier: String?) {
        guard let identifier, let language = Self(rawValue: identifier) else { return nil }
        self = language
    }

    fileprivate static func includesRecognizerLocale(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return allCases.contains { Locale(identifier: $0.rawValue).identifier == identifier }
    }
}

public struct ChatSpeechCapability: Sendable, Equatable {
    public let localeIdentifier: String?
    public let authorization: ChatSpeechAuthorization
    public let recognizerAvailable: Bool
    public let supportsOnDeviceRecognition: Bool

    public var canTranscribeLocally: Bool {
        admissionError == nil
    }

    var admissionError: ChatSpeechError? {
        guard ChatSpeechRecognitionLanguage.includesRecognizerLocale(localeIdentifier) else {
            return .localeUnsupported
        }
        guard authorization == .authorized else {
            return authorization == .notDetermined ? .authorizationRequired : .authorizationDenied
        }
        guard supportsOnDeviceRecognition else { return .onDeviceUnavailable }
        guard recognizerAvailable else { return .recognizerUnavailable }
        return nil
    }
}

public struct ChatSpeechTranscript: Sendable, Equatable {
    public let text: String
    public let localeIdentifier: String
    public let route: String
    public let sourceURL: URL
}

public struct ChatSystemVoice: Sendable, Equatable, Identifiable {
    public let id: String
    public let language: String
    public let name: String
}

public enum ChatSpeechPlaybackState: Sendable, Equatable {
    case idle, speaking, paused, stopping
}

public enum ChatSpeechStopReason: Sendable, Equatable {
    case cancelled, timedOut
}

public enum ChatSpeechRecognitionState: Sendable, Equatable {
    case idle, recognizing, stopping(ChatSpeechStopReason), stalledDrain(ChatSpeechStopReason)
}

/// The same transition rules used by the service. Only an SDK end acknowledgment releases
/// admission; a stop request, final text, or elapsed wall time cannot do so.
struct ChatSpeechLifecycle: Sendable {
    let id: UUID
    private(set) var state: ChatSpeechRecognitionState = .recognizing
    private(set) var finalText: String?
    private(set) var ended = false

    init(id: UUID = UUID()) { self.id = id }

    func acceptsCallback(id: UUID) -> Bool { self.id == id && !ended }

    mutating func receiveFinal(_ text: String) {
        guard state == .recognizing, !ended else { return }
        finalText = text
    }

    mutating func requestStop(_ reason: ChatSpeechStopReason) -> Bool {
        guard state == .recognizing, !ended else { return false }
        state = .stopping(reason)
        finalText = nil
        return true
    }

    mutating func markStalled() {
        guard case .stopping(let reason) = state, !ended else { return }
        state = .stalledDrain(reason)
    }

    mutating func acknowledgeEnd() -> Bool {
        guard !ended else { return false }
        ended = true
        return true
    }

    var stopReason: ChatSpeechStopReason? {
        switch state {
        case .stopping(let reason), .stalledDrain(let reason): reason
        case .idle, .recognizing: nil
        }
    }

    var canRelease: Bool { ended }
}

private final class ChatSpeechRecognitionDelegate: NSObject, SFSpeechRecognitionTaskDelegate {
    let id: UUID
    weak var owner: ChatSpeechService?
    private let finalText = Mutex<String?>(nil)

    init(id: UUID, owner: ChatSpeechService) {
        self.id = id
        self.owner = owner
    }

    func speechRecognitionTask(
        _ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult
    ) {
        finalText.withLock { $0 = result.bestTranscription.formattedString }
    }

    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        let id = id
        let owner = owner
        Task { @MainActor [weak owner] in owner?.sdkCancelled(id: id) }
    }

    func speechRecognitionTask(
        _ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool
    ) {
        let id = id
        let owner = owner
        let text = finalText.withLock { $0 }
        let wasCancelled = task.isCancelled
        let message = ChatSpeechService.readableRecognitionFailure(task.error)
        Task { @MainActor [weak owner] in
            owner?.finishRecognition(id: id, successfully: successfully,
                                     wasCancelled: wasCancelled, finalText: text,
                                     failureMessage: message)
        }
    }
}

/// Owns one file recognition at a time and only the utterances queued on its own synthesizer.
/// The caller retains access to the file until transcribeFile returns, including SDK drain.
/// No result is sent to chat.
@MainActor
public final class ChatSpeechService: NSObject, AVSpeechSynthesizerDelegate {
    private final class CancellationLatch: Sendable {
        private enum State: Sendable, Equatable { case pending, cancelled, completed }
        private let value = Mutex(State.pending)
        var isCancelled: Bool { value.withLock { $0 == .cancelled } }
        func cancel() {
            value.withLock { if $0 == .pending { $0 = .cancelled } }
        }
        func claimCompletion() -> Bool {
            value.withLock {
                guard $0 == .pending else { return false }
                $0 = .completed
                return true
            }
        }
    }

    private final class Recognition {
        let id: UUID
        let localeIdentifier: String
        let sourceURL: URL
        let recognizer: SFSpeechRecognizer
        let request: SFSpeechURLRecognitionRequest
        let cancellation: CancellationLatch
        let delegate: ChatSpeechRecognitionDelegate
        var task: SFSpeechRecognitionTask?
        var continuation: CheckedContinuation<ChatSpeechTranscript, Error>?
        var watchdog: Task<Void, Never>?
        var drainNotice: Task<Void, Never>?
        var lifecycle: ChatSpeechLifecycle

        init(id: UUID, localeIdentifier: String, sourceURL: URL,
             recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest,
             cancellation: CancellationLatch, delegate: ChatSpeechRecognitionDelegate,
             continuation: CheckedContinuation<ChatSpeechTranscript, Error>) {
            self.id = id
            self.localeIdentifier = localeIdentifier
            self.sourceURL = sourceURL
            self.recognizer = recognizer
            self.request = request
            self.cancellation = cancellation
            self.delegate = delegate
            self.continuation = continuation
            self.lifecycle = ChatSpeechLifecycle(id: id)
        }
    }

    private var recognition: Recognition?
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var selectedVoiceID: String?
    private var selectedLanguage: String = AVSpeechSynthesisVoice.currentLanguageCode()
    private var selectedRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var playbackDrain: [CheckedContinuation<Void, Never>] = []
    public private(set) var playbackState: ChatSpeechPlaybackState = .idle {
        didSet {
            if playbackState != oldValue { onPlaybackStateChange?(playbackState) }
            if playbackState == .idle {
                let waiting = playbackDrain; playbackDrain.removeAll()
                for continuation in waiting { continuation.resume() }
            }
        }
    }
    public var onPlaybackStateChange: (@MainActor (ChatSpeechPlaybackState) -> Void)?
    public private(set) var recognitionState: ChatSpeechRecognitionState = .idle {
        didSet { if recognitionState != oldValue { onRecognitionStateChange?(recognitionState) } }
    }
    public var onRecognitionStateChange: (@MainActor (ChatSpeechRecognitionState) -> Void)?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Reads system state only. This never requests speech or microphone authorization.
    public func capability(localeIdentifier: String? = nil) -> ChatSpeechCapability {
        let recognizer = makeRecognizer(localeIdentifier: localeIdentifier)
        return ChatSpeechCapability(
            localeIdentifier: recognizer?.locale.identifier,
            authorization: ChatSpeechAuthorization(SFSpeechRecognizer.authorizationStatus()),
            recognizerAvailable: recognizer?.isAvailable ?? false,
            supportsOnDeviceRecognition: recognizer?.supportsOnDeviceRecognition ?? false
        )
    }

    /// An explicit caller action only. The host App must supply NSSpeechRecognitionUsageDescription.
    public func requestRecognitionAuthorization() async -> ChatSpeechAuthorization {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: ChatSpeechAuthorization(status))
            }
        }
    }

    /// A finite processing budget for a short file, not a product limit on audio length.
    /// Cancellation and timeout request a stop immediately, but return only after Speech
    /// confirms the task ended. A missing acknowledgment is visible as stalledDrain.
    public func transcribeFile(
        at url: URL, localeIdentifier: String? = nil, timeoutSeconds: Double = 120
    ) async throws -> ChatSpeechTranscript {
        defer { withExtendedLifetime(self) {} }
        guard recognition == nil else { throw ChatSpeechError.busy }
        guard timeoutSeconds.isFinite, (1...600).contains(timeoutSeconds) else {
            throw ChatSpeechError.invalidTimeout
        }
        guard url.isFileURL, !url.hasDirectoryPath else { throw ChatSpeechError.invalidFile }
        let resolvedURL = url.resolvingSymlinksInPath()
        let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .volumeIsLocalKey])
        guard values?.isRegularFile == true, values?.volumeIsLocal == true else {
            throw ChatSpeechError.invalidFile
        }
        let recognizer = makeRecognizer(localeIdentifier: localeIdentifier)
        let capability = ChatSpeechCapability(
            localeIdentifier: recognizer?.locale.identifier,
            authorization: ChatSpeechAuthorization(SFSpeechRecognizer.authorizationStatus()),
            recognizerAvailable: recognizer?.isAvailable ?? false,
            supportsOnDeviceRecognition: recognizer?.supportsOnDeviceRecognition ?? false
        )
        if let error = capability.admissionError { throw error }
        guard let recognizer else { throw ChatSpeechError.localeUnsupported }

        let request = SFSpeechURLRecognitionRequest(url: resolvedURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        let id = UUID()
        let cancellation = CancellationLatch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let delegate = ChatSpeechRecognitionDelegate(id: id, owner: self)
                let current = Recognition(id: id, localeIdentifier: recognizer.locale.identifier,
                                          sourceURL: url, recognizer: recognizer,
                                          request: request, cancellation: cancellation,
                                          delegate: delegate,
                                          continuation: continuation)
                recognition = current
                let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                current.watchdog = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
                    self?.timeoutRecognition(id: id)
                }
                current.task = recognizer.recognitionTask(with: request, delegate: delegate)
                if cancellation.isCancelled { cancelRecognition(id: id) }
                recognitionState = current.lifecycle.state
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancelRecognition(id: id) }
        }
    }

    public func cancelTranscription() {
        guard let recognition else { return }
        cancelRecognition(id: recognition.id)
    }

    public var availableVoices: [ChatSystemVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isPersonalVoice) }
            .map { ChatSystemVoice(id: $0.identifier, language: $0.language, name: $0.name) }
            .sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
    }

    public var rateRange: ClosedRange<Float> {
        AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate
    }

    public var voiceID: String? { selectedVoiceID }
    public var language: String { selectedLanguage }
    public var rate: Float { selectedRate }

    public func selectVoice(id: String) throws {
        guard let voice = AVSpeechSynthesisVoice(identifier: id),
              !voice.voiceTraits.contains(.isPersonalVoice) else { throw ChatSpeechError.voiceUnavailable }
        selectedVoiceID = voice.identifier
        selectedLanguage = voice.language
    }

    public func selectLanguage(_ language: String) throws {
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: {
            $0.language == language && !$0.voiceTraits.contains(.isPersonalVoice)
        }) else { throw ChatSpeechError.voiceUnavailable }
        selectedLanguage = voice.language
        selectedVoiceID = nil
    }

    public func selectSystemDefaultVoice() throws {
        try selectLanguage(AVSpeechSynthesisVoice.currentLanguageCode())
    }

    public func setRate(_ rate: Float) throws {
        guard rate.isFinite, rateRange.contains(rate) else { throw ChatSpeechError.invalidRate }
        selectedRate = rate
    }

    public func speak(_ text: String) throws {
        guard playbackState == .idle, !synthesizer.isSpeaking else { throw ChatSpeechError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatSpeechError.emptyText
        }
        let voice: AVSpeechSynthesisVoice?
        if let selectedVoiceID {
            voice = AVSpeechSynthesisVoice(identifier: selectedVoiceID)
        } else {
            voice = AVSpeechSynthesisVoice.speechVoices().first(where: {
                $0.language == selectedLanguage && !$0.voiceTraits.contains(.isPersonalVoice)
            })
        }
        guard let voice, !voice.voiceTraits.contains(.isPersonalVoice) else {
            throw ChatSpeechError.voiceUnavailable
        }
        let next = AVSpeechUtterance(string: text)
        next.voice = voice
        next.rate = selectedRate
        utterance = next
        synthesizer.speak(next)
        playbackState = .speaking
    }

    public func pauseSpeech() {
        guard playbackState == .speaking, synthesizer.pauseSpeaking(at: .immediate) else { return }
        playbackState = .paused
    }

    public func resumeSpeech() {
        guard playbackState == .paused, synthesizer.continueSpeaking() else { return }
        playbackState = .speaking
    }

    public func stopSpeech() {
        guard utterance != nil, playbackState != .stopping else { return }
        if synthesizer.stopSpeaking(at: .immediate) {
            playbackState = .stopping
        } else if !synthesizer.isSpeaking, !synthesizer.isPaused {
            utterance = nil
            playbackState = .idle
        }
    }

    /// Closing waits for this synthesizer's terminal acknowledgment, including paused speech.
    public func stopSpeechAndWait() async {
        stopSpeech()
        guard playbackState != .idle else { return }
        await withCheckedContinuation { playbackDrain.append($0) }
    }

    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishSpeech(identity: identity) }
    }

    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishSpeech(identity: identity) }
    }

    private func finishSpeech(identity: ObjectIdentifier) {
        guard let utterance, ObjectIdentifier(utterance) == identity else { return }
        self.utterance = nil
        playbackState = .idle
    }

    private func makeRecognizer(localeIdentifier: String?) -> SFSpeechRecognizer? {
        guard let language = ChatSpeechRecognitionLanguage(identifier: localeIdentifier) else { return nil }
        let requested = Locale(identifier: language.rawValue)
        guard SFSpeechRecognizer.supportedLocales().contains(where: {
            $0.identifier == requested.identifier
        }) else { return nil }
        let recognizer = SFSpeechRecognizer(locale: requested)
        guard recognizer?.locale.identifier == requested.identifier else { return nil }
        return recognizer
    }

    fileprivate func sdkCancelled(id: UUID) {
        guard let current = recognition, current.lifecycle.acceptsCallback(id: id) else { return }
        beginDrain(id: id, reason: .cancelled)
        if current.task?.state == .completed {
            finishRecognition(id: id, successfully: false, wasCancelled: true,
                              finalText: nil, failureMessage: nil)
        }
    }

    fileprivate func finishRecognition(id: UUID, successfully: Bool,
                                       wasCancelled: Bool, finalText: String?,
                                       failureMessage: String?) {
        guard let current = recognition, current.lifecycle.acceptsCallback(id: id) else { return }
        if wasCancelled, current.lifecycle.requestStop(.cancelled) {
            recognitionState = current.lifecycle.state
        }
        if let finalText { current.lifecycle.receiveFinal(finalText) }
        guard current.lifecycle.acknowledgeEnd() else { return }
        current.watchdog?.cancel()
        current.drainNotice?.cancel()
        let continuation = current.continuation
        current.continuation = nil
        let completionClaimed = current.cancellation.claimCompletion()
        let result: Result<ChatSpeechTranscript, Error>
        if let reason = current.lifecycle.stopReason {
            if reason == .timedOut {
                result = .failure(ChatSpeechError.timedOut)
            } else {
                result = .failure(CancellationError())
            }
        } else if !completionClaimed {
            result = .failure(CancellationError())
        } else if successfully, let text = current.lifecycle.finalText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = .success(ChatSpeechTranscript(text: text,
                                                   localeIdentifier: current.localeIdentifier,
                                                   route: "Apple Speech on-device",
                                                   sourceURL: current.sourceURL))
        } else {
            result = .failure(ChatSpeechError.recognitionFailed(
                failureMessage ?? "No speech was recognized in this recording."
            ))
        }
        recognition = nil
        recognitionState = .idle
        continuation?.resume(with: result)
    }

    private func cancelRecognition(id: UUID) {
        beginDrain(id: id, reason: .cancelled)
    }

    private func timeoutRecognition(id: UUID) {
        beginDrain(id: id, reason: .timedOut)
    }

    private func beginDrain(id: UUID, reason: ChatSpeechStopReason) {
        guard let current = recognition, current.lifecycle.acceptsCallback(id: id),
              current.lifecycle.requestStop(reason) else { return }
        recognitionState = current.lifecycle.state
        current.watchdog?.cancel()
        current.task?.cancel()
        current.drainNotice = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            self?.inspectDrain(id: id)
        }
    }

    private func inspectDrain(id: UUID) {
        guard let current = recognition, current.lifecycle.acceptsCallback(id: id) else { return }
        if current.task?.state == .completed {
            finishRecognition(id: id, successfully: false, wasCancelled: current.task?.isCancelled == true,
                              finalText: nil,
                              failureMessage: Self.readableRecognitionFailure(current.task?.error))
        } else {
            current.lifecycle.markStalled()
            recognitionState = current.lifecycle.state
        }
    }

    /// Checks the SDK state once when the UI asks after a stalled drain. This never
    /// starts another task and never treats elapsed time as completion.
    public func refreshRecognitionDrain() {
        guard case .stalledDrain = recognitionState, let id = recognition?.id else { return }
        inspectDrain(id: id)
    }

    fileprivate nonisolated static func readableRecognitionFailure(_ error: Error?) -> String? {
        guard let error = error as NSError? else { return nil }
        switch (error.domain, error.code) {
        case ("kLSRErrorDomain", 102):
            return "The on-device speech resources for this language are unavailable."
        case ("kLSRErrorDomain", 201), ("kAFAssistantErrorDomain", 1700):
            return "Speech recognition is disabled. Check system speech permissions."
        case ("kAFAssistantErrorDomain", 1110):
            return "No speech was recognized in this recording."
        default:
            return "Speech recognition failed. Try another recording or language."
        }
    }
}
