// Path: Core/Sources/Core/Models/ModelCapability.swift

import Foundation

/// Capabilities that a model may possess.
public enum ModelCapability: String, Sendable, Codable, CaseIterable {
    case text
    case image
    case audio
    case video
    case visionLanguage

    public var displayName: String {
        switch self {
        case .text: return "Text Generation"
        case .image: return "Image Generation"
        case .audio: return "Audio Generation"
        case .video: return "Video Generation"
        case .visionLanguage: return "Vision Language"
        }
    }

    public var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .visionLanguage: return "eye.circle"
        }
    }
}
