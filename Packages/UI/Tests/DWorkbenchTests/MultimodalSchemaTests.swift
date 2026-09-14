import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Combined image-reference and text-sources formats")
struct MultimodalSchemaTests {
    @Test func referenceNinePreservesFrozenRunAndInitializesOnlyMissingNotebook() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "九版 🎨")
            let imageID = await store.snapshot().activeDocumentID
            let png = try fixture.publishPNG(jobID: UUID(), size: 512)
            let imported = try await store.importImageReference(at: png, name: "原图", documentID: imageID)
            let asset = try #require(imported.assets.first)
            let original = try Data(contentsOf: fixture.project.appendingPathComponent(asset.relativePath))
            let run = UUID()
            let input = try await store.prepareImageReference(assetID: asset.id, runID: run)
            let inputBytes = try Data(contentsOf: input.url)
            let request = ImageReferenceProjectTests().request(input, id: run, fixture: fixture)
            _ = try await store.enqueue(request: request, documentID: imageID, capturedImageReferenceAssetID: asset.id)
            let output = try fixture.publishPNG(jobID: run, size: 512)
            _ = try await store.complete(id: run, result: .init(artifacts: [.init(url: output, mediaType: "image/png")]))
            var legacy = try await store.createTextDocument(text: "中文 e\u{301} 👩‍💻")
            let textID = legacy.activeDocumentID
            legacy.schemaVersion = 9
            for index in legacy.documents.indices { legacy.documents[index].textSources = nil }
            try await store.close()
            let raw = try JSONEncoder().encode(legacy)
            let manifest = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            try raw.write(to: manifest)
            let reopened = try await ProjectStore.open(at: fixture.project)
            let current = await reopened.snapshot()
            #expect(current.schemaVersion == ProjectManifest.currentSchemaVersion)
            #expect(current.jobs == legacy.jobs)
            #expect(current.assets == legacy.assets)
            #expect(current.documents.first { $0.id == imageID } == legacy.documents.first { $0.id == imageID })
            #expect(current.documents.first { $0.id == textID }?.textDraft == legacy.documents.first { $0.id == textID }?.textDraft)
            let beforeText = try #require(legacy.documents.first { $0.id == textID }?.textDraft?.text)
            let afterText = try #require(current.documents.first { $0.id == textID }?.textDraft?.text)
            #expect(beforeText.utf8.elementsEqual(afterText.utf8))
            #expect(current.documents.first { $0.id == textID }?.textSources?.sources.isEmpty == true)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionNineBackupFilename)) == raw)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(asset.relativePath)) == original)
            #expect(try Data(contentsOf: input.url) == inputBytes)
            try await reopened.close()
        }
    }

    @Test func textTenPreservesHistoryAndCoexistsWithReferenceAfterReopen() async throws {
        try await withFixture { fixture in
            var old = try JSONDecoder().decode(ProjectManifest.self, from: TextSourcesLegacyFixture.project)
            let oldTextIndex = try #require(old.documents.firstIndex { $0.kind == .text })
            let oldDraft = try #require(old.documents[oldTextIndex].textDraft)
            var mixed = try #require(old.documents[oldTextIndex].textSources)
            let priorSubmission = try TextSourcesContext.makeSubmission(notebook: mixed, target: oldDraft,
                modelID: "model", modelRevision: "revision")
            mixed.records.append(.init(submission: priorSubmission, answer: "旧v2回答：京都。[S1]"))
            old.documents[oldTextIndex].textSources = mixed
            let rawTen = try JSONEncoder().encode(old)
            try await installLegacy(rawTen, at: fixture.project)
            let store = try await ProjectStore.open(at: fixture.project)
            let migrated = await store.snapshot()
            let original = try #require(old.activeDocument?.textSources)
            let text = try #require(migrated.activeDocument?.textDraft)
            #expect(migrated.schemaVersion == ProjectManifest.currentSchemaVersion)
            #expect(migrated.activeDocument?.textSources == original)
            #expect(migrated.activeDocument?.textDraft == old.activeDocument?.textDraft)
            let oldBody = try #require(old.activeDocument?.textDraft?.text)
            let newBody = try #require(migrated.activeDocument?.textDraft?.text)
            #expect(oldBody.utf8.elementsEqual(newBody.utf8))
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionTenBackupFilename)) == rawTen)
            #expect(migrated.activeDocument?.textSources?.records.map(\.submission.promptTemplate) == [.v1, .v2])
            for (before, after) in zip(original.records, migrated.activeDocument?.textSources?.records ?? []) {
                #expect(before.submission.request.prompt.utf8.elementsEqual(after.submission.request.prompt.utf8))
                #expect(before.answer.utf8.elementsEqual(after.answer.utf8))
            }
            var note = original
            note.revision = UUID()
            let submission = try TextSourcesContext.makeSubmission(notebook: note, target: text,
                modelID: "model", modelRevision: "revision")
            note.records.append(.init(submission: submission, answer: "蓝桉，京都。[S1]"))
            _ = try await store.saveTextSources(note, documentID: text.id, expectedRevision: original.revision,
                                               expectedDocumentRevision: text.revision)
            let image = try #require(migrated.documents.first { $0.kind == .image })
            let png = try fixture.publishPNG(jobID: UUID(), size: 512)
            let withReference = try await store.importImageReference(at: png, name: "跨域原件", documentID: image.id)
            let assetID = try #require(withReference.documents.first { $0.id == image.id }?.draft.referenceImageAssetID)
            try await store.close()
            let beforeReopen = try Data(contentsOf: fixture.project.appendingPathComponent("project.json"))
            let reopened = try await ProjectStore.open(at: fixture.project)
            let current = await reopened.snapshot()
            #expect(current.documents.first { $0.id == text.id }?.textSources == note)
            #expect(current.documents.first { $0.id == text.id }?.textSources?.records.map(\.submission.promptTemplate) == [.v1, .v2, .v2])
            #expect(current.documents.first { $0.id == image.id }?.draft.referenceImageAssetID == assetID)
            #expect(current.activeDocument?.textDraft == text)
            try await reopened.close()
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent("project.json")) == beforeReopen)
        }
    }

    @Test(arguments: [9, 10])
    func originalBackupCollisionAndInterruptedPublicationAreSafe(version: Int) async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "备份与锁")
            var old = await store.snapshot(); old.schemaVersion = version
            try await store.close()
            let file = fixture.project.appendingPathComponent("project.json")
            let original = try JSONEncoder().encode(old)
            let backup = fixture.project.appendingPathComponent(version == 9
                ? ProjectStore.versionNineBackupFilename : ProjectStore.versionTenBackupFilename)
            try original.write(to: file)
            let sentinel = Data("独立备份，不允许覆盖".utf8)
            try sentinel.write(to: backup)
            await #expect(throws: (any Error).self) { _ = try await ProjectStore.open(at: fixture.project) }
            #expect(try Data(contentsOf: file) == original)
            #expect(try Data(contentsOf: backup) == sentinel)
            // Remove only this explicitly created fixture sentinel to exercise retry.
            try FileManager.default.removeItem(at: backup)
            for point in [ProjectMigrationCheckpoint.backupDurable, .beforePublication] {
                await #expect(throws: Interrupted.self) {
                    _ = try await ProjectStore.open(at: fixture.project, migrationCheckpoint: { checkpoint in
                        if checkpoint == point { throw Interrupted() }
                    })
                }
                #expect(try Data(contentsOf: file) == original)
                #expect(try Data(contentsOf: backup) == original)
            }
            await #expect(throws: Interrupted.self) {
                _ = try await ProjectStore.open(at: fixture.project, migrationCheckpoint: { checkpoint in
                    if checkpoint == .publicationDurable { throw Interrupted() }
                })
            }
            let published = try Data(contentsOf: file)
            #expect(try JSONDecoder().decode(ProjectManifest.self, from: published).schemaVersion == ProjectManifest.currentSchemaVersion)
            #expect(try Data(contentsOf: backup) == original)
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().schemaVersion == ProjectManifest.currentSchemaVersion)
            try await reopened.close()
            #expect(try Data(contentsOf: file) == published)
        }
    }

    @Test(arguments: [9, 10, 11, 12])
    func declaredDomainsAndRequiredSourcesAreStrict(version: Int) async throws {
        try await withFixture { fixture in
            try await installLegacy(TextSourcesLegacyFixture.project, at: fixture.project)
            let file = fixture.project.appendingPathComponent("project.json")
            for field in ["missing", "null", "wrong-type"] {
                var object = try #require(JSONSerialization.jsonObject(with: TextSourcesLegacyFixture.project) as? [String: Any])
                object["schemaVersion"] = version
                var docs = try #require(object["documents"] as? [[String: Any]])
                let index = try #require(docs.firstIndex { $0["kind"] as? String == "text" })
                if version != 9 {
                    if field == "missing" { docs[index].removeValue(forKey: "textSources") }
                    else { docs[index]["textSources"] = field == "null" ? NSNull() : true as Any }
                }
                // v9 retains an otherwise valid but undeclared notebook; it must not be silently cleared.
                object["documents"] = docs
                let raw = try JSONSerialization.data(withJSONObject: object)
                try raw.write(to: file)
                await #expect(throws: (any Error).self) { _ = try await ProjectStore.open(at: fixture.project) }
                #expect(try Data(contentsOf: file) == raw)
                #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("project.v\(version).backup.json").path))
            }
        }
    }

    @Test func textTenCannotSilentlyGainReferenceDomain() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "分支域隔离")
            let imageID = await store.snapshot().activeDocumentID
            let png = try fixture.publishPNG(jobID: UUID(), size: 512)
            var snapshot = try await store.importImageReference(at: png, name: "原件", documentID: imageID)
            try await store.close()
            snapshot.schemaVersion = 10
            let file = fixture.project.appendingPathComponent("project.json")
            let raw = try JSONEncoder().encode(snapshot)
            try raw.write(to: file)
            await #expect(throws: (any Error).self) { _ = try await ProjectStore.open(at: fixture.project) }
            #expect(try Data(contentsOf: file) == raw)
            #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(ProjectStore.versionTenBackupFilename).path))
        }
    }

    private struct Interrupted: Error {}

    private func installLegacy(_ data: Data, at project: URL) async throws {
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Tasks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        try data.write(to: project.appendingPathComponent("project.json"), options: .withoutOverwriting)
    }
}
