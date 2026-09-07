import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Document ownership and candidate persistence")
struct ProjectDocumentStoreTests {
    @Test func documentsKeepIndependentDraftsAndImmutableTaskOwnership() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "两份探索")
            let firstID = await store.snapshot().activeDocumentID
            let firstDraft = ProjectDraft(prompt: "First exploration", randomSeed: false, seedText: "0")
            _ = try await store.saveDraft(firstDraft, documentID: firstID)
            let second = try await store.createDocument(name: "构图 B", draft: .init(prompt: "Second draft", randomSeed: false, seedText: "-"))
            let secondID = second.activeDocumentID
            #expect(firstID != secondID)
            let request = fixture.request(seed: 0)
            _ = try await store.enqueue(request: request, documentID: firstID)
            let image = try fixture.publishPNG(jobID: request.id)
            let finished = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            #expect(finished.activeDocumentID == secondID)
            #expect(finished.jobs[0].documentID == firstID)
            #expect(finished.jobs[0].request == request)
            #expect(finished.documents.first { $0.id == firstID }?.draft == firstDraft)
            #expect(finished.activeDocument?.draft.seedText == "-")
            #expect(finished.activeDocument?.selectedAssetID == nil)
            #expect(finished.documents.allSatisfy { $0.adoptedAssetID == nil })
            _ = try await store.renameDocument(id: firstID, name: "构图 A")
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            let snapshot = await reopened.snapshot()
            #expect(snapshot.documents.count == 2)
            #expect(snapshot.activeDocumentID == secondID)
            #expect(snapshot.documents.first { $0.id == firstID }?.name == "构图 A")
            #expect(snapshot.documents.first { $0.id == firstID }?.draft == firstDraft)
            #expect(try await reopened.selectDocument(id: firstID).draft == firstDraft)
            try await reopened.close()
        }
    }

    @Test func candidateAnnotationsSelectionAndAdoptionPersistWithoutChangingMedia() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "候选整理")
            let documentID = await store.snapshot().activeDocumentID
            let first = fixture.request(), second = fixture.request(seed: 0)
            _ = try await store.enqueue(request: first, documentID: documentID)
            let image = try fixture.publishPNG(jobID: first.id)
            let originalBytes = try Data(contentsOf: image)
            let completed = try await store.complete(id: first.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            let firstAsset = try #require(completed.assets.first)
            _ = try await store.updateAsset(id: firstAsset.id, name: "安静的光线", note: "保留阴影\n下一轮比较背景", isFavorite: true)
            _ = try await store.adoptAsset(id: firstAsset.id, documentID: documentID)
            _ = try await store.enqueue(request: second, documentID: documentID)
            let secondImage = try fixture.publishPNG(jobID: second.id)
            let secondCompleted = try await store.complete(id: second.id, result: .init(artifacts: [.init(url: secondImage, mediaType: "image/png")]))
            let secondAsset = try #require(secondCompleted.assets.last)
            let selected = try await store.setSelectedAsset(secondAsset.id, documentID: documentID)
            #expect(selected.activeDocument?.adoptedAssetID == firstAsset.id)
            #expect(selected.activeDocument?.selectedAssetID == secondAsset.id)
            let revision = selected.revision
            #expect(try await store.updateAsset(id: firstAsset.id, isFavorite: true).revision == revision)
            #expect(try await store.setSelectedAsset(secondAsset.id, documentID: documentID).revision == revision)
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            let restored = await reopened.snapshot()
            #expect(restored.activeDocument?.adoptedAssetID == firstAsset.id)
            #expect(restored.activeDocument?.selectedAssetID == secondAsset.id)
            #expect(restored.assets[0].name == "安静的光线")
            #expect(restored.assets[0].isFavorite)
            #expect(restored.assets[0].note == "保留阴影\n下一轮比较背景")
            #expect(restored.assets[0].relativePath == firstAsset.relativePath)
            #expect(try Data(contentsOf: image) == originalBytes)
            #expect(try await reopened.adoptAsset(id: nil, documentID: documentID).activeDocument?.adoptedAssetID == nil)
            try await reopened.close()
        }
    }

    @Test func sourceReferencesReuseOneAssetWithoutAdoptingAnotherDocumentsCandidate() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "条件复用")
            let oldDocumentID = await store.snapshot().activeDocumentID
            let oldDraft = ProjectDraft(prompt: "Leave this unfinished", randomSeed: false, seedText: "-")
            _ = try await store.saveDraft(oldDraft, documentID: oldDocumentID)
            let request = fixture.request(seed: 0)
            _ = try await store.enqueue(request: request, documentID: oldDocumentID)
            let image = try fixture.publishPNG(jobID: request.id)
            let completed = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            let asset = try #require(completed.assets.first)
            let fork = try await store.createDocument(name: "继续探索", draft: .init(prompt: "A red teapot", randomSeed: false, seedText: "0"), sourceAssetID: asset.id)
            #expect(fork.documents.first { $0.id == oldDocumentID }?.draft == oldDraft)
            #expect(fork.activeDocument?.sourceAssetID == asset.id)
            #expect(fork.activeDocument?.selectedAssetID == asset.id)
            #expect(fork.activeDocument?.adoptedAssetID == nil)
            #expect(fork.assets == completed.assets)
            #expect(fork.jobs == completed.jobs)
            await #expect(throws: ProjectStoreError.self) { try await store.adoptAsset(id: asset.id, documentID: fork.activeDocumentID) }
            #expect(await store.snapshot() == fork)
            #expect(try await store.assetURL(for: asset) == image)
            try await store.close()
        }
    }

    @Test func invalidDocumentAndCrossDocumentReferencesNeverCommit() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "引用边界")
            let firstID = await store.snapshot().activeDocumentID
            let request = fixture.request()
            _ = try await store.enqueue(request: request, documentID: firstID)
            let image = try fixture.publishPNG(jobID: request.id)
            let completed = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            let assetID = try #require(completed.assets.first?.id)
            let baseline = try await store.createDocument(name: "独立文档")
            await #expect(throws: ProjectStoreError.missingDocument) { try await store.enqueue(request: fixture.request(), documentID: UUID()) }
            await #expect(throws: ProjectStoreError.missingDocument) { try await store.saveDraft(.init(prompt: "Lost"), documentID: UUID()) }
            await #expect(throws: ProjectStoreError.self) { try await store.renameDocument(id: firstID, name: " \n") }
            await #expect(throws: ProjectStoreError.missingAsset) { try await store.createDocument(name: "无效来源", sourceAssetID: UUID()) }
            await #expect(throws: ProjectStoreError.self) { try await store.setSelectedAsset(assetID, documentID: baseline.activeDocumentID) }
            await #expect(throws: ProjectStoreError.self) { try await store.adoptAsset(id: UUID(), documentID: firstID) }
            await #expect(throws: ProjectStoreError.self) { try await store.updateAsset(id: assetID, name: "") }
            #expect(await store.snapshot() == baseline)
            try await store.close()
        }
    }

    @Test func failedCandidateAndDocumentSavesPreserveSnapshotAndArtwork() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "保存失败")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let image = try fixture.publishPNG(jobID: request.id)
            let baseline = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            let bytes = try Data(contentsOf: image)
            let assetID = try #require(baseline.assets.first?.id)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.project.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.project.path) }
            await #expect(throws: ProjectStoreError.self) { try await store.createDocument(name: "尚未保存") }
            await #expect(throws: ProjectStoreError.self) { try await store.updateAsset(id: assetID, note: "尚未保存") }
            await #expect(throws: ProjectStoreError.self) { try await store.adoptAsset(id: assetID, documentID: baseline.activeDocumentID) }
            #expect(await store.snapshot() == baseline)
            #expect(try Data(contentsOf: image) == bytes)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.project.path)
            #expect(try await store.updateAsset(id: assetID, note: "已保存").revision == baseline.revision + 1)
            try await store.close()
        }
    }

    @Test(arguments: ["duplicate-document", "missing-active", "missing-job-owner", "missing-source", "cross-adoption", "missing-v2-job-owner"])
    func malformedVersionTwoReferencesAreRejectedWithoutRewrite(defect: String) async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "校验 v2")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let image = try fixture.publishPNG(jobID: request.id)
            _ = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            var manifest = try await store.createDocument(name: "另一文档")
            try await store.close()
            switch defect {
            case "duplicate-document": manifest.documents.append(manifest.documents[0])
            case "missing-active": manifest.activeDocumentID = UUID()
            case "missing-job-owner": manifest.jobs[0].documentID = UUID()
            case "missing-source": manifest.documents[0].sourceAssetID = UUID()
            case "cross-adoption": manifest.documents[1].adoptedAssetID = manifest.assets[0].id
            default: break
            }
            var bytes = try JSONEncoder().encode(manifest)
            if defect == "missing-v2-job-owner" {
                var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                var jobs = try #require(json["jobs"] as? [[String: Any]])
                jobs[0].removeValue(forKey: "documentID")
                json["jobs"] = jobs
                bytes = try JSONSerialization.data(withJSONObject: json)
            }
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            try bytes.write(to: file)
            await #expect(throws: ProjectStoreError.self) { try await ProjectStore.open(at: fixture.project) }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
}
