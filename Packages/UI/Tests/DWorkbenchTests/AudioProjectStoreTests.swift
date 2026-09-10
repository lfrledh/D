import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import DWorkbench

@Suite("Audio project ownership and persistence")
struct AudioProjectStoreTests {
    @Test func importOwnsExactBytesCreatesDistinctDocumentReopensAndExportsOriginal() async throws {
        try await withAudioProjectFixture { directory, project in
            let source = directory.appendingPathComponent("原声 source.wav")
            try AudioTestMedia.writePCM(to: source, samples: [[-1, -0.25, 0.5, 1]], sampleRate: 8_000,
                                        bitDepth: 16, floatingPoint: false)
            let original = try Data(contentsOf: source)
            let store = try await ProjectStore.create(at: project, name: "Audio")
            let imported = try await store.importAudio(at: source, name: "原声 e\u{301}")
            let audioDocument = try #require(imported.documents.last)
            let asset = try #require(imported.assets.last)
            #expect(audioDocument.kind == .audio)
            #expect(audioDocument.id != imported.documents[0].id)
            #expect(audioDocument.audioDraft?.id == audioDocument.id)
            #expect(audioDocument.audioDraft?.assetID == asset.id)
            #expect(asset.jobID == nil && asset.role == .original)
            #expect(asset.relativePath == "Audio/\(asset.id.uuidString)/source.wav")
            #expect(asset.metadata.audio?.contentSHA256 == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
            try FileManager.default.removeItem(at: source)
            let owned = try await store.assetURL(for: asset)
            #expect(try Data(contentsOf: owned) == original)
            let export = directory.appendingPathComponent("original.wav")
            try await store.export(assetID: asset.id, to: export)
            #expect(try Data(contentsOf: export) == original)
            let protected = Data("keep".utf8)
            let existing = directory.appendingPathComponent("existing.wav")
            try protected.write(to: existing)
            await #expect(throws: ProjectStoreError.self) { try await store.export(assetID: asset.id, to: existing) }
            #expect(try Data(contentsOf: existing) == protected)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            #expect(await reopened.snapshot() == imported)
            #expect(try Data(contentsOf: await reopened.assetURL(for: asset)) == original)
            try await reopened.close()
        }
    }

    @Test func pendingCapturePersistsAcrossReopenAndFinalizesOnlyExplicitly() async throws {
        try await withAudioProjectFixture { _, project in
            let store = try await ProjectStore.create(at: project, name: "Capture")
            let reservation = try await store.reserveAudioCapture(name: "现场录音")
            let capture = try await store.audioCaptureURL(id: reservation.id)
            #expect(await store.snapshot().pendingAudioCaptures == [reservation])
            try AudioTestMedia.writePCM(to: capture, samples: [[-0.5, 0, 0.5]], sampleRate: 8_000,
                                        bitDepth: 32, floatingPoint: true)
            try await store.close()

            let reopened = try await ProjectStore.open(at: project)
            #expect(await reopened.snapshot().pendingAudioCaptures == [reservation])
            #expect(await reopened.snapshot().assets.isEmpty)
            #expect(await reopened.snapshot().documents.filter { $0.kind == .audio }.isEmpty)
            let finalized = try await reopened.finalizeAudioCapture(id: reservation.id)
            #expect(finalized.pendingAudioCaptures.isEmpty)
            let asset = try #require(finalized.assets.first)
            #expect(asset.id == reservation.id)
            #expect(asset.relativePath == reservation.relativePath)
            #expect(asset.metadata.audio?.origin == .microphone)
            #expect(finalized.documents.last?.audioDraft?.assetID == reservation.id)
            #expect(FileManager.default.fileExists(atPath: capture.path))
            try await reopened.close()
        }
    }

    @Test func failedCaptureKeepsPersistedReservationAndRawBytesForRetry() async throws {
        try await withAudioProjectFixture { _, project in
            let store = try await ProjectStore.create(at: project, name: "Recovery")
            let reservation = try await store.reserveAudioCapture(name: "partial")
            let capture = try await store.audioCaptureURL(id: reservation.id)
            let raw = Data([0x63, 0x61, 0x66, 0x66, 0, 1]) + Data("partial".utf8)
            try raw.write(to: capture)
            await #expect(throws: AudioMediaError.self) { try await store.finalizeAudioCapture(id: reservation.id) }
            #expect(await store.snapshot().pendingAudioCaptures == [reservation])
            #expect(await store.snapshot().assets.isEmpty)
            #expect(try Data(contentsOf: capture) == raw)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            #expect(await reopened.snapshot().pendingAudioCaptures == [reservation])
            #expect(try Data(contentsOf: capture) == raw)
            try await reopened.close()
        }
    }

