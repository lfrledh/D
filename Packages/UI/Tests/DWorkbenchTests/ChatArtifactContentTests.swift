import Foundation
import XCTest
@testable import DWorkbench

final class ChatArtifactContentTests: XCTestCase {
    private let projectID = UUID()

    private func reference(_ kind: WorkflowDataKind) -> WorkflowAssetReference {
        .init(projectID: projectID, assetID: UUID(), kind: kind, sha256: "source-hash")
    }

    func testRoundTripAndRevisionPreserveOriginAndExactUnicodeSource() throws {
        let origin = reference(.document)
        let output = reference(.text)
        let session = UUID()
        let text = "第一行👩‍💻\r\n  <script>原文</script>\n"
        let original = ChatArtifactContent(sessionID: session, title: "  原题  ", kind: .markdown,
                                           text: text, source: origin, output: output)
        try original.validate()
        XCTAssertEqual(try JSONDecoder().decode(ChatArtifactContent.self,
                                                from: JSONEncoder().encode(original)), original)

        var edited = original
        edited.title = "新题"
        edited.kind = .code
        edited.text += "追加"
        let revised = try edited.revised()
        XCTAssertEqual(revised.id, original.id)
        XCTAssertEqual(revised.sessionID, session)
        XCTAssertEqual(revised.source, origin)
        XCTAssertNil(revised.output)
        XCTAssertEqual(revised.revision, 2)
        XCTAssertEqual(revised.text, text + "追加")
        XCTAssertEqual(original.title, "  原题  ")
        XCTAssertEqual(original.output, output)
    }

    func testExactTitleAndUTF8BudgetsAllowEmptyFile() throws {
        let base = ChatArtifactContent(sessionID: UUID(), title: String(repeating: "👩‍💻", count: 256),
                                       kind: .plainText, text: "")
        XCTAssertNoThrow(try base.validate())
        var invalid = base
        invalid.title += "a"
        XCTAssertThrowsError(try invalid.validate()) {
            XCTAssertEqual($0 as? ChatArtifactContent.ValidationError, .titleTooLong)
        }
        invalid.title = " \n\t "
        XCTAssertThrowsError(try invalid.validate()) {
            XCTAssertEqual($0 as? ChatArtifactContent.ValidationError, .blankTitle)
        }
        invalid.title = "Title"
        invalid.text = String(repeating: "🎨", count: 262_144)
        XCTAssertNoThrow(try invalid.validate())
        invalid.text += "🎨"
        XCTAssertThrowsError(try invalid.validate()) {
            XCTAssertEqual($0 as? ChatArtifactContent.ValidationError, .sourceTooLarge)
        }
        XCTAssertEqual(invalid.text.utf8.count, 1_048_580)
    }

    func testOnlyTextOrDocumentReferencesAndPositiveRevisions() throws {
        let session = UUID()
        var content = ChatArtifactContent(revision: 0, sessionID: session, title: "Data",
                                          kind: .csv, text: "a,b\n1,2")
        XCTAssertThrowsError(try content.validate()) {
            XCTAssertEqual($0 as? ChatArtifactContent.ValidationError, .invalidRevision)
        }
        content = .init(sessionID: session, title: "Data", kind: .csv, text: "a,b\n1,2",
                        source: reference(.image))
        XCTAssertThrowsError(try content.validate()) {
            XCTAssertEqual($0 as? ChatArtifactContent.ValidationError, .invalidSourceKind)
        }
        content = .init(sessionID: session, title: "Data", kind: .csv, text: "a,b\n1,2",
                        source: reference(.text), output: reference(.video))
        XCTAssertThrowsError(try content.validate()) {
            XCTAssertEqual($0 as? ChatArtifactContent.ValidationError, .invalidOutputKind)
        }
        content.output = reference(.document)
        XCTAssertNoThrow(try content.validate())
        content = .init(revision: Int.max, sessionID: session, title: content.title,
                        kind: content.kind, text: content.text, source: content.source, output: content.output)
        XCTAssertThrowsError(try content.revised()) {
            XCTAssertEqual($0 as? ChatArtifactContent.ValidationError, .revisionOverflow)
        }
    }
}
