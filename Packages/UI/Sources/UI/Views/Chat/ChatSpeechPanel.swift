import DWorkbench
import AVFAudio
import SwiftUI

/// System speech is explicit and independent of the selected generation model.
struct ChatSpeechPanel: View {
    let chat: ChatController
    let project: ProjectSession
    let sessionID: UUID
    let onImportAudio: (String) -> Void
    var onOpenSettings: (() -> Void)? = nil
    @Environment(\.dLanguageStore) private var language
    @State private var recognitionLanguage: ChatSpeechRecognitionLanguage?
    @State private var capability: ChatSpeechCapability?
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflowText(language, "chat.speechPanel.voiceInput")).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text(workflowText(language, "chat.speechPanel.onDeviceTranscriptionOnlyTheOriginalRecordingIsKeptReview"))
                    .font(.caption).foregroundStyle(.secondary)
                WorkbenchPicker(workflowText(language, "chat.speechPanel.recognitionLanguage"), selection: $recognitionLanguage) {
                    WorkbenchChoice(workflowText(language, "chat.speechPanel.chooseALanguage"), value:nil as ChatSpeechRecognitionLanguage?)
                    WorkbenchChoice(workflowText(language, "chat.speechPanel.mandarinChineseZhCN"), value:Optional(ChatSpeechRecognitionLanguage.mandarin))
                    WorkbenchChoice(workflowText(language, "chat.speechPanel.englishEnUS"), value:Optional(ChatSpeechRecognitionLanguage.english))
                }
                    .disabled(chat.isTranscribing || project.chatRecordingSessionID != nil)
                    .accessibilityIdentifier("chat-recognition-language")
                    .onChange(of: recognitionLanguage) { _, value in
                        capability = value.map { chat.speech.capability(localeIdentifier: $0.rawValue) }
                    }
                if let recognitionLanguage, let capability {
                    Text(workflowText(language, "chat.speechPanel.selectedLanguage", arguments: ["language": String(recognitionLanguage.rawValue)]))
                        .font(.caption)
                    Text(workflowText(language, "chat.speechPanel.permission", arguments: ["status": String(authorizationText(capability.authorization))]))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(capability.supportsOnDeviceRecognition
                         ? workflowText(language, "chat.speechPanel.offlineResourcesUnconfirmedUntilTranscriptionOnDeviceRecognitionIsSupported")
                         : workflowText(language, "chat.speechPanel.offlineResourcesUnavailableForThisLanguage"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(capability.recognizerAvailable
                         ? workflowText(language, "chat.speechPanel.recognizerCurrentlyAvailable")
                         : workflowText(language, "chat.speechPanel.recognizerCurrentlyUnavailable"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(workflowText(language, "chat.speechPanel.chooseALanguageBeforeTranscribingOrRecording"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if capability?.authorization == .notDetermined, capability?.localeIdentifier != nil {
                    Button(workflowText(language, "chat.speechPanel.authorizeLocalTranscription")) {
                        Task {
                            _ = await chat.speech.requestRecognitionAuthorization()
                            capability = recognitionLanguage.map {
                                chat.speech.capability(localeIdentifier: $0.rawValue)
                            }
                        }
                    }
                }
                HStack {
                    Button(workflowText(language, "chat.speechPanel.chooseAudioAndTranscribe")) {
                        if let recognitionLanguage { onImportAudio(recognitionLanguage.rawValue) }
                    }
                        .disabled(project.isBusy || capability?.canTranscribeLocally != true)
                        .accessibilityIdentifier("chat-transcribe-file")
                    if project.chatRecordingSessionID != nil {
                        Button(workflowText(language, "chat.speechPanel.finishRecording")) { Task { await project.finishChatRecording() } }
                            .buttonStyle(WorkbenchPrimaryButtonStyle())
                    } else {
                        Button(workflowText(language, "chat.speechPanel.recordVoice")) {
                            if let recognitionLanguage {
                                Task { await project.startChatRecording(sessionID: sessionID, controller: chat,
                                                                        locale: recognitionLanguage.rawValue) }
                            }
                        }.disabled(project.isBusy || capability?.canTranscribeLocally != true)
                    }
                    if chat.isTranscribing {
                        Button(workflowText(language, "chat.speechPanel.stopTranscription")) { Task { await chat.cancelSpeechTranscription() } }
                        Text(chatRecognitionText(chat.speechRecognitionState, language: language)).font(.caption)
                    }
                }
                if let draft = chat.speechDrafts[sessionID] {
                    Text(draft.textSnapshot ?? "").textSelection(.enabled)
                    HStack {
                        Button(workflowText(language, "chat.speechPanel.appendToDraft")) { change { try chat.adoptSpeechDraft(sessionID: sessionID) } }
                        Button(workflowText(language, "chat.speechPanel.dismissTranscript")) { change { try chat.discardSpeechDraft(sessionID: sessionID) } }
                    }
                }
                Divider()
                Button(workflowText(language, "chat.speechPanel.voiceAndSpeedSettings")) { onOpenSettings?() }
                    .disabled(onOpenSettings == nil)
                HStack {
                    Button(workflowText(language, "chat.speechPanel.readDraft")) {
                        change { try chat.speech.speak(chat.state.sessions.first { $0.id == sessionID }?.draft ?? "") }
                    }.disabled(chat.speechPlaybackState != .idle)
                    if chat.speechPlaybackState == .speaking { Button(workflowText(language, "workflow.preview.pause")) { chat.speech.pauseSpeech() } }
                    if chat.speechPlaybackState == .paused { Button(workflowText(language, "chat.speechPanel.resume")) { chat.speech.resumeSpeech() } }
                    if chat.speechPlaybackState != .idle { Button(workflowText(language, "chat.speechPanel.stopReading")) { chat.speech.stopSpeech() } }
                }
                if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red).textSelection(.enabled) }
                if let message = project.errorMessage { Text(message).foregroundStyle(.red).font(.caption) }
            }
        }.task {
            if let recognitionLanguage {
                capability = chat.speech.capability(localeIdentifier: recognitionLanguage.rawValue)
            }
        }
    }
    private func authorizationText(_ authorization: ChatSpeechAuthorization) -> String {
        switch authorization {
        case .notDetermined: workflowText(language, "chat.speechPanel.notRequested")
        case .denied: workflowText(language, "chat.speechPanel.denied")
        case .restricted: workflowText(language, "chat.speechPanel.restricted")
        case .authorized: workflowText(language, "chat.speechPanel.allowed")
        }
    }
    private func change(_ action: () throws -> Void) {
        do { try action(); issue = nil } catch { issue = error.localizedDescription }
    }
}
