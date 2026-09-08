import Foundation
import Testing
@testable import DWorkbench

@Suite("Project text document durability")
struct ProjectTextStoreTests {
    @Test func unicodeAndEmptyTextDraftsRoundTripWithStableRevision() async throws {
        try await withTextFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "文稿项目")
            let created = try await store.createTextDocument(text: "")
            let document = try #require(created.activeDocument)
            let empty = try #require(document.textDraft)
            #expect(document.kind == .text)
            #expect(document.id == empty.id)
            let revision = empty.revision
            let changed = try TextDraftDocument(id: document.id, text: "咖啡\nCafe\u{301} ☕️")
            _ = try await store.saveTextDraft(changed, documentID: document.id, expectedRevision: revision)
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            let reopenedManifest = await reopened.snapshot()
            let saved = try #require(reopenedManifest.activeDocument?.textDraft)
            #expect(saved == changed)
            try await reopened.close()
        }
    }

    @Test func rejectsStaleMismatchedAndOversizedTextDraftsWithoutChangingManifest() async throws {
        try await withTextFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "检查文字保存")
            let created = try await store.createTextDocument()
            let document = try #require(created.activeDocument)
            let current = try #require(document.textDraft)
            let changed = try TextDraftDocument(id: document.id, text: "新版")
            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.saveTextDraft(changed, documentID: document.id, expectedRevision: UUID())
            }
            await #expect(throws: ProjectStoreError.self) {
                try await store.saveTextDraft(try TextDraftDocument(text: "错误编号"), documentID: document.id,
                                              expectedRevision: current.revision)
            }
            await #expect(throws: TextDraftError.textTooLarge) {
                _ = try TextDraftDocument(text: String(repeating: "x", count: TextDraftDocument.maximumUTF8Bytes + 1))
            }
            let unchanged = await store.snapshot()
            #expect(unchanged.documents.last?.textDraft == current)
            try await store.close()
        }
    }

    @Test func imageOperationsAndImageJobsCannotUseTextDocument() async throws {
        try await withTextFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "隔离")
            let created = try await store.createTextDocument()
            let text = try #require(created.activeDocument)
            await #expect(throws: ProjectStoreError.self) { try await store.saveDraft(.init(), documentID: text.id) }
            await #expect(throws: ProjectStoreError.self) { try await store.setSelectedAsset(nil, documentID: text.id) }
            await #expect(throws: ProjectStoreError.self) { try await store.adoptAsset(id: nil, documentID: text.id) }
            await #expect(throws: ProjectStoreError.self) { try await store.enqueue(request: fixture.request(), documentID: text.id) }
            try await store.close()
        }
    }

    @Test func versionTwoBytesAreBackedUpBeforeVersionThreePublication() async throws {
        try await withTextFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "v2 项目")
            try await store.close()
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["schemaVersion"] = 2
            var documents = try #require(object["documents"] as? [[String: Any]])
            for index in documents.indices {
                documents[index].removeValue(forKey: "kind")
                documents[index].removeValue(forKey: "textDraft")
            }
            object["documents"] = documents
            let original = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try original.write(to: file)
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().schemaVersion == ProjectManifest.currentSchemaVersion)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionTwoBackupFilename)) == original)
            try await reopened.close()
        }
    }
    @Test func interruptedVersionTwoMigrationKeepsRawBytesAndCanRetry() async throws {
        try await withTextFixture { fixture in
            let original = try await writeVersionTwoManifest(at: fixture.project)
            await #expect(throws: MigrationInterrupted.self) {
                try await ProjectStore.open(at: fixture.project, migrationCheckpoint: { point in
                    if point == .backupDurable { throw MigrationInterrupted.afterBackup }
                })
            }
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            #expect(try Data(contentsOf: file) == original)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionTwoBackupFilename)) == original)
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().schemaVersion == ProjectManifest.currentSchemaVersion)
            try await reopened.close()
        }
    }

    @Test func externalTextManifestChangeRejectsSaveWithoutOverwritingIt() async throws {
        try await withTextFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "外部编辑")
            let created = try await store.createTextDocument(text: "原稿")
            let document = try #require(created.activeDocument)
            let draft = try #require(document.textDraft)
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["name"] = "外部修改"
            let externalBytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try externalBytes.write(to: file, options: .atomic)
            let replacement = try TextDraftDocument(id: document.id, text: "不得覆盖")
            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.saveTextDraft(replacement, documentID: document.id, expectedRevision: draft.revision)
            }
            #expect(try Data(contentsOf: file) == externalBytes)
            try await store.close(preserveExternalChanges: true)
        }
    }
}

private enum MigrationInterrupted: Error { case afterBackup }

private func writeVersionTwoManifest(at project: URL) async throws -> Data {
    let store = try await ProjectStore.create(at: project, name: "v2 中断")
    try await store.close()
    let file = project.appendingPathComponent(ProjectStore.manifestFilename)
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    object["schemaVersion"] = 2
    var documents = try #require(object["documents"] as? [[String: Any]])
    for index in documents.indices {
        documents[index].removeValue(forKey: "kind")
        documents[index].removeValue(forKey: "textDraft")
    }
    object["documents"] = documents
    let original = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try original.write(to: file)
    return original
}

private func withTextFixture(_ body: @Sendable (ProjectFixture) async throws -> Void) async throws {
    let path = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
    let directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(ProjectFixture(directory: directory.resolvingSymlinksInPath()))
}
