import DInference
import DRuntime
import zlib
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
        try await preparedFixture(publicFixture: true) { fixture, store, asset, original in
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

    private func preparedFixture(publicFixture: Bool = false, _ body: @Sendable (ProjectFixture, ProjectStore, ProjectAsset, URL) async throws -> Void) async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "fixture")
            let request = fixture.request(); _ = try await store.enqueue(request: request)
            let url = try fixture.publishPNG(jobID: request.id)
            if publicFixture {
                // ImageIO emits additional metadata. This explicitly synthetic fixture only
                // retains critical image chunks; production public rejection stays unchanged.
                let input = [UInt8](try Data(contentsOf: url)); var output = Data(input.prefix(8)); var offset = 8
                while offset < input.count {
                    let length = input[offset..<offset+4].reduce(0) { $0 << 8 | Int($1) }
                    let type = String(bytes: input[offset+4..<offset+8], encoding: .ascii)!
                    let end = offset + length + 12
                    if ["IHDR", "PLTE", "IDAT", "IEND", "tRNS"].contains(type) { output.append(contentsOf: input[offset..<end]) }
                    offset = end
                }
                try output.write(to: url)
            }
            let manifest = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: url, mediaType: "image/png")]))
            let asset = try #require(manifest.assets.first)
            try await body(fixture, store, asset, url)
            // Some cases deliberately leave an external change; don't overwrite it to close.
            if (try? await store.flush()) != nil { try await store.close() }
        }
    }
}

