import Foundation
import Speech
import Testing
@testable import DWorkbench

@Suite("Chat speech local admission")
struct ChatSpeechServiceTests {
    @MainActor @Test func authorizationFromBackgroundQueueReturnsToCallerActor() async {
        let service = ChatSpeechService()
        let cases: [(SFSpeechRecognizerAuthorizationStatus, ChatSpeechAuthorization)] = [
            (.authorized, .authorized), (.denied, .denied),
            (.restricted, .restricted), (.notDetermined, .notDetermined)
        ]
        for (systemStatus, expected) in cases {
            let result = await service.requestRecognitionAuthorization { completion in
                DispatchQueue.global().async {
                    #expect(!Thread.isMainThread)
                    completion(systemStatus)
                }
            }
            MainActor.assertIsolated()
            #expect(result == expected)
            #expect(service.recognitionState == .idle)
        }
    }

    @Test func recognitionLanguageRequiresAnExplicitSupportedChoice() {
        #expect(ChatSpeechRecognitionLanguage(identifier: "zh-CN") == .mandarin)
        #expect(ChatSpeechRecognitionLanguage(identifier: "en-US") == .english)
        #expect(ChatSpeechRecognitionLanguage(identifier: nil) == nil)
        #expect(ChatSpeechRecognitionLanguage(identifier: "fr-FR") == nil)
        #expect(ChatSpeechRecognitionLanguage(identifier: "en_US") == nil)
        #expect(ChatSpeechRecognitionLanguage(identifier: "zh-HK") == nil)
        #expect(ChatSpeechRecognitionLanguage.allCases.count == 2)
    }

    @Test func recognizerLocaleAliasesKeepLanguageAndRegion() {
        for identifier in ["en-US", "en_US"] {
            #expect(ChatSpeechRecognitionLanguage.recognizerLanguage(for: identifier) == .english)
        }
        for identifier in ["zh-CN", "zh_CN", "zh-Hans-CN", "zh_Hans_CN"] {
            #expect(ChatSpeechRecognitionLanguage.recognizerLanguage(for: identifier) == .mandarin)
        }
        for identifier in ["en-GB", "en_AU", "zh-TW", "zh_Hant_TW", "zh-HK", "yue-CN", "fr-FR", "zh-Hans-HK", "en-US-x-private"] {
            #expect(ChatSpeechRecognitionLanguage.recognizerLanguage(for: identifier) == nil)
        }
        #expect(ChatSpeechRecognitionLanguage.recognizerLanguage(for: nil) == nil)
        #expect(ChatSpeechRecognitionLanguage(identifier: "zh-Hans-CN") == nil)
    }

    @Test func unsupportedRecognitionLanguageCannotBeAdmitted() {
        let unsupported = ChatSpeechCapability(localeIdentifier: "fr_FR", authorization: .authorized,
                                               recognizerAvailable: true, supportsOnDeviceRecognition: true)
        #expect(unsupported.admissionError == .localeUnsupported)
        let noChoice = ChatSpeechCapability(localeIdentifier: nil, authorization: .notDetermined,
                                           recognizerAvailable: false, supportsOnDeviceRecognition: false)
        #expect(noChoice.admissionError == .localeUnsupported)
        let otherEnglishRegion = ChatSpeechCapability(localeIdentifier: "en_GB", authorization: .authorized,
                                                       recognizerAvailable: true, supportsOnDeviceRecognition: true)
        #expect(otherEnglishRegion.admissionError == .localeUnsupported)
        let traditionalChinese = ChatSpeechCapability(localeIdentifier: "zh_Hant_TW", authorization: .authorized,
                                                       recognizerAvailable: true, supportsOnDeviceRecognition: true)
        #expect(traditionalChinese.admissionError == .localeUnsupported)
    }

