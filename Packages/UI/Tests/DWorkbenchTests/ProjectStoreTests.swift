import CoreGraphics
import DInference
import Foundation
import ImageIO
import Testing
import DWorkbench
import UniformTypeIdentifiers

@Suite("Project package durability and recovery")
struct ProjectStoreTests {
    @Test(arguments: ["0", "-"])
    func unsentDraftPreservesLongPromptAndEditableSeedAcrossReopening(seedText: String) async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "未提交的草稿")
            #expect(try await store.saveDraft(.init()).revision == 0)
            let draft = ProjectDraft(prompt: String(repeating: "studio light\n", count: 90_000), randomSeed: false, seedText: seedText)
            #expect(draft.prompt.utf8.count > 1_024 * 1_024)
            #expect(try await store.saveDraft(draft).revision == 1)
            #expect(try await store.saveDraft(draft).revision == 1)
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            let manifest = await reopened.snapshot()
            #expect(manifest.draft == draft)
            #expect(manifest.jobs.isEmpty)
            #expect(manifest.revision == 1)
            try await reopened.close()
        }
    }

    @Test func laterDraftEditsDoNotChangePersistedInferenceRequest() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "草稿与任务")
            _ = try await store.saveDraft(.init(prompt: "A red teapot", randomSeed: false, seedText: "0"))
            let request = fixture.request(seed: 0)
            _ = try await store.enqueue(request: request)
            let edited = ProjectDraft(prompt: "A new unfinished idea", randomSeed: false, seedText: "-")
            let manifest = try await store.saveDraft(edited)
            #expect(manifest.jobs[0].request == request)
            #expect(manifest.draft == edited)
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().jobs[0].request == request)
            #expect(await reopened.snapshot().draft == edited)
            try await reopened.close()
        }
    }

    @Test func earlierVersionOneManifestWithoutDraftKeepsDefaultEditableState() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "已有项目")
            try await store.close()
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            var contents = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            contents["schemaVersion"] = 1
            contents.removeValue(forKey: "documents")
            contents.removeValue(forKey: "activeDocumentID")
            contents.removeValue(forKey: "draft")
            let bytes = try JSONSerialization.data(withJSONObject: contents)
            try bytes.write(to: file, options: .atomic)
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().draft == .init())
            #expect(await reopened.snapshot().schemaVersion == 2)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionOneBackupFilename)) == bytes)
            try await reopened.close()
        }
    }

    @Test func persistedRequestAndInterruptedQueue() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "茶壶研究")
            let request = fixture.request(seed: 0)
            _ = try await store.enqueue(request: request)
            _ = try await store.updateJob(id: request.id, state: .generating)
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            let manifest = await reopened.snapshot()
            #expect(manifest.jobs.count == 1)
            #expect(manifest.jobs[0].request == request)
            #expect(manifest.jobs[0].state == .interrupted)
            #expect(manifest.jobs[0].error?.contains("不会自动") == true)
            #expect(manifest.assets.isEmpty)
            try await reopened.close()
        }
    }

    @Test func completedArtworkRoundTripsAndExportsExactBytes() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "作品")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let image = try fixture.publishPNG(jobID: request.id)
            let expectedBytes = try Data(contentsOf: image)
            let manifest = try await store.complete(id: request.id, result: .init(
                artifacts: [.init(url: image, mediaType: "image/png")], metadata: ["model.revision": "fixture-revision"]))
            #expect(manifest.jobs[0].state == .completed)
            #expect(manifest.assets[0].metadata.width == 8)
            #expect(manifest.assets[0].metadata.height == 8)
            #expect(manifest.assets[0].metadata.bitDepth == 8)
            #expect(manifest.assets[0].role == .result)
            let output = fixture.directory.appendingPathComponent("作品.png")
            try await store.export(assetID: manifest.assets[0].id, to: output)
            #expect(try Data(contentsOf: output) == expectedBytes)
            await #expect(throws: ProjectStoreError.self) { try await store.export(assetID: manifest.assets[0].id, to: output) }
            #expect(try Data(contentsOf: output) == expectedBytes)
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot() == manifest)
            #expect(try Data(contentsOf: await reopened.assetURL(for: manifest.assets[0])) == expectedBytes)
            try await reopened.close()
        }
    }

    @Test func publicationGapIsRecoveredOnceWithoutClaimingCompletion() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "恢复")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            _ = try fixture.publishPNG(jobID: request.id)
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            let recovered = await reopened.snapshot()
            #expect(recovered.assets.count == 1)
            #expect(recovered.jobs[0].artifactIDs == recovered.assets.map(\.id))
            #expect(recovered.jobs[0].state == .interrupted)
            #expect(recovered.jobs[0].error?.contains("已恢复") == true)
            #expect(try await reopened.recoverPublishedArtifacts() == recovered)
            try await reopened.close()
        }
    }

    @Test(arguments: [JobState.cancelled, .failed])
    func cancelledOrFailedPublicationIsPreserved(state: JobState) async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "恢复取消")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            _ = try await store.updateJob(id: request.id, state: state)
            let image = try fixture.publishPNG(jobID: request.id)
            let recovered = try await store.recoverPublishedArtifacts()
            #expect(recovered.assets.count == 1)
            #expect(recovered.jobs[0].state == .interrupted)
            #expect(FileManager.default.fileExists(atPath: image.path))
            try await store.close()
        }
    }

    @Test func unrelatedAndPartialDirectoriesAreNotAdopted() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "限定恢复")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let unrelated = try fixture.publishPNG(jobID: UUID())
            let partial = fixture.project.appendingPathComponent("Tasks/\(request.id)-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
            try Data("partial".utf8).write(to: partial.appendingPathComponent(".image.partial"))
            let manifest = try await store.recoverPublishedArtifacts()
            #expect(manifest.assets.isEmpty)
            #expect(FileManager.default.fileExists(atPath: unrelated.path))
            #expect(manifest.jobs[0].state == .queued)
            try await store.close()
        }
    }

    @Test func corruptPNGAndWrongDimensionsNeverBecomeArtwork() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "检查图片")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let bad = try fixture.publishPNG(jobID: request.id)
            try Data([137, 80, 78, 71, 13, 10, 26, 10, 0]).write(to: bad)
            await #expect(throws: ProjectStoreError.self) {
                try await store.complete(id: request.id, result: .init(artifacts: [.init(url: bad, mediaType: "image/png")]))
            }
            #expect(await store.snapshot().assets.isEmpty)
            let wrong = try fixture.publishPNG(jobID: request.id, size: 4)
            await #expect(throws: ProjectStoreError.self) {
                try await store.complete(id: request.id, result: .init(artifacts: [.init(url: wrong, mediaType: "image/png")]))
            }
            let recovered = try await store.recoverPublishedArtifacts()
            #expect(recovered.assets.isEmpty)
            #expect(recovered.jobs[0].error?.contains("无法安全恢复") == true)
            #expect(FileManager.default.fileExists(atPath: bad.path))
            try await store.close()
        }
    }

    @Test func movedProjectRetainsArtWithoutModelDirectory() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "可移动")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let image = try fixture.publishPNG(jobID: request.id)
            let manifest = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            let original = try Data(contentsOf: image)
            try await store.close()
            let moved = fixture.directory.appendingPathComponent("Moved.dproject", isDirectory: true)
            try FileManager.default.moveItem(at: fixture.project, to: moved)
            let reopened = try await ProjectStore.open(at: moved)
            let resolved = try await reopened.assetURL(for: manifest.assets[0])
            #expect(resolved.path.hasPrefix(moved.path + "/"))
            #expect(try Data(contentsOf: resolved) == original)
            #expect(!FileManager.default.fileExists(atPath: request.model.directory.path))
            try await reopened.close()
        }
    }

    @Test func saveFailureKeepsPreviouslyDurableStateAndArtwork() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "保存失败")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let image = try fixture.publishPNG(jobID: request.id)
            let before = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            let original = try Data(contentsOf: image)
            let manifestURL = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            let manifestBytes = try Data(contentsOf: manifestURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.project.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.project.path) }
            await #expect(throws: ProjectStoreError.self) { try await store.enqueue(request: fixture.request()) }
            #expect(await store.snapshot() == before)
            #expect(try Data(contentsOf: manifestURL) == manifestBytes)
            #expect(try Data(contentsOf: image) == original)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.project.path)
            try await store.close()
        }
    }

    @Test func locationChangeFailsWithoutCreatingFallback() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "外盘")
            let before = await store.snapshot()
            let disconnected = fixture.directory.appendingPathComponent("disconnected.dproject")
            try FileManager.default.moveItem(at: fixture.project, to: disconnected)
            await #expect(throws: ProjectStoreError.self) { try await store.enqueue(request: fixture.request()) }
            await #expect(throws: ProjectStoreError.self) { try await store.close() }
            #expect(await store.snapshot() == before)
            #expect(!FileManager.default.fileExists(atPath: fixture.project.path))
            try FileManager.default.moveItem(at: disconnected, to: fixture.project)
            try await store.close()
        }
    }

    @Test func symlinkedTaskAndOutsideResultAreRejected() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "路径保护")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let actual = try fixture.publishPNG(jobID: request.id)
            let outside = fixture.directory.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: actual.deletingLastPathComponent(), to: outside)
            try FileManager.default.createSymbolicLink(at: actual.deletingLastPathComponent(), withDestinationURL: outside)
            await #expect(throws: ProjectStoreError.self) {
                try await store.complete(id: request.id, result: .init(artifacts: [.init(url: actual, mediaType: "image/png")]))
            }
            await #expect(throws: ProjectStoreError.self) {
                try await store.complete(id: request.id, result: .init(artifacts: [.init(url: outside.appendingPathComponent("image.png"), mediaType: "image/png")]))
            }
            #expect(try await store.recoverPublishedArtifacts().assets.isEmpty)
            #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("image.png").path))
            try await store.close()
        }
    }

    @Test func malformedManifestReferencesAndDuplicateIDsAreRejected() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "验证清单")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            var manifest = await store.snapshot()
            try await store.close()
            let manifestURL = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            manifest.jobs.append(manifest.jobs[0])
            try JSONEncoder().encode(manifest).write(to: manifestURL)
            await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.open(at: fixture.project) }
            manifest.jobs.removeLast()
            let asset = ProjectAsset(jobID: request.id, relativePath: "../outside.png")
            manifest.assets = [asset]
            manifest.jobs[0].artifactIDs = [asset.id]
            try JSONEncoder().encode(manifest).write(to: manifestURL)
            await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.open(at: fixture.project) }
        }
    }

    @Test func futureSchemaRejectedWithoutRewritingFile() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "未来格式")
            var manifest = await store.snapshot()
            try await store.close()
            manifest.schemaVersion = 999
            let bytes = try JSONEncoder().encode(manifest)
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            try bytes.write(to: file)
            await #expect(throws: ProjectStoreError.unsupportedSchema(999)) { _ = try await ProjectStore.open(at: fixture.project) }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func externallyEditedManifestIsPreservedAndFurtherWritesAreRefused() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "原始名称")
            let before = await store.snapshot()
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            let original = try Data(contentsOf: file)
            var external = before
            external.name = "其他程序修改的名称"
            let changedBytes = try JSONEncoder().encode(external)
            try changedBytes.write(to: file, options: .atomic)
            await #expect(throws: ProjectStoreError.self) { try await store.enqueue(request: fixture.request()) }
            await #expect(throws: ProjectStoreError.self) { try await store.flush() }
            #expect(await store.snapshot() == before)
            #expect(try Data(contentsOf: file) == changedBytes)
            // Restore the fixture explicitly so the normal close path can verify its snapshot.
            try original.write(to: file, options: .atomic)
            try await store.close()
        }
    }

    @Test func explicitConflictClosePreservesExternalBytesAndAllowsReopening() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "当前项目")
            var external = await store.snapshot()
            external.name = "保留外部修改"
            let bytes = try JSONEncoder().encode(external)
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            try bytes.write(to: file, options: .atomic)
            await #expect(throws: ProjectStoreError.externalModification) { try await store.close() }
            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.saveDraft(.init(prompt: "未写入的草稿"))
            }
            #expect(await store.snapshot().draft == .init())
            try await store.close(preserveExternalChanges: true)
            #expect(try Data(contentsOf: file) == bytes)
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().name == "保留外部修改")
            try await reopened.close()
        }
    }

    @Test func exclusiveSessionAndCreateNeverOverwrite() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "独占")
            let original = await store.snapshot()
            await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.create(at: fixture.project, name: "覆盖") }
            await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.open(at: fixture.project) }
            #expect(await store.snapshot() == original)
            try await store.close()
            await #expect(throws: ProjectStoreError.self) { try await store.enqueue(request: fixture.request()) }
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot() == original)
            try await reopened.close()
        }
    }

    @Test func unknownColorMetadataRemainsUnknown() throws {
        let metadata = MediaMetadata(width: 512, height: 512)
        let decoded = try JSONDecoder().decode(MediaMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(decoded.bitDepth == nil)
        #expect(decoded.colorSpace == nil)
    }

    @Test func manifestRevisionAdvancesOnlyForDurableChangesAndSurvivesReopening() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "修订顺序")
            #expect(await store.snapshot().revision == 0)
            let request = fixture.request()
            #expect(try await store.enqueue(request: request).revision == 1)
            #expect(try await store.updateJob(id: request.id, state: .preparing).revision == 2)
            // An idempotent update and a rejected update must not invent new committed versions.
            #expect(try await store.updateJob(id: request.id, state: .preparing).revision == 2)
            await #expect(throws: ProjectStoreError.self) { try await store.enqueue(request: request) }
            #expect(await store.snapshot().revision == 2)
            #expect(try await store.updateJob(id: request.id, state: .cancelled).revision == 3)
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot().revision == 3)
            try await reopened.close()
        }
    }

    @Test func originalAssetIdentityDoesNotRequireInventingAnInferenceJob() throws {
        let asset = ProjectAsset(relativePath: "Originals/camera.dng", mediaType: "image/x-adobe-dng", role: .original)
        let decoded = try JSONDecoder().decode(ProjectAsset.self, from: JSONEncoder().encode(asset))
        #expect(decoded.id == asset.id)
        #expect(decoded.jobID == nil)
        #expect(decoded.role == .original)
        #expect(decoded.metadata == .init())
    }

    @Test func projectAndExportDoNotRequireListingTheirAncestorDirectory() async throws {
        try await withFixture { fixture in
            try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: fixture.directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path) }
            let store = try await ProjectStore.create(at: fixture.project, name: "限定文件授权")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let image = try fixture.publishPNG(jobID: request.id)
            let manifest = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            let export = fixture.directory.appendingPathComponent("export.png")
            try await store.export(assetID: manifest.assets[0].id, to: export)
            #expect(try Data(contentsOf: export) == Data(contentsOf: image))
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            #expect(await reopened.snapshot() == manifest)
            try await reopened.close()
        }
    }

    @Test func openSessionRelocationPreservesIdentityRevisionAssetsAndExclusiveLock() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "正在打开的项目")
            let request = fixture.request()
            _ = try await store.enqueue(request: request)
            let image = try fixture.publishPNG(jobID: request.id)
            let bytes = try Data(contentsOf: image)
            let before = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: image, mediaType: "image/png")]))
            let moved = fixture.directory.appendingPathComponent("MovedWhileOpen.dproject", isDirectory: true)
            try FileManager.default.moveItem(at: fixture.project, to: moved)
            #expect(try await store.matchesLocation(moved))
            let relocated = try await store.relocated(to: moved)
            #expect(await relocated.snapshot() == before)
            #expect(try Data(contentsOf: await relocated.assetURL(for: before.assets[0])) == bytes)
            await #expect(throws: ProjectStoreError.self) { try await store.enqueue(request: fixture.request()) }
            await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.open(at: moved) }
            try await relocated.close()
            let reopened = try await ProjectStore.open(at: moved)
            #expect(await reopened.snapshot() == before)
            try await reopened.close()
        }
    }

    @Test func relocationRejectsCopiedIdentityAndSymbolicLinkWithoutClosingOriginal() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "原件")
            let copied = fixture.directory.appendingPathComponent("Copied.dproject", isDirectory: true)
            try FileManager.default.copyItem(at: fixture.project, to: copied)
            #expect(try await store.matchesLocation(copied) == false)
            await #expect(throws: ProjectStoreError.self) { _ = try await store.relocated(to: copied) }
            let alias = fixture.directory.appendingPathComponent("Alias.dproject", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.project)
            await #expect(throws: ProjectStoreError.self) { _ = try await store.relocated(to: alias) }
            try await store.flush()
            #expect(try await store.enqueue(request: fixture.request()).revision == 1)
            try await store.close()
        }
    }
}

struct ProjectFixture: Sendable {
    let directory: URL
    var project: URL { directory.appendingPathComponent("Test.dproject", isDirectory: true) }

    func request(seed: UInt64 = 42) -> InferenceRequest {
        .init(model: .init(directory: directory.appendingPathComponent("MissingSharedModel"), revision: "fixture-revision"),
              input: .image(.init(prompt: "A red teapot", width: 8, height: 8, steps: 4, guidanceScale: 1, seed: seed)))
    }

    func publishPNG(jobID: UUID, size: Int = 8) throws -> URL {
        let task = project.appendingPathComponent("Tasks/\(jobID)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: task, withIntermediateDirectories: false)
        let file = task.appendingPathComponent("image.png")
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                            bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }
}

func withFixture(_ body: @Sendable (ProjectFixture) async throws -> Void) async throws {
    let base = ProcessInfo.processInfo.environment["D_TEST_WORKBENCH_ROOT"]
        ?? ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("D-Workbench-Tests", isDirectory: true).path
    let directory = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = ProjectFixture(directory: directory.resolvingSymlinksInPath())
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(fixture)
}
