// Path: Core/Sources/Core/Models/ModelDescriptor.swift

import Foundation

/// Describes a model on disk.
public struct ModelDescriptor: Sendable, Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let directoryURL: URL
    public let architectureIdentifier: String
    public let capabilities: Set<ModelCapability>
    public let parameterCount: UInt64
    public let importedAt: Date
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        directoryURL: URL,
        architectureIdentifier: String,
        capabilities: Set<ModelCapability>,
        parameterCount: UInt64,
        importedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.directoryURL = directoryURL
        self.architectureIdentifier = architectureIdentifier
        self.capabilities = capabilities
        self.parameterCount = parameterCount
        self.importedAt = importedAt
        self.lastUsedAt = lastUsedAt
    }
}
