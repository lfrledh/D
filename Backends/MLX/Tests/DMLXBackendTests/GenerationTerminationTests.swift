import DInference
@testable import DMLXBackend
import Testing

@Suite("Pinned SDK generation termination compatibility")
struct GenerationTerminationTests {
    @Test("Uncancelled generation at its token limit normalizes the pinned SDK mislabel")
    func mislabeledLimit() throws {
        let reason = try GenerationTermination.resolve(
            .init(promptTokenCount: 5, generationTokenCount: 8,
                  promptTime: 0.1, generationTime: 0.2, stopReason: .cancelled),
            requestedTokens: 8, taskWasCancelled: false)
        #expect(reason == "length")
    }

    @Test("Explicit cancellation wins at the exact token limit, regardless of completion label")
    func cancellationAtLimit() {
        #expect(throws: CancellationError.self) {
            try GenerationTermination.resolve(
                .init(promptTokenCount: 5, generationTokenCount: 8,
                      promptTime: 0.1, generationTime: 0.2, stopReason: .cancelled),
                requestedTokens: 8, taskWasCancelled: true)
        }
        #expect(throws: CancellationError.self) {
            try GenerationTermination.resolve(
                .init(promptTokenCount: 5, generationTokenCount: 8,
                      promptTime: 0.1, generationTime: 0.2, stopReason: .length),
                requestedTokens: 8, taskWasCancelled: true)
        }
        #expect(throws: CancellationError.self) {
            try GenerationTermination.resolve(
                .init(promptTokenCount: 5, generationTokenCount: 8,
                      promptTime: 0.1, generationTime: 0.2, stopReason: .stop),
                requestedTokens: 8, taskWasCancelled: true)
        }
    }

    @Test("An upstream cancellation below the limit cannot be reported as successful length completion")
    func earlyCancellation() {
        #expect(throws: CancellationError.self) {
            try GenerationTermination.resolve(
                .init(promptTokenCount: 5, generationTokenCount: 3,
                      promptTime: 0.1, generationTime: 0.2, stopReason: .cancelled),
                requestedTokens: 8, taskWasCancelled: false)
        }
    }

    @Test("EOS retains its stop reason, including at the requested count", arguments: [3, 8])
    func endOfSequence(count: Int) throws {
        let reason = try GenerationTermination.resolve(
            .init(promptTokenCount: 5, generationTokenCount: count,
                  promptTime: 0.1, generationTime: 0.2, stopReason: .stop),
            requestedTokens: 8, taskWasCancelled: false)
        #expect(reason == "stop")
    }

    @Test("A valid upstream length completion retains its reason")
    func validLength() throws {
        let reason = try GenerationTermination.resolve(
            .init(promptTokenCount: 5, generationTokenCount: 8,
                  promptTime: 0.1, generationTime: 0.2, stopReason: .length),
            requestedTokens: 8, taskWasCancelled: false)
        #expect(reason == "length")
    }

    @Test("Impossible generated token counts are failures", arguments: [-1, 9])
    func invalidTokenCount(count: Int) {
        #expect(throws: InferenceFailure.self) {
            try GenerationTermination.resolve(
                .init(promptTokenCount: 5, generationTokenCount: count,
                      promptTime: 0.1, generationTime: 0.2, stopReason: .stop),
                requestedTokens: 8, taskWasCancelled: false)
        }
    }

    @Test("An upstream length label below the limit is inconsistent, not success")
    func earlyLength() {
        #expect(throws: InferenceFailure.self) {
            try GenerationTermination.resolve(
                .init(promptTokenCount: 5, generationTokenCount: 3,
                      promptTime: 0.1, generationTime: 0.2, stopReason: .length),
                requestedTokens: 8, taskWasCancelled: false)
        }
    }
}
