import DInference
import DRuntime
import Foundation
import Testing
@testable import DWorkbench

@Suite("Low-memory consent owner and persisted scope") @MainActor
struct LowMemoryDecisionTests {
    private func proposal(id: UUID = UUID(), token: UUID = UUID()) throws -> LowMemoryProposal {
        let request = InferenceRequest(model: .init(directory: URL(fileURLWithPath: "/exact")),
            input: .text(.init(prompt: "original")), loadingSelection: .automatic)
        return .init(id: id, entryToken: token, original: request,
            backend: .init(id: "test", version: "1", capabilities: [.textGeneration]),
            plan: .init(request: try request.lowMemoryRequest(method: .layered), method: .layered,
                strategyVersion: 1, modelIdentityToken: "exact"),
            preferredEstimate: .init(peakBytes: 100), estimate: .init(peakBytes: 30), budget: 50)
    }
    private func settings() throws -> UserDefaults { try #require(UserDefaults(suiteName: "D.B5.Test." + UUID().uuidString)) }
    private func wait(_ owner: LowMemoryDecisionStore) async throws {
        for _ in 0..<100 where owner.pending == nil { await Task.yield() }
        #expect(owner.pending != nil)
    }
    @Test func defaultAskStopAndStaleCallbacksNeverPersistAllow() async throws {
        let defaults = try settings(), owner = LowMemoryDecisionStore(settings: defaults), p = try proposal()
        #expect(owner.preference == .ask)
        let run = Task { try await owner.decide(p) }
        try await wait(owner)
        #expect(!owner.resolve(proposalID: p.id, entryToken: UUID(), allow: true, remember: true))
        #expect(owner.resolve(proposalID: p.id, entryToken: p.entryToken, allow: false, remember: true))
        #expect(try await run.value == .userStopped)
        #expect(!owner.resolve(proposalID: p.id, entryToken: p.entryToken, allow: true, remember: true))
        #expect(LowMemoryDecisionStore(settings: defaults).preference == .ask)
    }
    @Test func cancellationWinsBeforeMainActorCleanupAndCannotRemember() async throws {
        let defaults = try settings(), owner = LowMemoryDecisionStore(settings: defaults), p = try proposal()
        let run = Task { try await owner.decide(p) }
        try await wait(owner)
        run.cancel()
        // Deliberately no yield between cancellation and a stale affirmative click.
        #expect(!owner.resolve(proposalID: p.id, entryToken: p.entryToken, allow: true, remember: true))
        do { _ = try await run.value; Issue.record("Cancelled decision returned consent") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(owner.pending == nil && LowMemoryDecisionStore(settings: defaults).preference == .ask)
    }
    @Test func onlyAffirmativeRememberPersistsAndNewRequestsReadCurrentPreference() async throws {
        let defaults = try settings(), owner = LowMemoryDecisionStore(settings: defaults), p = try proposal()
        let run = Task { try await owner.decide(p) }; try await wait(owner)
        #expect(owner.resolve(proposalID: p.id, entryToken: p.entryToken, allow: true))
        #expect(try await run.value == .allowOnce)
        #expect(owner.preference == .ask)
        let next = try proposal(), remembered = Task { try await owner.decide(next) }; try await wait(owner)
        #expect(owner.resolve(proposalID: next.id, entryToken: next.entryToken, allow: true, remember: true))
        #expect(try await remembered.value == .allowOnce)
        let reopened = LowMemoryDecisionStore(settings: defaults)
        #expect(try await reopened.decide(proposal()) == .allowedByPreference)
        reopened.setPreference(.deny)
        #expect(try await reopened.decide(proposal()) == .denyByPreference)
        reopened.setPreference(.ask)
        #expect(LowMemoryDecisionStore(settings: defaults).preference == .ask)
    }
    @Test func retriesRetainPriorSubmissionRecordsAndSaveIsIdempotent() throws {
        let p = try proposal()
        var denied = InferenceExecutionRecord(request: p.original, backend: p.backend, budget: p.budget)
        denied.decision = .userStopped; denied.state = .stopped
        var accepted = InferenceExecutionRecord(request: p.original, backend: p.backend, budget: p.budget)
        accepted.decision = .allowOnce; accepted.state = .completed
        let history = [denied].mergingExecutionRecords([accepted])
        #expect(LowMemoryExecutionPresentation.nonExecutionCode([denied]) == "memory.stopped")
        denied.executionStarted = nil
        #expect(LowMemoryExecutionPresentation.nonExecutionCode([denied]) == nil)
        #expect(history.count == 2 && history[0].requestID == history[1].requestID)
        #expect(history.mergingExecutionRecords([accepted]) == history)
        #expect(try JSONDecoder().decode([InferenceExecutionRecord].self, from: JSONEncoder().encode(history)) == history)
    }
}
