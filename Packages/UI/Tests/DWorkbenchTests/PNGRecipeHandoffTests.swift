import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("PNG offline product handoff")
struct PNGRecipeHandoffTests {
    @Test func frozenRunToNewCopyAndIndependentDraftReopens() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "PNG fixture")
            let request = InferenceRequest(model: fixture.request().model,
                input: .image(.init(prompt: "中文 e\u{301} 👩🏽‍🎨", width: 8, height: 8, steps: 4, guidanceScale: 1, seed: UInt64.max)))
            _ = try await store.enqueue(request: request)
            let original = try fixture.publishPNG(jobID: request.id)
            let manifest = try await store.complete(id: request.id,
                result: .init(artifacts: [.init(url: original, mediaType: "image/png")], metadata: ["fixture": "synthetic pixels, no inference"]))
            let asset = try #require(manifest.assets.first)
            _ = try await store.saveDraft(.init(prompt: "new UI text is NOT historical input"))
            let manifestURL = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            let manifestBytes = try Data(contentsOf: manifestURL), pngBytes = try Data(contentsOf: original)
            let prepared = try await store.prepareRecipePNG(assetID: asset.id, disclosure: .privateArchive)
            let output = fixture.directory.appendingPathComponent("中文 new copy.png")
            try ProjectStore.publishRecipePNG(prepared, to: output)
            #expect(try Data(contentsOf: original) == pngBytes)
            #expect(try Data(contentsOf: manifestURL) == manifestBytes)
            try await store.close()
            // Only this selected PNG is read after the original store is closed.
            let (readback, inspection) = try ProjectStore.readRecipePNG(at: output)
            #expect(readback == prepared)
            let recipe = try #require(inspection.recipe)
            #expect(recipe.prompt == .value("中文 e\u{301} 👩🏽‍🎨"))
            #expect(recipe.seed == .value("18446744073709551615"))
            #expect(recipe.runID == request.id && recipe.assetID == asset.id)
            #expect(recipe.assetVersion != asset.id)
            #expect(recipe.modelSource == .unknown)
            #expect(recipe.modelRevision == .value("fixture-revision"))
            #expect(recipe.weightsManifestSHA256 == .unknown)
            #expect(recipe.claim == .callerDeclared)
            #expect(!String(decoding: prepared, as: UTF8.self).contains(fixture.directory.path))
            let freshURL = fixture.directory.appendingPathComponent("Independent.dproject")
            let fresh = try await ProjectStore.create(at: freshURL, name: "Independent")
            let before = await fresh.snapshot()
            let after = try await fresh.createRecipeDocument(recipe)
            #expect(after.documents.count == before.documents.count + 1)
            #expect(after.documents.first == before.documents.first)
            #expect(after.draft.prompt == "中文 e\u{301} 👩🏽‍🎨")
            #expect(after.draft.seedText == "18446744073709551615" && !after.draft.randomSeed)
            try await fresh.close()
            let reopened = try await ProjectStore.open(at: freshURL)
            #expect(await reopened.snapshot() == after)
            try await reopened.close()
        }
    }

    @Test func publicProjectionCannotCreateFakePromptAndProtectsTargets() async throws {
        try await preparedFixture { fixture, store, asset, original in
            let data = try await store.prepareRecipePNG(assetID: asset.id, disclosure: .publicShare)
            let recipe = try #require(PNGRecipeCodec.inspect(data).recipe)
            #expect(recipe.prompt == .withheld && recipe.structuredInputRevision == .withheld)
            let before = await store.snapshot()
            await #expect(throws: PNGRecipeError.invalidRecipe) { try await store.createRecipeDocument(recipe) }
            #expect(await store.snapshot() == before)
            let destination = fixture.directory.appendingPathComponent("existing.png")
            let sentinel = Data("existing work".utf8); try sentinel.write(to: destination)
            #expect(throws: ProjectStoreError.self) { try ProjectStore.publishRecipePNG(data, to: destination) }
            #expect(try Data(contentsOf: destination) == sentinel)
            let alias = fixture.directory.appendingPathComponent("alias.png")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
            #expect(throws: ProjectStoreError.self) { try ProjectStore.publishRecipePNG(data, to: alias) }
            #expect(throws: ProjectStoreError.self) { try ProjectStore.readRecipePNG(at: alias) }
            #expect(try Data(contentsOf: original) != data)
        }
    }

    @Test func externalManifestChangeRefusesRecipePreparationAndDraftCreation() async throws {
        try await preparedFixture { fixture, store, asset, _ in
            let data = try await store.prepareRecipePNG(assetID: asset.id, disclosure: .privateArchive)
            let recipe = try #require(PNGRecipeCodec.inspect(data).recipe)
            let url = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            var changed = await store.snapshot(); changed.name = "external author"
            let bytes = try JSONEncoder().encode(changed); try bytes.write(to: url)
            await #expect(throws: ProjectStoreError.externalModification) { try await store.prepareRecipePNG(assetID: asset.id, disclosure: .privateArchive) }
            await #expect(throws: ProjectStoreError.externalModification) { try await store.createRecipeDocument(recipe) }
            #expect(try Data(contentsOf: url) == bytes)
            // No restoration of external bytes. Actor close deliberately checks external changes.
        }
    }

    @Test func publishFailureBeforeAndAfterCommitPreservesOwnership() async throws {
        enum Fault: Error { case injected }
        try await preparedFixture { fixture, store, asset, original in
            let data = try await store.prepareRecipePNG(assetID: asset.id, disclosure: .privateArchive)
            let source = try Data(contentsOf: original)
            for afterPublish in [false, true] {
                let target = fixture.directory.appendingPathComponent("failure-\(afterPublish).png")
                #expect(throws: Fault.injected) {
                    try ProjectStore.publishRecipePNG(data, to: target, checkpoint: { checkpoint in
                        switch checkpoint {
                        case .contentDurable: if !afterPublish { throw Fault.injected }
                        case .published: if afterPublish { throw Fault.injected }
                        }
                    })
                }
                #expect(FileManager.default.fileExists(atPath: target.path) == afterPublish)
                if afterPublish { #expect(try Data(contentsOf: target) == data) }
                #expect(try Data(contentsOf: original) == source)
            }
        }
    }

    @Test func knownContainerWithInvalidPixelsIsNotAUsableAsset() throws {
        // Valid CRC/chunk structure, deliberately invalid zlib bytes. Codec is not a pixel decoder.
        var bytes = Data([137,80,78,71,13,10,26,10])
        func chunk(_ name: String, _ value: Data) -> Data {
            func word(_ value: UInt32) -> Data { Data([UInt8(truncatingIfNeeded:value >> 24),UInt8(truncatingIfNeeded:value >> 16),UInt8(truncatingIfNeeded:value >> 8),UInt8(truncatingIfNeeded:value)]) }
            let payload = Data(name.utf8) + value
            var crc: UInt32 = 0xffffffff
            for b in payload { crc ^= UInt32(b); for _ in 0..<8 { crc = crc & 1 == 1 ? crc >> 1 ^ 0xedb88320 : crc >> 1 } }
            return word(UInt32(value.count)) + payload + word(crc ^ 0xffffffff)
        }
        bytes += chunk("IHDR", Data([0,0,0,1,0,0,0,1,8,0,0,0,0]))
        bytes += chunk("IDAT", Data([0])); bytes += chunk("IEND", Data())
        #expect(try PNGRecipeCodec.inspect(bytes).recipe == nil)
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("invalid-pixels-\(UUID()).png")
        try bytes.write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: ProjectStoreError.self) { try ProjectStore.readRecipePNG(at: file) }
    }

    private func preparedFixture(_ body: @Sendable (ProjectFixture, ProjectStore, ProjectAsset, URL) async throws -> Void) async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "fixture")
            let request = fixture.request(); _ = try await store.enqueue(request: request)
            let url = try fixture.publishPNG(jobID: request.id)
            let manifest = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: url, mediaType: "image/png")]))
            let asset = try #require(manifest.assets.first)
            try await body(fixture, store, asset, url)
            // Some cases deliberately leave an external change; don't overwrite it to close.
            if (try? await store.flush()) != nil { try await store.close() }
        }
    }
}