@Suite("PNG stream and session boundaries")
struct PNGRecipeBoundaryTests {
    @Test func exactStreamsAdam7AndWindowBoundaries() throws {
        // Independent known sizes: 8x8 grayscale is 72 filtered bytes, Adam7 is79.
        let valid: [(Int, Int, UInt8, Data)] = [
            (8,8,0,Data(repeating:0,count:72)), (8,8,1,Data(repeating:0,count:79)),
            (256,256,0,Data(repeating:0,count:257*256))]
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"].map { URL(fileURLWithPath:$0, isDirectory:true) } ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        for (width,height,interlace,raw) in valid {
            let stream = try compress(raw)
            let path=base.appendingPathComponent("streams-\(UUID()).png")
            defer { try? FileManager.default.removeItem(at:path) }
            try png(width:width,height:height,interlace:interlace,stream:stream).write(to:path)
            #expect(try ProjectStore.readRecipePNG(at:path).1.width == width)
            var badFilter=raw
            // For256wide rows, the next row starts at65792, beyond64KiB output window.
            badFilter[width==256 ? 65792 : 0]=5
            var badChecksum=stream; badChecksum[badChecksum.count-1] ^= 1
            let badStreams = [try compress(Data(raw.dropLast())), try compress(raw+Data([0])),
                              try compress(badFilter), badChecksum, stream+Data([0]), Data(stream.dropLast()),
                              try compress(raw+Data(repeating:0,count:65536))]
            for bad in badStreams {
                try png(width:width,height:height,interlace:interlace,stream:bad).write(to:path)
                #expect(throws:ProjectStoreError.self) { try ProjectStore.readRecipePNG(at:path) }
            }
        }
    }

    @MainActor @Test func sessionRejectsWrongProjectAndFlushesLatestDraftBeforeCreating() async throws {
        try await withFixture { @MainActor fixture in
            let session = makeSession()
            await session.createProject(at:fixture.project)
            let initial = try #require(session.manifest)
            let manifestURL=fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            let bytes=try Data(contentsOf:manifestURL)
            session.prompt="latest draft e\u{301} 👩🏽‍🎨"
            #expect(await session.createRecipeDocument(recipe(),expectedProjectID:UUID()) == false)
            #expect(try Data(contentsOf:manifestURL) == bytes)
            #expect(session.activeDocumentID == initial.activeDocumentID)
            #expect(await session.createRecipeDocument(recipe(),expectedProjectID:initial.id))
            let after=try #require(session.manifest)
            #expect(after.documents.count == initial.documents.count+1)
            #expect(after.documents.first?.draft.prompt == "latest draft e\u{301} 👩🏽‍🎨")
            #expect(after.activeDocument?.draft.prompt == "imported proposal")
            #expect(await session.requestClose())
            let reopened=try await ProjectStore.open(at:fixture.project)
            #expect(await reopened.snapshot() == after)
            try await reopened.close()
        }
    }

    @MainActor @Test func sessionCreationFailurePreservesNavigationAndUnsavedInput() async throws {
        try await withFixture { @MainActor fixture in
            let session=makeSession(); await session.createProject(at:fixture.project)
            let before=try #require(session.manifest)
            let url=fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            var external=before;external.name="external-author-change"
            let externalBytes=try JSONEncoder().encode(external);try externalBytes.write(to:url)
            session.prompt="unsaved input must survive"
            #expect(await session.createRecipeDocument(recipe(),expectedProjectID:before.id) == false)
            #expect(session.manifest == before)
            #expect(session.activeDocumentID == before.activeDocumentID)
            #expect(session.prompt == "unsaved input must survive")
            #expect(!session.isChangingProject && session.errorMessage != nil)
            #expect(try Data(contentsOf:url) == externalBytes)
            #expect(await session.requestClose() == false)
            #expect(try Data(contentsOf:url) == externalBytes)
        }
    }

    @MainActor private func makeSession() -> ProjectSession {
        ProjectSession(sessionFactory:{ _ in
            let runtime=try InferenceRuntime(backends:[],configuration:.init(memoryBudgetBytes:1024))
            return WorkbenchSession(engine:runtime,backendID:"no-generation",
                status:{ .init(activeRunID:nil,phase:nil,queuedRunIDs:[]) },shutdown:{await runtime.shutdown()},cleanup:{},validateModel:{_ in})
        }, settings:UserDefaults(suiteName:"D.PNGSessionTests.\(UUID())")!)
    }
    private func recipe() -> GenerationRecipe {
        .init(assetID:UUID(),assetVersion:UUID(),runID:UUID(),modelSource:.unknown,modelRevision:.unknown,weightsManifestSHA256:.unknown,prompt:.value("imported proposal"),structuredInputRevision:.unknown,seed:.value("18446744073709551615"),steps:.unknown,guidance:.unknown,width:.unknown,height:.unknown,scheduler:.unknown,computePrecision:.unknown,quantization:.unknown,implementationVersion:.unknown,mediaPayloadSHA256:.unknown,parents:[],claim:.callerDeclared)
    }
    private func compress(_ raw:Data) throws -> Data {
        var count=compressBound(uLong(raw.count));var output=Data(count:Int(count))
        let result=raw.withUnsafeBytes { source in output.withUnsafeMutableBytes { target in
            compress2(target.bindMemory(to:UInt8.self).baseAddress,&count,source.bindMemory(to:UInt8.self).baseAddress,uLong(raw.count),Z_BEST_SPEED)
        }}
        #expect(result==Z_OK);output.count=Int(count);return output
    }
    private func png(width:Int,height:Int,interlace:UInt8,stream:Data) -> Data {
        func word(_ n:UInt32)->Data {Data([UInt8(truncatingIfNeeded:n>>24),UInt8(truncatingIfNeeded:n>>16),UInt8(truncatingIfNeeded:n>>8),UInt8(truncatingIfNeeded:n)])}
        func chunk(_ type:String,_ data:Data)->Data {
            let checked=Data(type.utf8)+data
            let crc=checked.withUnsafeBytes { zlib.crc32(0,$0.bindMemory(to:UInt8.self).baseAddress,uInt($0.count)) }
            return word(UInt32(data.count))+checked+word(UInt32(crc))
        }
        let header=word(UInt32(width))+word(UInt32(height))+Data([8,0,0,0,interlace])
        return Data([137,80,78,71,13,10,26,10])+chunk("IHDR",header)+chunk("IDAT",stream)+chunk("IEND",Data())
    }
}
