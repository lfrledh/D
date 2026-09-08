import Foundation
import CoreFoundation

public enum TextDraftArchive {
    public static let schemaVersion = 1
    public static let maximumInputBytes = 8 * 1_024 * 1_024

    private struct Envelope: Codable {
        let schemaVersion: Int
        let document: TextDraftDocument

        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", document }
    }

    public static func encode(_ document: TextDraftDocument) throws -> Data {
        try TextDraftDocument.validate(document.text)
        let encoder = JSONEncoder()
        let data = try encoder.encode(Envelope(schemaVersion: schemaVersion, document: document))
        guard data.count <= maximumInputBytes else { throw TextDraftError.archiveTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> TextDraftDocument {
        guard data.count <= maximumInputBytes else { throw TextDraftError.archiveTooLarge }
        do {
            try validateSchemaVersionToken(in: data)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == schemaVersion else { throw TextDraftError.unsupportedArchiveVersion }
            try TextDraftDocument.validate(envelope.document.text)
            return envelope.document
        } catch let error as TextDraftError {
            throw error
        } catch {
            throw TextDraftError.malformedArchive
        }
    }

    /// JSONDecoder accepts 1.0 and 1e0 while decoding Int; this archive requires an integer token.
    private static func validateSchemaVersionToken(in data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["schema_version"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw TextDraftError.malformedArchive
        }
        let encoding = String(cString: number.objCType)
        let integerEncodings: Set<String> = ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]
        guard integerEncodings.contains(encoding) else { throw TextDraftError.malformedArchive }
    }
}
