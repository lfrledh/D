import Foundation
import Testing
@testable import DWorkbench

@Suite("Chat speech local admission")
struct ChatSpeechServiceTests {
    @Test func authorizationAndDeviceSupportMustBothBePresent() {
        let ready = ChatSpeechCapability(localeIdentifier: "en_US", authorization: .authorized,
                                         recognizerAvailable: true, supportsOnDeviceRecognition: true)
        #expect(ready.canTranscribeLocally)
        #expect(ready.admissionError == nil)

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
        #expect(lifecycle.acknowledgeEnd())
        #expect(lifecycle.canRelease)
        #expect(!lifecycle.acknowledgeEnd())
    }

    @Test func cancellationRetainsOwnershipUntilEnd() {
        var lifecycle = ChatSpeechLifecycle()
        lifecycle.receiveFinal("old result")
        #expect(lifecycle.requestStop(.cancelled))
        #expect(lifecycle.state == .stopping(.cancelled))
        #expect(lifecycle.finalText == nil)
        lifecycle.receiveFinal("late result")
        #expect(lifecycle.finalText == nil)
        #expect(!lifecycle.canRelease)
        lifecycle.markStalled()
        #expect(lifecycle.state == .stalledDrain(.cancelled))
        #expect(!lifecycle.canRelease)
        #expect(lifecycle.acknowledgeEnd())
        #expect(lifecycle.canRelease)
    }

    @Test func timeoutAndMissingAcknowledgmentCannotAdmitRetry() {
        let oldID = UUID()
        let retryID = UUID()
        var old = ChatSpeechLifecycle(id: oldID)
        #expect(old.requestStop(.timedOut))
        old.markStalled()
        #expect(old.stopReason == .timedOut)
        #expect(old.state == .stalledDrain(.timedOut))
        #expect(!old.canRelease)
        #expect(!old.requestStop(.cancelled))
        old.receiveFinal("late old result")
        #expect(old.finalText == nil)

        #expect(old.acknowledgeEnd())
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
