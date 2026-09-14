import DInference
import DRuntime
import Foundation
import Testing

@Suite("Explicit task memory budgets", .timeLimit(.minutes(1)))
struct RequestBudgetTests {
    private func selected(_ bytes: UInt64?) -> InferenceRequest {
        InferenceRequest(model: .init(directory: URL(fileURLWithPath: "/model")),
                         input: .text(.init(prompt: "test")), memoryBudgetBytes: bytes)
    }

    @Test func legacyAndRepresentation() throws {
        let original = selected(nil)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "memoryBudgetBytes")
        let legacy = try JSONDecoder().decode(InferenceRequest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy == original)
        for invalid in [UInt64(0), UInt64.max] {
            #expect(throws: InferenceFailure.self) { try selected(invalid).validate() }
        }
        try selected(UInt64(Int64.max)).validate()
    }

    @Test func hostMustOptIn() async throws {
        let backend = ControlledBackend()
        let engine = try runtime([backend], budget: 64)
        do {
            _ = try await engine.submit(selected(65), backendID: "controlled")
            Issue.record("A default host allowed a budget increase")
        } catch let failure as InferenceFailure {
            guard case .invalidRequest = failure else { Issue.record("Wrong refusal: \(failure)"); return }
        }
        #expect(await backend.observations().calls.isEmpty)
        await engine.shutdown()
    }

    @Test func queuedSelectionsRemainIndependent() async throws {
        let first = selected(128), lower = selected(32), automatic = selected(nil)
        let gate = TestGate()
        let backend = ControlledBackend(plans: [first.id: TestPlan(estimate: 96, executeGate: gate)])
        let engine = try InferenceRuntime(backends: [backend], configuration: .init(
            memoryBudgetBytes: 64, allowsRequestBudgetIncrease: true))
        let one = try await engine.submit(first, backendID: "controlled")
        await gate.waitForArrival()
        let two = try await engine.submit(lower, backendID: "controlled")
        let three = try await engine.submit(automatic, backendID: "controlled")
        #expect(await engine.snapshot().reservedBytes == 96)
        await gate.open()
        await expectCompleted(one)
        #expect(await two.outcome() == .failed(.memoryBudgetExceeded(required: 64, limit: 32)))
        await expectCompleted(three)
        #expect(await backend.observations().maximumConcurrentExecutions == 1)
        await engine.shutdown()
    }
}
