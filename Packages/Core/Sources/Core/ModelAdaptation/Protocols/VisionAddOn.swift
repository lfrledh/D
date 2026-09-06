// Path: Core/Sources/Core/ModelAdaptation/Protocols/VisionAddOn.swift

import Foundation

/// A plugin that can convert image data into embeddings.
/// All inputs and outputs are Sendable, suitable for cross-actor communication.
public protocol VisionAddOn: Sendable {
    /// Compute image embeddings from raw image data.
    /// - Parameter imageData: The image data (e.g., PNG, JPEG) as Data.
    /// - Returns: An array of floats representing the image embeddings.
    nonisolated func computeEmbeddings(imageData: Data) throws -> [Float]
}