    @Test func authorizationAndDeviceSupportMustBothBePresent() {
        let ready = ChatSpeechCapability(localeIdentifier: "en_US", authorization: .authorized,
                                         recognizerAvailable: true, supportsOnDeviceRecognition: true)
        #expect(ready.canTranscribeLocally)
        #expect(ready.admissionError == nil)
        let mandarin = ChatSpeechCapability(localeIdentifier: "zh_CN", authorization: .authorized,
                                            recognizerAvailable: true, supportsOnDeviceRecognition: true)
        #expect(mandarin.canTranscribeLocally)
        let scriptedMandarin = ChatSpeechCapability(localeIdentifier: "zh_Hans_CN", authorization: .authorized,
                                                    recognizerAvailable: true, supportsOnDeviceRecognition: true)
        #expect(scriptedMandarin.canTranscribeLocally)

        let noPermission = ChatSpeechCapability(localeIdentifier: "en_US", authorization: .notDetermined,
                                                recognizerAvailable: true, supportsOnDeviceRecognition: true)
        #expect(noPermission.admissionError == .authorizationRequired)

        let cloudOnly = ChatSpeechCapability(localeIdentifier: "en_US", authorization: .authorized,
                                            recognizerAvailable: true, supportsOnDeviceRecognition: false)
        #expect(!cloudOnly.canTranscribeLocally)
        #expect(cloudOnly.admissionError == .onDeviceUnavailable)

        let unavailable = ChatSpeechCapability(localeIdentifier: "en_US", authorization: .authorized,
                                              recognizerAvailable: false, supportsOnDeviceRecognition: true)
        #expect(unavailable.admissionError == .recognizerUnavailable)

        let wrongLocale = ChatSpeechCapability(localeIdentifier: nil, authorization: .authorized,
                                              recognizerAvailable: false, supportsOnDeviceRecognition: false)
        #expect(wrongLocale.admissionError == .localeUnsupported)
    }

    @Test func finalResultNeedsEndAcknowledgmentBeforeRelease() {
        var lifecycle = ChatSpeechLifecycle()
        lifecycle.receiveFinal("recognized words")
        #expect(lifecycle.finalText == "recognized words")
        #expect(!lifecycle.canRelease)
        let ended = lifecycle.acknowledgeEnd(); #expect(ended)
        #expect(lifecycle.canRelease)
        let duplicate = lifecycle.acknowledgeEnd(); #expect(!duplicate)
    }

    @Test func cancellationRetainsOwnershipUntilEnd() {
        var lifecycle = ChatSpeechLifecycle()
        lifecycle.receiveFinal("old result")
        let stopped = lifecycle.requestStop(.cancelled); #expect(stopped)
        #expect(lifecycle.state == .stopping(.cancelled))
        #expect(lifecycle.finalText == nil)
        lifecycle.receiveFinal("late result")
        #expect(lifecycle.finalText == nil)
        #expect(!lifecycle.canRelease)
        lifecycle.markStalled()
        #expect(lifecycle.state == .stalledDrain(.cancelled))
        #expect(!lifecycle.canRelease)
        let ended = lifecycle.acknowledgeEnd(); #expect(ended)
        #expect(lifecycle.canRelease)
    }

    @Test func cancelledRecognitionCannotOfferLateTextForAdoption() {
        var lifecycle = ChatSpeechLifecycle()
        lifecycle.receiveFinal("candidate transcript")
        #expect(lifecycle.finalText == "candidate transcript")
        let stopped = lifecycle.requestStop(.cancelled)
        #expect(stopped)
        lifecycle.receiveFinal("late transcript")
        #expect(lifecycle.finalText == nil)
        #expect(!lifecycle.canRelease)
        let ended = lifecycle.acknowledgeEnd()
        #expect(ended)
        #expect(lifecycle.stopReason == .cancelled)
        #expect(lifecycle.finalText == nil)
    }

    @Test func timeoutAndMissingAcknowledgmentCannotAdmitRetry() {
        let oldID = UUID()
        let retryID = UUID()
        var old = ChatSpeechLifecycle(id: oldID)
        let stopped = old.requestStop(.timedOut); #expect(stopped)
        old.markStalled()
        #expect(old.stopReason == .timedOut)
        #expect(old.state == .stalledDrain(.timedOut))
        #expect(!old.canRelease)
        let duplicate = old.requestStop(.cancelled); #expect(!duplicate)
        old.receiveFinal("late old result")
        #expect(old.finalText == nil)

        let ended = old.acknowledgeEnd(); #expect(ended)
        #expect(old.canRelease)
        var retry = ChatSpeechLifecycle(id: retryID)
        #expect(!retry.acceptsCallback(id: oldID))
        #expect(retry.acceptsCallback(id: retryID))
        retry.receiveFinal("new result")
        #expect(retry.finalText == "new result")
        #expect(!retry.canRelease)
    }

    @Test func errorsHaveReadableDescriptions() {
        #expect(ChatSpeechError.timedOut.localizedDescription.contains("too long"))
        #expect(ChatSpeechError.busy.localizedDescription.contains("still in use"))
    }
}
