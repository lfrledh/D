import Foundation

public enum ImageCodecRegistryError: Error, Sendable, Equatable {
    case invalidFormatID
    case invalidTypeIdentifier
    case duplicateFormatID(String)
    case duplicateTypeIdentifier(String)
    case ambiguousSignature([String])
    case unsupportedFormat
}

public struct ImageCodecRegistry: Sendable {
    public static let standard = ImageCodecRegistry(validatedCodecs: [
        PNGImageCodec(),
        JPEGImageCodec(),
    ])

    private let codecs: [any ImageCodec]

    public init(codecs: [any ImageCodec]) throws {
        var formatIDs = Set<String>()
        var typeIdentifiers = Set<String>()
        for codec in codecs {
            guard !codec.formatID.isEmpty else {
                throw ImageCodecRegistryError.invalidFormatID
            }
            guard !codec.typeIdentifier.isEmpty else {
                throw ImageCodecRegistryError.invalidTypeIdentifier
            }
            guard formatIDs.insert(codec.formatID).inserted else {
                throw ImageCodecRegistryError.duplicateFormatID(codec.formatID)
            }
            let normalizedTypeIdentifier = codec.typeIdentifier.lowercased()
            guard typeIdentifiers.insert(normalizedTypeIdentifier).inserted else {
                throw ImageCodecRegistryError.duplicateTypeIdentifier(codec.typeIdentifier)
            }
        }
        self.codecs = codecs
    }

    public var formatIDs: [String] {
        codecs.map(\.formatID)
    }

    public func codec(formatID: String) -> (any ImageCodec)? {
        codecs.first { $0.formatID == formatID }
    }

    public func codec(detecting data: Data) throws -> any ImageCodec {
        let matches = codecs.filter { $0.matchesSignature(data) }
        guard !matches.isEmpty else {
            throw ImageCodecRegistryError.unsupportedFormat
        }
        guard matches.count == 1 else {
            throw ImageCodecRegistryError.ambiguousSignature(
                matches.map(\.formatID).sorted())
        }
        return matches[0]
    }

    private init(validatedCodecs: [any ImageCodec]) {
        codecs = validatedCodecs
    }
}
