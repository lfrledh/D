import Foundation
import Core
import MLXLMCommon
import ModelLoading

public final class LLMChatService: TextGenerationService, @unchecked Sendable {
    private let session: ChatSession

    public init(modelContainer: ModelContainerProtocol) {
        guard let wrapper = modelContainer as? ModelContainerWrapper else {
            fatalError("Invalid model container type")
        }
        self.session = ChatSession(wrapper.container)
    }

    public nonisolated func generate(prompt: String, parameters: Core.GenerateParameters) -> AsyncStream<String> {
        let mlxParameters = MLXLMCommon.GenerateParameters(
            maxTokens: parameters.maxTokens,
            temperature: parameters.temperature,
            topP: parameters.topP,
            repetitionPenalty: parameters.repetitionPenalty,
            repetitionContextSize: parameters.penaltyWindowSize
        )

        return AsyncStream { continuation in
            Task {
                do {
                    // 设置会话的生成参数
                    session.generateParameters = mlxParameters
                    let stream = session.streamResponse(to: prompt)
                    for try await fragment in stream {
                        if Task.isCancelled { break }
                        continuation.yield(fragment)
                    }
                    continuation.finish()
                } catch {
                    continuation.yield("[Error] \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }
}
