import CryptoKit
import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Reference image project ownership", .serialized)
struct ImageReferenceProjectTests {
    func request(_ ref: ImageReference, id: UUID, fixture: ProjectFixture) -> InferenceRequest {
        .init(id: id, model: fixture.request().model, input: .image(.init(prompt: "改成蓝色 e\u{301} 🎨",
            width: 512, height: 512, steps: 4, guidanceScale: 1, seed: 42,
            executionProfile: ImageExecutionCapability.referenceKlein4B.profile, referenceImage: ref)))
    }
    @Test func copyFreezeCompleteAdoptExportAndReopen() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "参考 🎨")
            let doc = await store.snapshot().activeDocumentID
            let source = try fixture.publishPNG(jobID: UUID(), size: 512)
            let original = try Data(contentsOf: source)
            let imported = try await store.importImageReference(at: source, name: "原图", documentID: doc)
            let assetID = try #require(imported.documents.first?.draft.referenceImageAssetID)
            let asset = try #require(imported.assets.first { $0.id == assetID })
            #expect(asset.role == .original)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(asset.relativePath)) == original)
            try Data("external modification".utf8).write(to: source)
            let id = UUID()
            let ref = try await store.prepareImageReference(assetID: assetID, runID: id)
            let bytes = try Data(contentsOf: ref.url)
            #expect(bytes.count == 512 * 512 * 3)
            #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == ref.sha256)
            _ = try await store.setImageReference(nil, documentID: doc)
            // Captured input survives later draft/reference changes; it is not read from current UI.
            _ = try await store.enqueue(request: request(ref, id: id, fixture: fixture), documentID: doc,
                                        capturedImageReferenceAssetID: assetID)
            let output = try fixture.publishPNG(jobID: id, size: 512)
            let completed = try await store.complete(id: id, result: .init(artifacts: [.init(url: output, mediaType: "image/png")]))
            let resultID = try #require(completed.jobs.first?.artifactIDs.first)
            #expect(completed.documents.first?.adoptedAssetID == nil)
            #expect(completed.documents.first?.draft.referenceImageAssetID == nil)
            #expect(completed.jobs.first?.imageReferenceAssetID == assetID)
            _ = try await store.adoptAsset(id: resultID, documentID: doc)
            let export = fixture.directory.appendingPathComponent("导出 🎨.png")
            try await store.export(assetID: resultID, to: export)
            let exportBytes = try Data(contentsOf: export)
            await #expect(throws: (any Error).self) { try await store.export(assetID: resultID, to: export) }
            #expect(try Data(contentsOf: export) == exportBytes)
            await #expect(throws: (any Error).self) { _ = try await store.prepareRecipePNG(assetID: resultID, disclosure: .privateArchive) }
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            let saved = await reopened.snapshot()
            #expect(saved.documents.first?.adoptedAssetID == resultID)
            #expect(saved.jobs.first?.request == request(ref, id: id, fixture: fixture))
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(asset.relativePath)) == original)
            try await reopened.close()
        }
    }

    @Test func tamperingAndDuplicateInputsAreRejected() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "保护")
            let doc = await store.snapshot().activeDocumentID
            let source = try fixture.publishPNG(jobID: UUID(), size: 512)
            let updated = try await store.importImageReference(at: source, name: "原图", documentID: doc)
            let asset = try #require(updated.assets.first)
            let id = UUID(); let ref = try await store.prepareImageReference(assetID: asset.id, runID: id)
            let originalBytes = try Data(contentsOf: ref.url)
            await #expect(throws: (any Error).self) { _ = try await store.prepareImageReference(assetID: asset.id, runID: id) }
            #expect(try Data(contentsOf: ref.url) == originalBytes)
            try Data(repeating: 0, count: originalBytes.count).write(to: ref.url)
            await #expect(throws: (any Error).self) {
                _ = try await store.enqueue(request: request(ref, id: id, fixture: fixture), documentID: doc,
                                            capturedImageReferenceAssetID: asset.id)
            }
            #expect(await store.snapshot().jobs.isEmpty)
            try Data("broken".utf8).write(to: fixture.project.appendingPathComponent(asset.relativePath))
            await #expect(throws: (any Error).self) { _ = try await store.prepareImageReference(assetID: asset.id, runID: UUID()) }
            try await store.close()
        }
    }

    @Test func sourceIdentityCannotBeSubstitutedAndReplacingSelectedOriginalIsValid() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "来源绑定")
            let doc = await store.snapshot().activeDocumentID
            let source = try fixture.publishPNG(jobID: UUID(), size: 512)
            let a = try await store.importImageReference(at: source, name: "A", documentID: doc)
            let aid = try #require(a.documents.first?.draft.referenceImageAssetID)
            _ = try await store.setSelectedAsset(aid, documentID: doc)
            let b = try await store.importImageReference(at: source, name: "B", documentID: doc)
            let bid = try #require(b.documents.first?.draft.referenceImageAssetID)
            #expect(aid != bid)
            #expect(b.documents.first?.selectedAssetID == nil)
            let run = UUID(); let ref = try await store.prepareImageReference(assetID: bid, runID: run)
            // Identical pixels do not license replacing the explicitly captured source identity.
            await #expect(throws: (any Error).self) {
                _ = try await store.enqueue(request: request(ref, id: run, fixture: fixture), documentID: doc,
                                            capturedImageReferenceAssetID: aid)
            }
            #expect(await store.snapshot().jobs.isEmpty)
            _ = try await store.enqueue(request: request(ref, id: run, fixture: fixture), documentID: doc,
                                        capturedImageReferenceAssetID: bid)
            #expect(await store.snapshot().jobs.first?.imageReferenceAssetID == bid)
            try await store.close()
        }
    }

    @Test func movedProjectRetainsOriginalAndPreparesNewRunInsideNewRoot() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "可移动参考")
            let doc = await store.snapshot().activeDocumentID
            let source = try fixture.publishPNG(jobID: UUID(), size: 512)
            let bytes = try Data(contentsOf: source)
            let imported = try await store.importImageReference(at: source, name: "原件", documentID: doc)
            let asset = try #require(imported.assets.first)
            let oldRun = UUID(); let oldInput = try await store.prepareImageReference(assetID: asset.id, runID: oldRun)
            _ = try await store.enqueue(request: request(oldInput, id: oldRun, fixture: fixture), documentID: doc,
                                        capturedImageReferenceAssetID: asset.id)
            try await store.close()
            let moved = fixture.directory.appendingPathComponent("移到这里 🎨.dproject")
            try FileManager.default.moveItem(at: fixture.project, to: moved)
            let reopened = try await ProjectStore.open(at: moved)
            #expect(await reopened.snapshot().documents.first?.draft.referenceImageAssetID == asset.id)
            #expect(try Data(contentsOf: moved.appendingPathComponent(asset.relativePath)) == bytes)
            let newRun = UUID(); let newInput = try await reopened.prepareImageReference(assetID: asset.id, runID: newRun)
            #expect(newInput.url.path.hasPrefix(moved.path + "/"))
            #expect(newInput.sha256 == oldInput.sha256)
            _ = try await reopened.enqueue(request: request(newInput, id: newRun, fixture: fixture), documentID: doc,
                                           capturedImageReferenceAssetID: asset.id)
            #expect(await reopened.snapshot().jobs.last?.imageReferenceAssetID == asset.id)
            try await reopened.close()
        }
    }

    @Test func versionEightBackedUpWithoutActivatingBrowsingSource() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "旧项目")
            var old = await store.snapshot(); old.schemaVersion = 8
            let source = try fixture.publishPNG(jobID: UUID(), size: 512)
            let original = ProjectAsset(relativePath: "Legacy.png", role: .original,
                                        metadata: .init(width: 512, height: 512))
            try FileManager.default.copyItem(at: source, to: fixture.project.appendingPathComponent(original.relativePath))
            old.assets = [original]
            old.documents[0].sourceAssetID = original.id
            old.documents[0].selectedAssetID = original.id
            try await store.close()
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            let bytes = try JSONEncoder().encode(old); try bytes.write(to: file)
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().schemaVersion == 9)
            #expect(await reopened.snapshot().documents.allSatisfy { $0.draft.referenceImageAssetID == nil })
            #expect(await reopened.snapshot().assets.first?.metadata.imageContentSHA256 == nil)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionEightBackupFilename)) == bytes)
            _ = try await reopened.setImageReference(original.id, documentID: old.activeDocumentID)
            #expect(await reopened.snapshot().documents.first?.draft.referenceImageAssetID == original.id)
            try await reopened.close()
        }
    }

    @Test func failedManifestSaveDoesNotOverwriteOriginalOrAttachReference() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "保存失败")
            let before = await store.snapshot()
            let source = try fixture.publishPNG(jobID: UUID(), size: 512)
            let bytes = try Data(contentsOf: source)
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            try Data("changed outside".utf8).write(to: file)
            await #expect(throws: (any Error).self) {
                _ = try await store.importImageReference(at: source, name: "不覆盖", documentID: before.activeDocumentID)
            }
            #expect(await store.snapshot() == before)
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try Data(contentsOf: file) == Data("changed outside".utf8))
            try await store.close(preserveExternalChanges: true)
        }
    }
}
