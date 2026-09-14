import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Text sources production persistence")
struct TextSourcesStoreTests {
    private enum Interrupted: Error { case checkpoint }

    @Test(arguments: [false, true])
    func versionEightMigrationProtectsConflictAndInterruptedBackup(conflict: Bool) async throws {
        try await fixture { url in
            let store = try await ProjectStore.create(at: url, name: "升级保护")
            _ = try await store.createTextDocument(text: "保留原稿")
            try await store.close()
            let file = url.appendingPathComponent("project.json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var docs = try #require(object["documents"] as? [[String: Any]])
            for i in docs.indices { docs[i].removeValue(forKey: "textSources") }
            object["documents"] = docs; object["schemaVersion"] = 8
            let original = try JSONSerialization.data(withJSONObject: object)
            try original.write(to: file)
            let backup = url.appendingPathComponent(ProjectStore.versionEightBackupFilename)
            if conflict {
                let existing = Data("another backup".utf8); try existing.write(to: backup)
                await #expect(throws: ProjectStoreError.self) { try await ProjectStore.open(at: url) }
                #expect(try Data(contentsOf: backup) == existing)
            } else {
                await #expect(throws: Interrupted.self) {
                    try await ProjectStore.open(at: url, migrationCheckpoint: { point in
                        if point == .backupDurable { throw Interrupted.checkpoint }
                    })
                }
                #expect(try Data(contentsOf: backup) == original)
            }
            #expect(try Data(contentsOf: file) == original)
            if !conflict {
                let reopened = try await ProjectStore.open(at: url)
                #expect(await reopened.snapshot().activeDocument?.textDraft?.text == "保留原稿")
                #expect(await reopened.snapshot().schemaVersion == 10)
                try await reopened.close()
            }
        }
    }

    @Test func sourcesAndAnswerPersistBesideBodyAndSurviveReopen() async throws {
        try await fixture { url in
            let store = try await ProjectStore.create(at: url, name: "资料项目")
            let created = try await store.createTextDocument(text: "原稿 👩‍💻")
            let draft = try #require(created.activeDocument?.textDraft)
            let original = try #require(created.activeDocument?.textSources)
            var note = try notebook()
            let saved = try await store.saveTextSources(note, documentID: draft.id,
                expectedRevision: original.revision, expectedDocumentRevision: draft.revision)
            #expect(saved.activeDocument?.textDraft == draft)
            let submission = try TextSourcesContext.makeSubmission(notebook: note, target: draft,
                modelID: "fixture-qwen", modelRevision: "fixture-revision")
            let previous = note.revision
            note.records.append(.init(submission: submission, answer: "资料中的代号是蓝桉。[S1]"))
            note.revision = UUID()
            _ = try await store.saveTextSources(note, documentID: draft.id,
                expectedRevision: previous, expectedDocumentRevision: draft.revision)
            let edited = try TextDraftDocument(id: draft.id, text: "手动继续编辑")
            _ = try await store.saveTextDraft(edited, documentID: draft.id, expectedRevision: draft.revision)
            try await store.close()
            let moved = url.deletingLastPathComponent().appendingPathComponent("移动后的项目.dproject")
            try FileManager.default.moveItem(at: url, to: moved)
            let reopened = try await ProjectStore.open(at: moved)
            let after = await reopened.snapshot()
            #expect(after.activeDocument?.textDraft == edited)
            #expect(after.activeDocument?.textSources == note)
            #expect(try after.activeDocument?.textSources?.sources.first?.validatedText() == "代号：蓝桉\r\nCafe\u{301} 👩‍💻")
            try await reopened.close()
        }
    }

