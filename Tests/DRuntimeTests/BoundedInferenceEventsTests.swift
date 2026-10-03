import DInference
@testable import DRuntime
import Foundation
import Testing

@Suite("Bounded lossless events", .timeLimit(.minutes(1)))
struct BoundedInferenceEventsTests {
    @Test func cancellationHandsFreeSlotToAnotherSender() async throws {
        for _ in 0..<64 {
            let queue = BoundedInferenceEvents(capacity: 1)
            try await queue.send(.textDelta("a"))
            let first = Task { try await queue.send(.textDelta("b")) }
            while await queue.snapshot().pendingProducers != 1 { await Task.yield() }
            let second = Task { try await queue.send(.textDelta("c")) }
            while await queue.snapshot().pendingProducers != 2 { await Task.yield() }
            #expect(try await queue.next() == .textDelta("a"))
            first.cancel()
            let firstAccepted: Bool
            do { try await first.value; firstAccepted = true }
            catch is CancellationError { firstAccepted = false }
            var values: [InferenceOutput] = []
            for _ in 0..<(firstAccepted ? 2 : 1) {
                if let value = try await queue.next() { values.append(value) }
            }
            try await second.value
            #expect(values.contains(.textDelta("c")))
            #expect(values.contains(.textDelta("b")) == firstAccepted)
            #expect(await queue.snapshot().peakBuffered == 1)
            await queue.finish(.success(()))
        }
    }

    @Test func capacityAndTerminalPrefix() async throws {
        let queue = BoundedInferenceEvents(capacity: 2)
        try await queue.send(.textDelta("a")); try await queue.send(.textDelta("b"))
        let sender = Task { try await queue.send(.textDelta("c")) }
        while await queue.snapshot().pendingProducers == 0 { await Task.yield() }
        let before = await queue.snapshot()
        #expect(before.buffered == 2 && before.peakBuffered == 2 && before.capacityWaits == 1)
        #expect(try await queue.next() == .textDelta("a"))
        try await sender.value
        await queue.finish(.failure(InferenceFailure.backendFailed("terminal")))
        #expect(try await queue.next() == .textDelta("b"))
        #expect(try await queue.next() == .textDelta("c"))
        await #expect(throws: InferenceFailure.backendFailed("terminal")) { _ = try await queue.next() }
        #expect(await queue.snapshot().peakBuffered == 2)
    }

    @Test func cancelledSenderIsNotAnAcceptedEvent() async throws {
        let queue = BoundedInferenceEvents(capacity: 1)
        try await queue.send(.textDelta("accepted"))
        let sender = Task { try await queue.send(.textDelta("not accepted")) }
        while await queue.snapshot().pendingProducers == 0 { await Task.yield() }
        sender.cancel()
        await #expect(throws: CancellationError.self) { try await sender.value }
        await queue.finish(.success(()))
        #expect(try await queue.next() == .textDelta("accepted"))
        #expect(try await queue.next() == nil)
        #expect(await queue.snapshot().pendingProducers == 0)
    }
}
