import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Audio creation persistence and safety", .serialized)
struct AudioCreationStoreTests {
    @Test func requestBuilderParsesOnlyOperativeFieldsWithoutClamping() throws {
        let source = AudioSourceReference(url: URL(fileURLWithPath: "/frozen/source.wav"),
            sha256: String(repeating: "a", count: 64), frameCount: 44_100,
            sampleRate: 44_100, channels: 2)
        var generate = AudioCreationDraft(prompt: "  rain  ", operation: .generate,
            durationText: "1.25", seedText: "4294967294", stepsText: "100",
            guidanceText: "15", strengthText: "unfinished")
        let generated = try generate.makeRequest(source: nil)
        #expect(generated.durationSeconds == 1.25 && generated.diffusion?.strength == 1)
        #expect(generated.seed == UInt64(UInt32.max) - 1)

        var variation = AudioCreationDraft(prompt: "variation", operation: .variation,
            durationText: "unfinished", seedText: "0", stepsText: "1",
            guidanceText: "1", strengthText: "0.25")
        let varied = try variation.makeRequest(source: source)
        #expect(varied.durationSeconds == 1 && varied.diffusion?.strength == 0.25)
        variation.strengthText = "nan"
        #expect(throws: InferenceFailure.self) { try variation.makeRequest(source: source) }

        generate.durationText = "nan"
        #expect(throws: InferenceFailure.self) { try generate.makeRequest(source: nil) }
        generate.durationText = "1"; generate.prompt = " \n "
        #expect(throws: InferenceFailure.self) { try generate.makeRequest(source: nil) }
        generate.prompt = "x"
        #expect(throws: InferenceFailure.self) { try generate.makeRequest(source: source) }
    }

    @Test(arguments: [1, 2, 3, 4])
    func everyLegacySchemaKeepsExactBackup(version: Int) async throws {
        try await withCreationFixture { root, project in
            let source = root.appendingPathComponent("legacy.wav")
            try tinyWAV(source)
            let mediaBytes = try Data(contentsOf: source)
            let store = try await ProjectStore.create(at: project, name: "legacy")
            let imported = try await store.importAudio(at: source, name: "legacy audio")
            let asset = try #require(imported.assets.first)
            try await store.close()
            let manifestURL = project.appendingPathComponent(ProjectStore.manifestFilename)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            object["schemaVersion"] = version
            if version == 1 { object.removeValue(forKey: "documents"); object.removeValue(forKey: "activeDocumentID") }
            let legacy = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try legacy.write(to: manifestURL)
            let reopened = try await ProjectStore.open(at: project)
            #expect(await reopened.snapshot().schemaVersion == 5)
            let names = [ProjectStore.versionOneBackupFilename, ProjectStore.versionTwoBackupFilename,
                         ProjectStore.versionThreeBackupFilename, ProjectStore.versionFourBackupFilename]
            #expect(try Data(contentsOf: project.appendingPathComponent(names[version - 1])) == legacy)
            #expect(try Data(contentsOf: project.appendingPathComponent(asset.relativePath)) == mediaBytes)
            try await reopened.close()
        }
    }

