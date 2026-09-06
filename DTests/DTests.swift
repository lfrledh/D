import Testing
@testable import D

@MainActor
struct WorkbenchCloseTests {
    @Test func simultaneousWindowCloseAndQuitShareOneDecisionAndDrain() async {
        let prompt = SuspendedCloseDecision()
        let gate = CloseRequestGate { await prompt.decide() }
        let windowClose = Task { await gate.prepareToClose() }
        await prompt.waitUntilRequested()

        // The direct second request enters the gate before this queued answer is processed.
        Task { @MainActor in prompt.answer(true) }
        let quit = await gate.prepareToClose()
        let closed = await windowClose.value
        #expect(quit && closed)
        #expect(prompt.requestCount == 1)
    }

    @Test func choosingKeepEditingAllowsALaterCloseAttempt() async {
        var count = 0
        let gate = CloseRequestGate {
            count += 1
            return count == 2
        }
        #expect(await gate.prepareToClose() == false)
        #expect(await gate.prepareToClose() == true)
        #expect(count == 2)
    }
}

@MainActor
private final class SuspendedCloseDecision {
    private(set) var requestCount = 0
    private var answerContinuation: CheckedContinuation<Bool, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func decide() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            answerContinuation = continuation
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitUntilRequested() async {
        if answerContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func answer(_ approved: Bool) {
        answerContinuation?.resume(returning: approved)
        answerContinuation = nil
    }
}
