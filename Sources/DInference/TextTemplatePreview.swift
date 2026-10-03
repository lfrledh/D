import Foundation

/// CPU-only template expansion before the vision processor replaces media placeholders.
public struct TextTemplatePreview: Sendable, Equatable {
    public let sourceTemplate: String
    public let renderedTemplate: String
    public let templateTokenIDs: [Int]
    public let diagnostics: [String]

    public init(sourceTemplate: String, renderedTemplate: String,
                templateTokenIDs: [Int], diagnostics: [String]) {
        self.sourceTemplate = sourceTemplate
        self.renderedTemplate = renderedTemplate
        self.templateTokenIDs = templateTokenIDs
        self.diagnostics = diagnostics
    }
}
