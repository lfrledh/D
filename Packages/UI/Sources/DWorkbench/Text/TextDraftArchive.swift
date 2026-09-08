import Foundation

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
}
