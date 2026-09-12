import DInference
import Foundation
import Darwin
import Testing
@testable import DWorkbench

@Suite("MRT2 music persistence", .serialized)
struct MusicCreationStoreTests {
    @Test(arguments: [false, true]) func projectLockDoesNotOutliveItsOwnerInAChildProcess(relocated: Bool) async throws {
        try await fixture { _, project in
            let original = try await ProjectStore.create(at: project, name: "lock ownership")
            let store = relocated ? try await original.relocated(to: project) : original
            var child: pid_t = 0
            let executable = strdup("/bin/sleep")!, duration = strdup("1")!
            defer { free(executable); free(duration) }
            var arguments: [UnsafeMutablePointer<CChar>?] = [executable, duration, nil]
            let code = arguments.withUnsafeMutableBufferPointer {
                posix_spawn(&child, executable, nil, nil, $0.baseAddress!, environ)
            }
            #expect(code == 0)
            guard code == 0 else { try await store.close(); return }
            defer {
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            }
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            try await reopened.close()
        }
    }

    @Test func conditionsCandidateDecisionsAndExportSurviveReopen() async throws {
        try await fixture { root, project in
            let store = try await ProjectStore.create(at: project, name: "旋律 🎹")
            let created = try await store.createAudioCreation()
            let document = try #require(created.activeDocument)
            var draft = try #require(document.audioCreation)
            let prior = draft.revision
            draft.revision = UUID(); draft.profile = .conditionedMusic
            draft.prompt = "piano"; draft.durationText = "0.08"; draft.seedText = "4294967295"
            draft.music = .init(notes: [.init(pitchText: "C4", startText: "0", durationText: "0.04")], hasNoteCondition: true)
            _ = try await store.saveAudioCreation(draft, documentID: document.id, expectedRevision: prior)
            let audio = try draft.makeRequest(source: nil)
            let request = InferenceRequest(model: .init(directory: URL(fileURLWithPath: "/fixture-mrt2")), input: .audio(audio))
            _ = try await store.enqueue(request: request, documentID: document.id)
            let directory = project.appendingPathComponent("Tasks/\(request.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())/job")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent("output.wav")
            let samples = [Float](repeating: 0.25, count: 3_840)
            try AudioTestMedia.writePCM(to: output, samples: [samples,samples], sampleRate: 48_000, bitDepth: 32, floatingPoint: true)
            let original = try Data(contentsOf: output)
            let completed = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: output, mediaType: "audio/wav")]))
            let asset = try #require(completed.assets.last)
            #expect(completed.activeDocument?.adoptedAssetID == nil)
            #expect(asset.metadata.audio?.format.sampleRate == 48_000)
            _ = try await store.adoptAsset(id: asset.id, documentID: document.id)
            _ = try await store.setAudioCandidateRejected(id: asset.id, rejected: true, documentID: document.id)
            #expect((await store.snapshot()).activeDocument?.adoptedAssetID == nil)
            _ = try await store.setAudioCandidateRejected(id: asset.id, rejected: false, documentID: document.id)
            _ = try await store.adoptAsset(id: asset.id, documentID: document.id)
            let exported = root.appendingPathComponent("作品 🎹.wav")
            try await store.exportAudioAsset(id: asset.id, to: exported)
            await #expect(throws: ProjectStoreError.self) { try await store.exportAudioAsset(id: asset.id, to: exported) }
            #expect(try Data(contentsOf: exported) == original)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            let snapshot = await reopened.snapshot()
            #expect(snapshot.activeDocument?.audioCreation?.music == draft.music)
            #expect(snapshot.activeDocument?.audioCreation?.profile == .conditionedMusic)
            #expect(snapshot.jobs.last?.request == request)
            #expect(snapshot.activeDocument?.adoptedAssetID == asset.id)
            #expect(try Data(contentsOf: output) == original)
            try await reopened.close()
        }
    }

    @Test func invalidDraftIsPreservedAndConditionFileNeverOverwrites() async throws {
        try await fixture { root, project in
            let store = try await ProjectStore.create(at: project, name: "草稿")
            let created = try await store.createAudioCreation()
            let document = try #require(created.activeDocument)
            var draft = try #require(document.audioCreation);let previous=draft.revision
            draft.revision=UUID();draft.profile = .conditionedMusic;draft.music = .example
            draft.music?.notes[0].pitchText = "未完成 e\u{301} 🎹"
            _ = try await store.saveAudioCreation(draft, documentID: document.id, expectedRevision: previous)
            #expect(throws: (any Error).self) { try draft.makeRequest(source: nil) }
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            #expect((await reopened.snapshot()).activeDocument?.audioCreation == draft)
            try await reopened.close()
            let data = try MusicConditionFile.encode(.example, durationText: "4")
            let destination = root.appendingPathComponent("和弦.json")
            try ProjectStore.publishMusicCondition(data, to: destination)
            let recovered = try ProjectStore.readMusicCondition(at: destination)
            #expect(try recovered.draft.makeSequence(durationText: recovered.durationText) == MusicCreationDraft.example.makeSequence(durationText: "4"))
            #expect(throws: ProjectStoreError.self) { try ProjectStore.publishMusicCondition(data, to: destination) }
            #expect(try Data(contentsOf: destination) == data)
            let bad = root.appendingPathComponent("bad.json");try Data("{\"schemaVersion\":true}".utf8).write(to: bad)
            #expect(throws: (any Error).self) { try ProjectStore.readMusicCondition(at: bad) }
            #expect(try Data(contentsOf: destination) == data)
        }
    }

    private func fixture(_ body: (URL, URL) async throws -> Void) async throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("music-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root, root.appendingPathComponent("Music.dproject"))
    }
}