    @Test func draftIDsRangesUnicodeAndRevisionOverflowAreEnforcedByteExactly() async throws {
        try await withAudioProjectFixture { directory, project in
            let source = directory.appendingPathComponent("draft.wav")
            try AudioTestMedia.writePCM(to: source, samples: [[0, 0.25, 0.5, 0.75]], sampleRate: 8_000,
                                        bitDepth: 32, floatingPoint: true)
            let store = try await ProjectStore.create(at: project, name: "Draft")
            let imported = try await store.importAudio(at: source, name: "draft")
            let document = try #require(imported.documents.last)
            let assetID = try #require(document.audioDraft?.assetID)
            let clip = AudioClip(name: "e\u{301}", range: .init(startFrame: 1, endFrame: 3), note: "n\u{303}")
            let draft = AudioDraftDocument(id: document.id, revision: 1, assetID: assetID,
                                           clips: [clip], selectedClipID: clip.id, note: "a\u{30a}")
            let saved = try await store.saveAudioDraft(draft, documentID: document.id, expectedRevision: 0)
            #expect(saved.documents.last?.audioDraft == draft)
            var invalid = draft
            invalid.revision = 2
            invalid.clips[0].range = .init(startFrame: 3, endFrame: 5)
            await #expect(throws: AudioMediaError.self) {
                try await store.saveAudioDraft(invalid, documentID: document.id, expectedRevision: 1)
            }
            invalid = draft; invalid.revision = 2; invalid.assetID = UUID()
            await #expect(throws: ProjectStoreError.self) {
                try await store.saveAudioDraft(invalid, documentID: document.id, expectedRevision: 1)
            }