    @Test func emptyDraftRevisionAndFrozenSourceAreDurableAndCollisionSafe() async throws {
        try await withCreationFixture { root, project in
            let source = root.appendingPathComponent("outside.wav")
            try tinyWAV(source)
            let original = try Data(contentsOf: source)
            let store = try await ProjectStore.create(at: project, name: "source")
            let imported = try await store.importAudio(at: source, name: "source")
            let asset = try #require(imported.assets.first)
            let created = try await store.createAudioCreation(sourceAssetID: asset.id)
            let document = try #require(created.activeDocument)
            let empty = try #require(document.audioCreation)
            #expect(empty.prompt.isEmpty && empty.operation == .variation)
            #expect(document.audioDraft == nil && document.adoptedAssetID == nil)

            var unchangedRevision = empty; unchangedRevision.prompt = "changed"
            await #expect(throws: ProjectStoreError.self) {
                try await store.saveAudioCreation(unchangedRevision, documentID: document.id,
                                                  expectedRevision: empty.revision)
            }
            var draft = empty
            draft.revision = UUID(); draft.prompt = "e\u{301}"; draft.durationText = "unfinished"
            draft.strengthText = "0.5"
            let saved = try await store.saveAudioCreation(draft, documentID: document.id,
                                                          expectedRevision: empty.revision)
            #expect(saved.activeDocument?.audioCreation?.prompt.utf8.elementsEqual("e\u{301}".utf8) == true)
            var illegalDecision = draft
            illegalDecision.revision = UUID(); illegalDecision.rejectedAssetIDs = [UUID()]
            await #expect(throws: ProjectStoreError.self) {
                try await store.saveAudioCreation(illegalDecision, documentID: document.id,
                                                  expectedRevision: draft.revision)
            }
            _ = try await store.setSelectedAsset(asset.id, documentID: document.id)
            await #expect(throws: ProjectStoreError.self) {
                try await store.adoptAsset(id: asset.id, documentID: document.id)
            }

            let manifestURL = project.appendingPathComponent(ProjectStore.manifestFilename)
            let durable = try Data(contentsOf: manifestURL)
            try Data("external change".utf8).write(to: manifestURL)
            var later = draft; later.revision = UUID(); later.prompt += "x"
            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.saveAudioCreation(later, documentID: document.id,
                                                  expectedRevision: draft.revision)
            }
            try durable.write(to: manifestURL)

            let runID = UUID()
            let frozen = try await store.prepareAudioCreationSource(assetID: asset.id, runID: runID)
            #expect(frozen.url.path.contains("/AudioInputs/\(runID.uuidString)/source.wav"))
            #expect(!frozen.url.path.contains("/Tasks/"))
            #expect(try Data(contentsOf: frozen.url) == original)
            await #expect(throws: ProjectStoreError.self) {
                try await store.prepareAudioCreationSource(assetID: asset.id, runID: runID)
            }
            #expect(try Data(contentsOf: frozen.url) == original)
            let escapedRun = UUID()
            let outside = root.appendingPathComponent("protected")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let sentinel = outside.appendingPathComponent("source.wav")
            try Data("keep".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(
                at: project.appendingPathComponent("AudioInputs/\(escapedRun.uuidString)"),
                withDestinationURL: outside)
            await #expect(throws: ProjectStoreError.self) {
                try await store.prepareAudioCreationSource(assetID: asset.id, runID: escapedRun)
            }
            #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
            try FileManager.default.removeItem(at: await store.assetURL(for: asset))
            let audio = try draft.makeRequest(source: frozen)
            let request = InferenceRequest(id: runID,
                model: .init(directory: URL(fileURLWithPath: "/fixture-model")), input: .audio(audio))
            let badSource = AudioSourceReference(url: frozen.url,
                sha256: String(repeating: "0", count: 64), frameCount: frozen.frameCount,
                sampleRate: frozen.sampleRate, channels: frozen.channels)
            let badRequest = InferenceRequest(id: runID,
                model: request.model, input: .audio(try draft.makeRequest(source: badSource)))
            await #expect(throws: ProjectStoreError.self) {
                try await store.enqueue(request: badRequest, documentID: document.id)
            }
            await #expect(throws: ProjectStoreError.self) {
                try await store.enqueue(request: request, documentID: created.documents[0].id)
            }
            let queued = try await store.enqueue(request: request, documentID: document.id)
            #expect(queued.jobs.last?.request == request)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            #expect((await reopened.snapshot()).activeDocument?.audioCreation?.prompt == draft.prompt)
            #expect(try Data(contentsOf: frozen.url) == original)
            try await reopened.close()
        }
    }

    @Test func authoritativeCompletionDecisionsExportAndReopenPreserveTruth() async throws {
        try await withCreationFixture { root, project in
            let store = try await ProjectStore.create(at: project, name: "result")
            let created = try await store.createAudioCreation()
            let document = try #require(created.activeDocument)
            var draft = try #require(document.audioCreation)
            draft.revision = UUID(); draft.prompt = "fixture generation"
            draft.durationText = String(Double(4) / 44_100); draft.strengthText = "hidden-invalid"
            _ = try await store.saveAudioCreation(draft, documentID: document.id,
                                                  expectedRevision: created.activeDocument!.audioCreation!.revision)
            let audio = try draft.makeRequest(source: nil)
            let runID = UUID()
            let request = InferenceRequest(id: runID,
                model: .init(directory: URL(fileURLWithPath: "/fixture-model")), input: .audio(audio))
            _ = try await store.enqueue(request: request, documentID: document.id)
            let output = try publishedOutput(project: project, runID: runID)
            try tinyWAV(output)
            let bytes = try Data(contentsOf: output)
            let completed = try await store.complete(id: runID, result: .init(
                artifacts: [.init(url: output, mediaType: "audio/wav")],
                metadata: ["profile": "CPU fixture only", "precision": "float fixture"]))
            let asset = try #require(completed.assets.last)
            #expect(asset.metadata.audio?.origin == .modelGenerated)
            #expect(asset.role == .result && asset.jobID == runID)
            #expect(completed.jobs.last?.resultMetadata["precision"] == "float fixture")
            #expect(completed.jobs.last?.request == request)
            #expect(completed.activeDocument?.selectedAssetID == nil)
            #expect(completed.activeDocument?.adoptedAssetID == nil)

            let next = try await store.createAudioCreation(name: "next", sourceAssetID: asset.id)
            let nextDocument = try #require(next.activeDocument)
            let nextRun = UUID()
            let nextSource = try await store.prepareAudioCreationSource(assetID: asset.id, runID: nextRun)
            #expect(!nextSource.url.path.contains("/Tasks/"))
            #expect(try Data(contentsOf: nextSource.url) == bytes)
            _ = try await store.selectDocument(id: document.id)

            _ = try await store.setSelectedAsset(asset.id, documentID: document.id)
            #expect((await store.snapshot()).activeDocument?.adoptedAssetID == nil)
            _ = try await store.adoptAsset(id: asset.id, documentID: document.id)
            let rejected = try await store.setAudioCandidateRejected(id: asset.id, rejected: true,
                                                                     documentID: document.id)
            #expect(rejected.activeDocument?.selectedAssetID == nil)
            #expect(rejected.activeDocument?.adoptedAssetID == nil)
            #expect(rejected.activeDocument?.audioCreation?.rejectedAssetIDs == [asset.id])
            _ = try await store.setAudioCandidateRejected(id: asset.id, rejected: false,
                                                          documentID: document.id)
            #expect((await store.snapshot()).activeDocument?.selectedAssetID == nil)
            _ = try await store.adoptAsset(id: asset.id, documentID: document.id)
            _ = try await store.adoptAsset(id: nil, documentID: document.id)

            let inspection = try await store.inspectAudioAsset(id: asset.id)
            #expect(inspection.format.frameCount == 4)
            let export = root.appendingPathComponent("result.wav")
            try await store.exportAudioAsset(id: asset.id, to: export)
            #expect(try Data(contentsOf: export) == bytes)
            await #expect(throws: ProjectStoreError.self) {
                try await store.exportAudioAsset(id: asset.id, to: export)
            }
            let changed = root.appendingPathComponent("changed.wav")
            await #expect(throws: (any Error).self) {
                try await store.exportAudioAsset(id: asset.id, to: changed, checkpoint: { point in
                    if case .contentDurable(let temporary) = point {
                        try Data("corrupt".utf8).write(to: temporary)
                    }
                })
            }
            #expect(!FileManager.default.fileExists(atPath: changed.path))
            #expect(try Data(contentsOf: output) == bytes)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            #expect((await reopened.snapshot()).activeDocument?.adoptedAssetID == nil)
            #expect((await reopened.snapshot()).documents.contains(where: { $0.id == nextDocument.id }))
            #expect(try await reopened.inspectAudioAsset(id: asset.id).contentSHA256 == inspection.contentSHA256)
            try await reopened.close()
        }
    }

    @Test(arguments: [JobState.queued, .cancelled, .failed])
    func recoveredOutputNeverFabricatesSuccessfulAdoption(requestedState: JobState) async throws {
        try await withCreationFixture { _, project in
            let store = try await ProjectStore.create(at: project, name: "recover")
            let created = try await store.createAudioCreation()
            let document = try #require(created.activeDocument)
            var draft = try #require(document.audioCreation)
            draft.revision = UUID(); draft.prompt = "recover"; draft.durationText = String(Double(4) / 44_100)
            _ = try await store.saveAudioCreation(draft, documentID: document.id,
                                                  expectedRevision: created.activeDocument!.audioCreation!.revision)
            let runID = UUID()
            let request = InferenceRequest(id: runID,
                model: .init(directory: URL(fileURLWithPath: "/fixture-model")),
                input: .audio(try draft.makeRequest(source: nil)))
            _ = try await store.enqueue(request: request, documentID: document.id)
            if requestedState != .queued {
                _ = try await store.updateJob(id: runID, state: requestedState,
                                              error: "fixture terminal state")
            }
            let output = try publishedOutput(project: project, runID: runID)
            try tinyWAV(output)
            let outputBytes = try Data(contentsOf: output)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            let recovered = await reopened.snapshot()
            let job = try #require(recovered.jobs.first(where: { $0.id == runID }))
            let expectedState: JobState = requestedState == .queued ? .interrupted : requestedState
            #expect(job.state == expectedState)
            let asset = try #require(recovered.assets.first(where: { $0.jobID == runID }))
            #expect(job.artifactIDs == [asset.id])
            #expect(try Data(contentsOf: output) == outputBytes)
            await #expect(throws: ProjectStoreError.self) {
                try await reopened.adoptAsset(id: asset.id, documentID: document.id)
            }
            #expect((await reopened.snapshot()).activeDocument?.adoptedAssetID == nil)
            try await reopened.close()
        }
    }

    @Test func corruptNumericMetadataAndUnrepresentableDurationReturnErrors() async throws {
        try await withCreationFixture { root, project in
            let source = root.appendingPathComponent("metadata.wav")
            try tinyWAV(source)
            let store = try await ProjectStore.create(at: project, name: "metadata")
            let imported = try await store.importAudio(at: source, name: "source")
            let asset = try #require(imported.assets.first)
            let created = try await store.createAudioCreation(sourceAssetID: asset.id)
            let document = try #require(created.activeDocument)
            var draft = try #require(document.audioCreation)
            draft.revision = UUID(); draft.prompt = "variation"; draft.durationText = "hidden"
            _ = try await store.saveAudioCreation(draft, documentID: document.id,
                                                  expectedRevision: created.activeDocument!.audioCreation!.revision)
            let runID = UUID()
            let frozen = try await store.prepareAudioCreationSource(assetID: asset.id, runID: runID)
            let request = InferenceRequest(id: runID,
                model: .init(directory: URL(fileURLWithPath: "/fixture-model")),
                input: .audio(try draft.makeRequest(source: frozen)))
            _ = try await store.enqueue(request: request, documentID: document.id)
            try await store.close()

            let manifestURL = project.appendingPathComponent(ProjectStore.manifestFilename)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            var assets = try #require(object["assets"] as? [[String: Any]])
            var metadata = try #require(assets[0]["metadata"] as? [String: Any])
            var audio = try #require(metadata["audio"] as? [String: Any])
            var format = try #require(audio["format"] as? [String: Any])
            format["sampleRate"] = 1e100
            audio["format"] = format; metadata["audio"] = audio; assets[0]["metadata"] = metadata
            object["assets"] = assets
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: manifestURL)
            await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.open(at: project) }

            let hugeProject = root.appendingPathComponent("Huge.dproject", isDirectory: true)
            let hugeStore = try await ProjectStore.create(at: hugeProject, name: "huge")
            let hugeCreated = try await hugeStore.createAudioCreation()
            let hugeDocument = try #require(hugeCreated.activeDocument)
            var hugeDraft = try #require(hugeDocument.audioCreation)
            hugeDraft.revision = UUID(); hugeDraft.prompt = "huge"
            hugeDraft.durationText = String(Double(Int64.max) / 44_100)
            _ = try await hugeStore.saveAudioCreation(hugeDraft, documentID: hugeDocument.id,
                expectedRevision: hugeCreated.activeDocument!.audioCreation!.revision)
            let hugeID = UUID()
            let hugeRequest = InferenceRequest(id: hugeID,
                model: .init(directory: URL(fileURLWithPath: "/fixture-model")),
                input: .audio(try hugeDraft.makeRequest(source: nil)))
            _ = try await hugeStore.enqueue(request: hugeRequest, documentID: hugeDocument.id)
            let output = try publishedOutput(project: hugeProject, runID: hugeID)
            try tinyWAV(output)
            let outputBytes = try Data(contentsOf: output)
            await #expect(throws: ProjectStoreError.self) {
                try await hugeStore.complete(id: hugeID,
                    result: .init(artifacts: [.init(url: output, mediaType: "audio/wav")]))
            }
            #expect((await hugeStore.snapshot()).assets.isEmpty)
            #expect(try Data(contentsOf: output) == outputBytes)
            try await hugeStore.close()
        }
    }

    @Test func audioCompleteExternalManifestChangePreservesManifestOutputAndMemoryState() async throws {
        try await withCreationFixture { _, project in
            let store = try await ProjectStore.create(at: project, name: "complete conflict")
            let created = try await store.createAudioCreation()
            let document = try #require(created.activeDocument)
            var draft = try #require(document.audioCreation)
            let oldRevision = draft.revision
            draft.revision = UUID(); draft.prompt = "fixed request"
            draft.durationText = String(Double(4) / 44_100)
            _ = try await store.saveAudioCreation(draft, documentID: document.id,
                                                  expectedRevision: oldRevision)
            let runID = UUID()
            let request = InferenceRequest(id: runID,
                model: .init(directory: URL(fileURLWithPath: "/fixture-model")),
                input: .audio(try draft.makeRequest(source: nil)))
            _ = try await store.enqueue(request: request, documentID: document.id)
            let before = await store.snapshot()
            let output = try publishedOutput(project: project, runID: runID)
            try tinyWAV(output)
            let outputBytes = try Data(contentsOf: output)

            let manifestURL = project.appendingPathComponent(ProjectStore.manifestFilename)
            let ownedManifestBytes = try Data(contentsOf: manifestURL)
            var object = try #require(JSONSerialization.jsonObject(with: ownedManifestBytes) as? [String: Any])
            object["name"] = "external writer content"
            let externalBytes = try JSONSerialization.data(withJSONObject: object,
                                                            options: [.prettyPrinted, .sortedKeys])
            try externalBytes.write(to: manifestURL)
            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.complete(id: runID, result: .init(
                    artifacts: [.init(url: output, mediaType: "audio/wav")],
                    metadata: ["profile": "CPU fixture only"]))
            }
            #expect(try Data(contentsOf: manifestURL) == externalBytes)
            #expect(try Data(contentsOf: output) == outputBytes)
            let after = await store.snapshot()
            #expect(after == before)
            #expect(after.assets.isEmpty)
            #expect(after.jobs.first(where: { $0.id == runID })?.state == .queued)

            // Restore only this fixture's deliberate external edit so normal close can verify it.
            try ownedManifestBytes.write(to: manifestURL)
            #expect(try Data(contentsOf: manifestURL) == ownedManifestBytes)
            try await store.close()
        }
    }

    @Test func malformedPublishedResultsRemainErrorsAndBytesArePreserved() async throws {
        try await withCreationFixture { _, project in
            let store = try await ProjectStore.create(at: project, name: "malformed")

            func enqueue(frames: Int64) async throws -> (UUID, UUID) {
                let created = try await store.createAudioCreation()
                let document = try #require(created.activeDocument)
                var draft = try #require(document.audioCreation)
                let oldRevision = draft.revision
                draft.revision = UUID(); draft.prompt = "fixture"
                draft.durationText = String(Double(frames) / 44_100)
                _ = try await store.saveAudioCreation(draft, documentID: document.id,
                                                      expectedRevision: oldRevision)
                let runID = UUID()
                let request = InferenceRequest(id: runID,
                    model: .init(directory: URL(fileURLWithPath: "/fixture-model")),
                    input: .audio(try draft.makeRequest(source: nil)))
                _ = try await store.enqueue(request: request, documentID: document.id)
                return (document.id, runID)
            }

            let (_, wrongPathID) = try await enqueue(frames: 4)
            let wrongPath = project.appendingPathComponent(
                "Tasks/\(wrongPathID.uuidString.lowercased())-AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA/job/output.wav")
            try tinyWAV(wrongPath)
            let wrongPathBytes = try Data(contentsOf: wrongPath)
            await #expect(throws: ProjectStoreError.self) {
                try await store.complete(id: wrongPathID,
                    result: .init(artifacts: [.init(url: wrongPath, mediaType: "audio/wav")]))
            }
            #expect(try Data(contentsOf: wrongPath) == wrongPathBytes)

            let (_, framesID) = try await enqueue(frames: 5)
            let wrongFrames = try publishedOutput(project: project, runID: framesID)
            try tinyWAV(wrongFrames)
            let wrongFrameBytes = try Data(contentsOf: wrongFrames)
            await #expect(throws: AudioMediaError.self) {
                try await store.complete(id: framesID,
                    result: .init(artifacts: [.init(url: wrongFrames, mediaType: "audio/wav")]))
            }
            #expect(try Data(contentsOf: wrongFrames) == wrongFrameBytes)

            let (_, nanID) = try await enqueue(frames: 1)
            let nan = try publishedOutput(project: project, runID: nanID)
            try AudioTestMedia.writeMinimalWAV(to: nan, formatTag: 3, sampleRate: 44_100,
                channels: 2, bits: 32,
                samples: AudioTestMedia.floatBytes([.nan, .nan]))
            let nanBytes = try Data(contentsOf: nan)
            await #expect(throws: AudioMediaError.self) {
                try await store.complete(id: nanID,
                    result: .init(artifacts: [.init(url: nan, mediaType: "audio/wav")]))
            }
            #expect(try Data(contentsOf: nan) == nanBytes)
            #expect((await store.snapshot()).assets.isEmpty)
            try await store.close()
        }
    }

    private func tinyWAV(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AudioTestMedia.writePCM(to: url, samples: [[0, 0.25, -0.25, 0], [0, -0.25, 0.25, 0]],
                                    sampleRate: 44_100, bitDepth: 32, floatingPoint: true)
    }

    private func publishedOutput(project: URL, runID: UUID) throws -> URL {
        let directory = "\(runID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        let output = project.appendingPathComponent("Tasks/\(directory)/job/output.wav")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        return output
    }
}

private func withCreationFixture(
    _ body: @Sendable (URL, URL) async throws -> Void
) async throws {
    guard let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] else {
        throw AudioMediaError.unavailable("D_TEST_TEMP_DIR is required")
    }
    let root = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent("audio-creation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root, root.appendingPathComponent("Creation.dproject", isDirectory: true))
}