    @Test func staleRevisionsAndCorruptSourcesDoNotChangeDisk() async throws {
        try await fixture { url in
            let store = try await ProjectStore.create(at: url, name: "冲突保护")
            let manifest = try await store.createTextDocument(text: "原文")
            let draft = try #require(manifest.activeDocument?.textDraft)
            let original = try #require(manifest.activeDocument?.textSources)
            let before = try Data(contentsOf: url.appendingPathComponent("project.json"))
            let note = try notebook()
            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.saveTextSources(note, documentID: draft.id,
                    expectedRevision: UUID(), expectedDocumentRevision: draft.revision)
            }
            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.saveTextSources(note, documentID: draft.id,
                    expectedRevision: original.revision, expectedDocumentRevision: UUID())
            }
            var wrong = note; wrong.excerpts = [try TextSourceExcerpt(source: source("another"), range: NSRange(location: 0, length: 1))]
            await #expect(throws: (any Error).self) {
                try await store.saveTextSources(wrong, documentID: draft.id,
                    expectedRevision: original.revision, expectedDocumentRevision: draft.revision)
            }
            #expect(try Data(contentsOf: url.appendingPathComponent("project.json")) == before)
            try await store.close()
        }
    }

    @Test func externalCanonicallyEquivalentQuestionIsProtected() async throws {
        try await fixture { url in
            let store = try await ProjectStore.create(at: url, name: "字节保护")
            let created = try await store.createTextDocument()
            let draft = try #require(created.activeDocument?.textDraft)
            let original = try #require(created.activeDocument?.textSources)
            var note = try notebook(); note.question = "é"
            _ = try await store.saveTextSources(note, documentID: draft.id,
                expectedRevision: original.revision, expectedDocumentRevision: draft.revision)
            let file = url.appendingPathComponent("project.json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var docs = try #require(object["documents"] as? [[String: Any]])
            let index = try #require(docs.firstIndex { $0["kind"] as? String == "text" })
            var payload = try #require(docs[index]["textSources"] as? [String: Any])
            payload["question"] = "e\u{301}"; docs[index]["textSources"] = payload; object["documents"] = docs
            let external = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            try external.write(to: file, options: .atomic)
            let changed = try TextDraftDocument(id: draft.id, text: "不覆盖")
            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.saveTextDraft(changed, documentID: draft.id, expectedRevision: draft.revision)
            }
            #expect(try Data(contentsOf: file) == external)
            try await store.close(preserveExternalChanges: true)
        }
    }

    @Test func legacyEightBacksUpOriginalAndRejectsUnimplementedNine() async throws {
        try await fixture { url in
            let store = try await ProjectStore.create(at: url, name: "旧版")
            _ = try await store.createTextDocument(text: "旧原稿")
            try await store.close()
            let file = url.appendingPathComponent("project.json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var docs = try #require(object["documents"] as? [[String: Any]])
            for index in docs.indices { docs[index].removeValue(forKey: "textSources") }
            object["documents"] = docs; object["schemaVersion"] = 9
            let nine = try JSONSerialization.data(withJSONObject: object)
            try nine.write(to: file)
            await #expect(throws: ProjectStoreError.unsupportedSchema(9)) { try await ProjectStore.open(at: url) }
            #expect(try Data(contentsOf: file) == nine)
            object["schemaVersion"] = 8
            let eight = try JSONSerialization.data(withJSONObject: object)
            try eight.write(to: file)
            let reopened = try await ProjectStore.open(at: url)
            #expect(await reopened.snapshot().schemaVersion == 10)
            #expect(await reopened.snapshot().activeDocument?.textDraft?.text == "旧原稿")
            #expect(await reopened.snapshot().activeDocument?.textSources?.records.isEmpty == true)
            #expect(try Data(contentsOf: url.appendingPathComponent(ProjectStore.versionEightBackupFilename)) == eight)
            try await reopened.close()
        }
    }

    @Test(arguments: [false, true])
    func currentMissingOrNullRecordIsCorruption(null: Bool) async throws {
        try await fixture { url in
            let store = try await ProjectStore.create(at: url, name: "新格式")
            _ = try await store.createTextDocument()
            try await store.close()
            let file = url.appendingPathComponent("project.json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var docs = try #require(object["documents"] as? [[String: Any]])
            let index = try #require(docs.firstIndex { $0["kind"] as? String == "text" })
            if null { docs[index]["textSources"] = NSNull() } else { docs[index].removeValue(forKey: "textSources") }
            object["documents"] = docs
            let bad = try JSONSerialization.data(withJSONObject: object)
            try bad.write(to: file)
            await #expect(throws: ProjectStoreError.self) { try await ProjectStore.open(at: url) }
            #expect(try Data(contentsOf: file) == bad)
        }
    }

    private func source(_ text: String = "代号：蓝桉\r\nCafe\u{301} 👩‍💻") throws -> TextSourceSnapshot {
        try TextSourceSnapshot(displayName: "资料 👩‍💻.md", bytes: Data(text.utf8))
    }
    private func notebook() throws -> TextSourcesNotebook {
        let value = try source()
        let excerpt = try TextSourceExcerpt(source: value,
            range: NSRange(location: 0, length: value.validatedText().utf16.count))
        return TextSourcesNotebook(question: "代号是什么？", sources: [value], excerpts: [excerpt])
    }
    private func fixture(_ body: (URL) async throws -> Void) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: path).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root.resolvingSymlinksInPath().appendingPathComponent("资料.dproject"))
    }
}