            let manifestFile = project.appendingPathComponent(ProjectStore.manifestFilename)
            let durableBytes = try Data(contentsOf: manifestFile)
            var externallyNormalized = saved
            externallyNormalized.documents[externallyNormalized.documents.count - 1].audioDraft?.clips[0].name = "é"
            try encodedManifest(externallyNormalized).write(to: manifestFile)
            var next = draft; next.revision = 2; next.note += "x"
            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.saveAudioDraft(next, documentID: document.id, expectedRevision: 1)
            }
            try durableBytes.write(to: manifestFile)
            try await store.close()

            var overflow = saved
            overflow.documents[overflow.documents.count - 1].audioDraft?.revision = UInt64.max
            try encodedManifest(overflow).write(to: manifestFile)
            let overflowStore = try await ProjectStore.open(at: project)
            let overflowDraft = try #require((await overflowStore.snapshot()).documents.last?.audioDraft)
            await #expect(throws: ProjectStoreError.self) {
                try await overflowStore.saveAudioDraft(overflowDraft, documentID: document.id,
                                                       expectedRevision: UInt64.max)
            }
            try await overflowStore.close()
        }
    }

    @Test func clipExportIsValidatedFloat32ExactRangeAndNeverOverwrites() async throws {
        try await withAudioProjectFixture { directory, project in
            let source = directory.appendingPathComponent("clip.caf")
            try AudioTestMedia.writePCM(to: source,
                samples: [[-1, -0.5, 0.25, 1], [0.75, 0.5, -0.25, -0.75]],
                sampleRate: 8_000, bitDepth: 24, floatingPoint: false)
            let store = try await ProjectStore.create(at: project, name: "Clip")
            let manifest = try await store.importAudio(at: source, name: "clip")
            let document = try #require(manifest.documents.last)
            let output = directory.appendingPathComponent("selected.wav")
            try await store.exportAudioClip(documentID: document.id,
                                            range: .init(startFrame: 1, endFrame: 3), to: output)
            let inspection = try AudioMediaInspector.inspect(at: output)
            #expect(inspection.format.container == .wav)
            #expect(inspection.format.floatingPoint && inspection.format.bitDepth == 32)
            #expect(inspection.format.sampleRate == 8_000)
            #expect(inspection.format.channelCount == 2)
            #expect(inspection.format.frameCount == 2)
            #expect(inspection.waveform.count == 2)
            let delivered = try Data(contentsOf: output)
            await #expect(throws: ProjectStoreError.self) {
                try await store.exportAudioClip(documentID: document.id,
                                                range: .init(startFrame: 0, endFrame: 1), to: output)
            }
            #expect(try Data(contentsOf: output) == delivered)
            let invalid = directory.appendingPathComponent("invalid.wav")
            await #expect(throws: AudioMediaError.self) {
                try await store.exportAudioClip(documentID: document.id,
                                                range: .init(startFrame: 2, endFrame: 5), to: invalid)
            }
            #expect(!FileManager.default.fileExists(atPath: invalid.path))
            try await store.close()
        }
    }

    @Test func unsafeSourcesAndCaptureCollisionDoNotRegisterOrOverwrite() async throws {
        try await withAudioProjectFixture { directory, project in
            let source = directory.appendingPathComponent("source.wav")
            try AudioTestMedia.writePCM(to: source, samples: [[0, 0.5]], sampleRate: 8_000,
                                        bitDepth: 32, floatingPoint: true)
            let store = try await ProjectStore.create(at: project, name: "Safety")
            let audioDirectory = project.appendingPathComponent("Audio")
            let before = try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)
            let alias = directory.appendingPathComponent("alias.wav")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
            await #expect(throws: AudioMediaError.self) { try await store.importAudio(at: alias, name: "alias") }
            let hardlink = directory.appendingPathComponent("hard.wav")
            try FileManager.default.linkItem(at: source, to: hardlink)
            await #expect(throws: AudioMediaError.self) { try await store.importAudio(at: source, name: "hard") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path) == before)
            #expect(await store.snapshot().assets.isEmpty)

            let reservation = try await store.reserveAudioCapture(name: "collision")
            let capture = project.appendingPathComponent(reservation.relativePath)
            let sentinel = Data("do-not-overwrite".utf8)
            try sentinel.write(to: capture)
            await #expect(throws: ProjectStoreError.self) { _ = try await store.audioCaptureURL(id: reservation.id) }
            #expect(try Data(contentsOf: capture) == sentinel)
            #expect(await store.snapshot().pendingAudioCaptures == [reservation])
            try await store.close()
        }
    }


    @Test func captureDirectorySymlinkCannotEscapeRetainedProjectRoot() async throws {
        try await withAudioProjectFixture { directory, project in
            let store = try await ProjectStore.create(at: project, name: "Symlink")
            let reservation = try await store.reserveAudioCapture(name: "capture")
            let target = try await store.audioCaptureURL(id: reservation.id)
            let captureDirectory = target.deletingLastPathComponent()
            let savedDirectory = directory.appendingPathComponent("saved-reservation")
            try FileManager.default.moveItem(at: captureDirectory, to: savedDirectory)
            let outside = directory.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let sentinel = Data("protected".utf8)
            try sentinel.write(to: outside.appendingPathComponent("source.caf"))
            try FileManager.default.createSymbolicLink(at: captureDirectory, withDestinationURL: outside)
            await #expect(throws: (any Error).self) { _ = try await store.audioCaptureURL(id: reservation.id) }
            #expect(try Data(contentsOf: outside.appendingPathComponent("source.caf")) == sentinel)
            #expect(await store.snapshot().pendingAudioCaptures == [reservation])
            try await store.close()
        }
    }

    @Test(arguments: [2, 3])
    func schemaTwoAndThreeMigrationKeepExactBackupsAndDefaultNewFields(version: Int) async throws {
        try await withAudioProjectFixture { _, project in
            let store = try await ProjectStore.create(at: project, name: "Legacy")
            let current = await store.snapshot()
            try await store.close()
            let original = try legacyManifest(current, schemaVersion: version)
            let file = project.appendingPathComponent(ProjectStore.manifestFilename)
            try original.write(to: file)
            let reopened = try await ProjectStore.open(at: project)
            let migrated = await reopened.snapshot()
            #expect(migrated.schemaVersion == 4)
            #expect(migrated.pendingAudioCaptures.isEmpty)
            #expect(migrated.documents[0].audioDraft == nil)
            let backupName = version == 2 ? ProjectStore.versionTwoBackupFilename : ProjectStore.versionThreeBackupFilename
            #expect(try Data(contentsOf: project.appendingPathComponent(backupName)) == original)
            try await reopened.close()
        }
    }

    @Test func conflictingSchemaThreeBackupAndFutureSchemaNeverRewriteManifest() async throws {
        try await withAudioProjectFixture { _, project in
            let store = try await ProjectStore.create(at: project, name: "Conflicts")
            let current = await store.snapshot()
            try await store.close()
            let file = project.appendingPathComponent(ProjectStore.manifestFilename)
            let legacy = try legacyManifest(current, schemaVersion: 3)
            try legacy.write(to: file)
            let conflict = Data("different backup".utf8)
            let backup = project.appendingPathComponent(ProjectStore.versionThreeBackupFilename)
            try conflict.write(to: backup)
            await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.open(at: project) }
            #expect(try Data(contentsOf: file) == legacy)
            #expect(try Data(contentsOf: backup) == conflict)

            var future = current; future.schemaVersion = 999
            let futureBytes = try encodedManifest(future)
            try futureBytes.write(to: file)
            await #expect(throws: ProjectStoreError.unsupportedSchema(999)) {
                _ = try await ProjectStore.open(at: project)
            }
            #expect(try Data(contentsOf: file) == futureBytes)
        }
    }

    @Test func manifestRejectsCrossModalImageReferenceAndReservationAssetIDCollision() async throws {
        try await withAudioProjectFixture { directory, project in
            let source = directory.appendingPathComponent("modal.wav")
            try AudioTestMedia.writePCM(to: source, samples: [[0, 0.5]], sampleRate: 8_000,
                                        bitDepth: 32, floatingPoint: true)
            let store = try await ProjectStore.create(at: project, name: "Modal")
            var manifest = try await store.importAudio(at: source, name: "audio")
            try await store.close()
            let file = project.appendingPathComponent(ProjectStore.manifestFilename)
            let audioAsset = try #require(manifest.assets.first)
            manifest.documents[0].sourceAssetID = audioAsset.id
            try encodedManifest(manifest).write(to: file)
            await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.open(at: project) }

            manifest.documents[0].sourceAssetID = nil
            manifest.pendingAudioCaptures = [.init(id: audioAsset.id,
                relativePath: "Audio/\(audioAsset.id.uuidString)/source.caf", name: "collision")]
            try encodedManifest(manifest).write(to: file)
            await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.open(at: project) }
        }
    }

    @Test func changedRegisteredOriginalCannotBeExportedAndTargetStaysAbsent() async throws {
        try await withAudioProjectFixture { directory, project in
            let source = directory.appendingPathComponent("registered.wav")
            try AudioTestMedia.writePCM(to: source, samples: [[0, 0.25]], sampleRate: 8_000,
                                        bitDepth: 32, floatingPoint: true)
            let store = try await ProjectStore.create(at: project, name: "Identity")
            let manifest = try await store.importAudio(at: source, name: "registered")
            let asset = try #require(manifest.assets.first)
            let owned = try await store.assetURL(for: asset)
            try AudioTestMedia.writePCM(to: owned, samples: [[0.5, 0.75]], sampleRate: 8_000,
                                        bitDepth: 32, floatingPoint: true)
            let output = directory.appendingPathComponent("must-not-exist.wav")
            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.export(assetID: asset.id, to: output)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            try await store.close()
        }
    }
}

