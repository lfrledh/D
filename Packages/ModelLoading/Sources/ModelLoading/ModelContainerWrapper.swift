import Foundation
import MLXLMCommon
import Core

/// A wrapper that makes ModelContainer conform to our abstract protocol.
public final class ModelContainerWrapper: ModelContainerProtocol, @unchecked Sendable {
    public let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }
}
