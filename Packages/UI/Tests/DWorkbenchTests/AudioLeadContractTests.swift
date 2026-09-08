import Foundation
import AVFoundation
import Testing
@testable import DWorkbench

/// Lead counterexamples use independently assembled RIFF bytes, not production encoders.
@Suite("Audio admission and original-byte protection")
struct AudioLeadContractTests {
    @Test func importedBytesAndFrameExportSurviveSourceRemoval() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("原声 e\u{301} 👩‍🎤.wav")
        let original = wave(samples: [0, 8192, -16384, 24576, 0, -8192])
        try original.write(to: source)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("声音.dproject"), name: "声音")
        let manifest = try await store.importAudio(at: source, name: "人类原声")
        let document = try #require(manifest.activeDocument)
        let draft = try #require(document.audioDraft)
        let asset = try #require(manifest.assets.first { $0.id == draft.assetID })
        #expect(asset.role == .original && asset.jobID == nil)
        #expect(asset.metadata.audio?.origin == .importedFile)
        try FileManager.default.removeItem(at: source) // only this test's own synthetic input
        let copy = root.appendingPathComponent("原件导出.wav")
        try await store.export(assetID: asset.id, to: copy)
        #expect(try Data(contentsOf: copy) == original)
        let clip = root.appendingPathComponent("片段.wav")
        try await store.exportAudioClip(documentID: document.id,
            range: .init(startFrame: 1, endFrame: 4), to: clip)
        let file = try AVAudioFile(forReading: clip)
        #expect(file.length == 3)
        #expect(file.fileFormat.sampleRate == 8000 && file.fileFormat.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 3))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect(buffer.frameLength == 3)
        #expect(abs(samples[0] - 0.25) < 0.000001)
        #expect(abs(samples[1] + 0.5) < 0.000001)
        #expect(abs(samples[2] - 0.75) < 0.000001)
        let savedClip = try Data(contentsOf: clip)
        await #expect(throws: (any Error).self) {
            try await store.exportAudioClip(documentID: document.id,
                range: .init(startFrame: 0, endFrame: 1), to: clip)
        }
        #expect(try Data(contentsOf: clip) == savedClip)
        try await store.close()
        let reopened = try await ProjectStore.open(at: root.appendingPathComponent("声音.dproject"))
        let restored = await reopened.snapshot()
        #expect(restored.activeDocument?.audioDraft?.assetID == asset.id)
        let owned = try await reopened.assetURL(for: asset)
        #expect(try Data(contentsOf: owned) == original)
        try await reopened.close()
    }

    @Test func declaredButMissingPCMFramesCannotBecomeAnAsset() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("truncated.wav")
        var bytes = wave(samples: [1, 2, 3, 4])
        bytes.removeLast(4) // RIFF/data sizes still claim four frames; only two remain.
        try bytes.write(to: source)
        #expect(throws: (any Error).self) { try AudioMediaInspector.inspect(at: source) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("safe.dproject"), name: "safe")
        let before = await store.snapshot()
        await #expect(throws: (any Error).self) { try await store.importAudio(at: source, name: "broken") }
        let after = await store.snapshot()
        #expect(after == before)
        #expect(try Data(contentsOf: source) == bytes)
        try await store.close()
    }

    @Test func canonicalUnicodeExternalNoteIsNotEqualForOverwriteProtection() async throws {
        let root = try directory()
        let project = root.appendingPathComponent("保护.dproject")
        let source = root.appendingPathComponent("sample.wav")
        try wave(samples: [0, 1, -1, 2]).write(to: source)
        let store = try await ProjectStore.create(at: project, name: "保护")
        let imported = try await store.importAudio(at: source, name: "原声")
        var draft = try #require(imported.activeDocument?.audioDraft)
        draft.note = "é"; draft.revision += 1
        _ = try await store.saveAudioDraft(draft, documentID: draft.id, expectedRevision: 0)
        let file = project.appendingPathComponent(ProjectStore.manifestFilename)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var documents = try #require(object["documents"] as? [[String: Any]])
        let index = try #require(documents.firstIndex { $0["id"] as? String == draft.id.uuidString })
        var audio = try #require(documents[index]["audioDraft"] as? [String: Any])
        audio["note"] = "e\u{301}"; documents[index]["audioDraft"] = audio; object["documents"] = documents
        let external = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try external.write(to: file, options: .atomic)
        draft.note = "不能覆盖"; draft.revision += 1
        await #expect(throws: ProjectStoreError.externalModification) {
            try await store.saveAudioDraft(draft, documentID: draft.id, expectedRevision: 1)
        }
        #expect(try Data(contentsOf: file) == external)
        try await store.close(preserveExternalChanges: true)
    }

    private func directory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let base = try #require(environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("audio-lead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func wave(samples: [Int16]) -> Data {
        var bytes = Data()
        func ascii(_ s: String) { bytes.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { bytes.append(UInt8(truncatingIfNeeded: n)); bytes.append(UInt8(truncatingIfNeeded: n >> 8)) }
        func u32(_ n: UInt32) { for shift in stride(from: 0, through: 24, by: 8) { bytes.append(UInt8(truncatingIfNeeded: n >> shift)) } }
        ascii("RIFF"); u32(UInt32(36 + samples.count * 2)); ascii("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        ascii("data"); u32(UInt32(samples.count * 2))
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return bytes
    }
}
