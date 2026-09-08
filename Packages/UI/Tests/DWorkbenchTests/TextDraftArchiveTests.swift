import Foundation
import Testing
@testable import DWorkbench

@Suite("Text draft archive")
struct TextDraftArchiveTests {
    @Test func archiveRoundTripsExactDocumentIdentityAndUnicode() throws {
        let document = try TextDraftDocument(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                             revision: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                                             text: "中文 e\u{301} 👩‍💻 🇯🇵")
        let data = try TextDraftArchive.encode(document)
        #expect(try TextDraftArchive.decode(data) == document)
    }

    @Test func archiveRejectsUnknownBooleanAndMalformedSchemaVersions() throws {
        let unknown = Data(#"{"schema_version":2,"document":{"id":"11111111-1111-1111-1111-111111111111","revision":"22222222-2222-2222-2222-222222222222","text":"draft"}}"#.utf8)
        #expect(throws: TextDraftError.unsupportedArchiveVersion) { try TextDraftArchive.decode(unknown) }

        let boolean = Data(#"{"schema_version":true,"document":{"id":"11111111-1111-1111-1111-111111111111","revision":"22222222-2222-2222-2222-222222222222","text":"draft"}}"#.utf8)
        #expect(throws: TextDraftError.malformedArchive) { try TextDraftArchive.decode(boolean) }
        #expect(throws: TextDraftError.malformedArchive) { try TextDraftArchive.decode(Data("not json".utf8)) }
    }

    @Test(arguments: ["1.0", "1e0"])
    func archiveRejectsNonIntegerNumericVersionTokens(_ token: String) throws {
        let document = try TextDraftDocument(text: "draft")
        let encoded = String(decoding: try TextDraftArchive.encode(document), as: UTF8.self)
        let malformed = Data(encoded.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":" + token).utf8)
        #expect(throws: TextDraftError.malformedArchive) { try TextDraftArchive.decode(malformed) }
    }

    @Test func archiveAndDocumentEnforceSeparateInputAndTextLimits() throws {
        let oversizedText = String(repeating: "a", count: TextDraftDocument.maximumUTF8Bytes + 1)
        #expect(throws: TextDraftError.textTooLarge) { try TextDraftDocument(text: oversizedText) }
        #expect(throws: TextDraftError.archiveTooLarge) {
            try TextDraftArchive.decode(Data(repeating: 0, count: TextDraftArchive.maximumInputBytes + 1))
        }
    }
}
