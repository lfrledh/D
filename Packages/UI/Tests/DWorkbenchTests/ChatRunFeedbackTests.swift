import Foundation
import Testing
@testable import DWorkbench

@Suite("Measured chat feedback")
struct ChatRunFeedbackTests {
    @Test func runtimeProjectionNeverBorrowsAnotherRequestsPhase() {
        let a = UUID(), b = UUID(), c = UUID()
        let status = WorkbenchRuntimeStatus(activeRunID: a, phase: "Loading A", queuedRunIDs: [b])
        #expect(status.phase(for: a) == "Loading A")
        #expect(status.phase(for: b) == "Queued / 正在排队")
        #expect(status.phase(for: c) == nil)
    }
    @Test func metadataIsMeasuredBoundedAndUnknownIsNotZero() {
        let known = ChatRunFeedback(metadata: ["promptTokens": "12", "generationTokens": "34",
            "application.stream.seconds": "45.5", "generationSeconds": "2.3", "loadingStrategy": "ssdLayered"])
        #expect(known.promptTokens == 12 && known.generationTokens == 34)
        #expect(known.applicationSeconds == 45.5 && known.generationSeconds == 2.3)
        #expect(known.loadingStrategy == "ssdLayered")
        let unknown = ChatRunFeedback(metadata: ["promptTokens": "true", "generationTokens": "-1",
            "application.stream.seconds": "nan", "generationSeconds": "-0.1", "loadingStrategy": "/private/canary",
            "application.stream.bytes": "900"])
        #expect(unknown.promptTokens == nil && unknown.generationTokens == nil)
        #expect(unknown.applicationSeconds == nil && unknown.generationSeconds == nil && unknown.loadingStrategy == nil)
        #expect(ChatRunFeedback(metadata: [:]).generationTokens == nil)
    }
}
