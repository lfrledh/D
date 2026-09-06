import Foundation

/// A protocol that abstracts the official ModelContainer from MLXLMCommon.
/// This allows us to keep Core free of external dependencies.
public protocol ModelContainerProtocol: Sendable {
    // 可以添加一些通用方法，比如获取 tokenizer 或配置，但目前暂时为空
    // 如果需要，可以添加方法，但现阶段我们仅将其作为类型占位符
}