private func encodedManifest(_ manifest: ProjectManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(manifest)
}

private func legacyManifest(_ manifest: ProjectManifest, schemaVersion: Int) throws -> Data {
    var json = try #require(JSONSerialization.jsonObject(with: encodedManifest(manifest)) as? [String: Any])
    json["schemaVersion"] = schemaVersion
    json.removeValue(forKey: "pendingAudioCaptures")
    var documents = try #require(json["documents"] as? [[String: Any]])
    for index in documents.indices {
        documents[index].removeValue(forKey: "audioDraft")
        if schemaVersion == 2 { documents[index].removeValue(forKey: "kind") }
    }
    json["documents"] = documents
    var assets = try #require(json["assets"] as? [[String: Any]])
    for index in assets.indices {
        if var metadata = assets[index]["metadata"] as? [String: Any] {
            metadata.removeValue(forKey: "audio")
            assets[index]["metadata"] = metadata
        }
    }
    json["assets"] = assets
    return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
}

private func withAudioProjectFixture(
    _ body: @Sendable (URL, URL) async throws -> Void
) async throws {
    let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
        ?? ProcessInfo.processInfo.environment["D_TEST_WORKBENCH_ROOT"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("D-Workbench-Audio-Store-Tests").path
    let directory = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.resolvingSymlinksInPath(),
                   directory.resolvingSymlinksInPath().appendingPathComponent("Audio.dproject", isDirectory: true))
}
