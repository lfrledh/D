// Path: Core/Sources/Core/Models/ShardMap.swift

import Foundation

/// Describes how model weights are split across safetensors files.
public struct ShardMap: Sendable, Codable {
    public let files: [URL]
    public let tensorNames: [String: URL]  // tensor name -> file URL

    public init(files: [URL], tensorNames: [String: URL]) {
        self.files = files
        self.tensorNames = tensorNames
    }
}
