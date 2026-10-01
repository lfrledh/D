import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

private let preparedStateKey = LMOutput.Key<MLXArray>("test.preparedState")

private final class PreparedStateModel: Module, LanguageModel {
    var observed: Int?

    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        var state = LMOutput.State()
        state[preparedStateKey] = MLXArray(37)
        return .logits(LMOutput(logits: MLXArray.zeros([1, 1, 4]), state: state))
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?,
                        state: LMOutput.State?) -> LMOutput {
        observed = state?[preparedStateKey]?.item(Int.self)
        return LMOutput(logits: MLXArray.zeros([1, 1, 4]), state: state)
    }
}

@Suite(.serialized) struct IteratorBoundaryTests {
@Test("TokenIterator carries prepare logits state into first decode")
func preparedLogitsStateSurvivesFirstDecode() throws {
    let model = PreparedStateModel()
    var iterator = try TokenIterator(input: LMInput(tokens: MLXArray([[1]])),
        model: model, parameters: GenerateParameters(maxTokens: 2, temperature: 0))
    _ = iterator.next()
    #expect(model.observed == 37)
}

private final class ThrowingFixedModel: Module, ThrowingLanguageModel {
    var failDecodeOnCall: Int?
    var decodeCalls = 0
    var slowDecode = false
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .logits(LMOutput(logits: MLXArray.zeros([1, 1, 4])))
    }

    func prepareThrowing(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        try prepare(input, cache: cache, windowSize: windowSize)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        LMOutput(logits: MLXArray.zeros([1, 1, 4]), state: state)
    }

    func callThrowing(_ input: LMInput.Text, cache: [KVCache]?,
                      state: LMOutput.State?) throws -> LMOutput {
        decodeCalls += 1
        if slowDecode { Thread.sleep(forTimeInterval: 0.01) }
        if let failDecodeOnCall, decodeCalls == failDecodeOnCall {
            throw DecodeFixtureError.failed
        }
        return callAsFunction(input, cache: cache, state: state)
    }
}

private enum DecodeFixtureError: Error { case failed }

@Test("Throwing raw token stream yields tokens and a length completion")
func throwingTokenStreamUsesRawHandler() async throws {
    let iterator = try TokenIterator(throwingInput: LMInput(tokens: MLXArray([[1]])),
        model: ThrowingFixedModel(), parameters: GenerateParameters(maxTokens: 2, temperature: 0))
    let (stream, task) = generateThrowingTokenTask(promptTokenCount: 1,
        modelConfiguration: ModelConfiguration(id: "synthetic"), tokenizer: TestTokenizer(),
        iterator: iterator)
    var tokens = [Int]()
    var stopReason: GenerateStopReason?
    for try await event in stream {
        switch event {
        case .token(let token): tokens.append(token)
        case .info(let info): stopReason = info.stopReason
        }
    }
    await task.value
    #expect(tokens.count == 2)
    if case .length = stopReason {} else { Issue.record("Expected length completion") }
}

@Test("Decode failure propagates through the stream and its producer is drained")
func throwingTokenStreamReportsDecodeFailure() async throws {
    let model = ThrowingFixedModel()
    model.failDecodeOnCall = 2
    let iterator = try TokenIterator(throwingInput: LMInput(tokens: MLXArray([[1, 2]])),
        model: model, parameters: GenerateParameters(maxTokens: 3, temperature: 0))
    let (stream, task) = generateThrowingTokenTask(promptTokenCount: 2,
        modelConfiguration: ModelConfiguration(id: "synthetic"), tokenizer: TestTokenizer(),
        iterator: iterator)
    var received = 0
    do {
        for try await event in stream {
            if case .token = event { received += 1 }
        }
        Issue.record("Decode error was swallowed")
    } catch DecodeFixtureError.failed {
        #expect(received == 1)
    }
    task.cancel()
    await task.value
    #expect(model.decodeCalls == 2)
}

@Test("Cancellation during generation drains the producer")
func throwingTokenStreamCancelsDuringDecode() async throws {
    let model = ThrowingFixedModel()
    model.slowDecode = true
    let iterator = try TokenIterator(throwingInput: LMInput(tokens: MLXArray([[1, 2]])),
        model: model, parameters: GenerateParameters(maxTokens: 10_000, temperature: 0))
    let (stream, task) = generateThrowingTokenTask(promptTokenCount: 2,
        modelConfiguration: ModelConfiguration(id: "synthetic"), tokenizer: TestTokenizer(), iterator: iterator)
    var cancelled = false
    do {
        for try await event in stream {
            if case .token = event, !cancelled { cancelled = true; task.cancel() }
        }
    } catch is CancellationError {} // Either a cancelled completion or propagated cancellation is valid.
    await task.value
    #expect(cancelled && task.isCancelled)
    #expect(model.decodeCalls > 0 && model.decodeCalls < 10_000)
}
}
