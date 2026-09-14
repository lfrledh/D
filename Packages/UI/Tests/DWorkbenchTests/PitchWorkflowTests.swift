import CryptoKit
import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Pitch original ownership and durable decisions", .serialized)
struct PitchWorkflowTests {
    @Test func strictFileAndRoundedSourceTailAreIndependentOfProvider() throws {
        let source = PitchSourceIdentity(assetID: UUID(), documentID: UUID(), documentRevision: 0,
            contentSHA256: String(repeating: "a", count: 64), sampleRate: 16_000,
            frameCount: 2000, startFrame: 100, endFrame: 1379)
        let value = PitchAnalysisResult(runID: UUID(), source: source, inputSHA256: String(repeating: "b", count: 64),
            sampleCount: 1280, frames: Array(repeating: .init(pitchHz: 440, confidence: 0.99, voiced: true), count: 5))
        let data = try JSONEncoder().encode(value)
        #expect(try PitchResultFile.decode(data) == value)
        var duplicate = Data("{\"schemaVersion\":1,".utf8); duplicate.append(data.dropFirst())
        #expect(throws: InferenceFailure.self) { try PitchResultFile.decode(duplicate) }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true")
        #expect(throws: (any Error).self) { try PitchResultFile.decode(Data(text.utf8)) }
        let mapped = try #require(PitchSourceNote.map(value).first)
        #expect(mapped.startFramePosition == 100)
        #expect(mapped.endFramePosition == 1379)
        let unvoiced = PitchFrame(pitchHz: nil, confidence: 0.1, voiced: false)
        let encoded = try JSONEncoder().encode(unvoiced)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"pitchHz\":null"))
    }

    @Test func unreadablePendingResultCanBeRejectedAndNavigationExpiresAnother() async throws {
        try await withPitchFixture { root, store, document, original in
            let project = root.appendingPathComponent("Pitch.dproject")
            let (_, damaged) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            let file = project.appendingPathComponent(damaged.relativePath), sentinel = Data("damaged evidence".utf8)
            try sentinel.write(to: file)
            await #expect(throws: ProjectStoreError.self) { try await store.readPitchAnalysis(assetID: damaged.id) }
            _ = try await store.decidePitchAnalysis(assetID: damaged.id, documentID: document.id, accept: false)
            #expect(try Data(contentsOf: file) == sentinel)
            let (_, candidate) = try await pitchCandidate(store: store, documentID: document.id, project: project)
            _ = try await store.invalidatePitchCandidates(documentID: document.id)
            await #expect(throws: ProjectStoreError.self) { try await store.decidePitchAnalysis(assetID: candidate.id, documentID: document.id, accept: true) }
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            await #expect(throws: ProjectStoreError.self) { try await reopened.decidePitchAnalysis(assetID: candidate.id, documentID: document.id, accept: true) }
            _ = try await reopened.decidePitchAnalysis(assetID: candidate.id, documentID: document.id, accept: false)
            #expect(try Data(contentsOf: root.appendingPathComponent("source.wav")) == original)
            try await reopened.close()
        }
    }

    @Test(arguments: [16_000, 24_000, 44_100, 48_000])
    func conversionPreservesSourceAndSelectedTime(rate: Int) async throws {
        try await withPitchFixture(rate: rate) { root, store, document, original in
            var draft = try #require(document.audioDraft)
            let clip = AudioClip(name: "e\u{301} 🎵", range: .init(startFrame: Int64(rate / 4), endFrame: Int64(rate * 3 / 4)))
            draft.clips = [clip]; draft.selectedClipID = clip.id; draft.revision += 1
            _ = try await store.saveAudioDraft(draft, documentID: document.id, expectedRevision: 0)
            let input = try await store.preparePitchInput(documentID: document.id, runID: UUID())
            #expect(abs(input.sampleCount - 8_000) <= 1)
            #expect(input.source.startFrame == Int64(rate / 4))
            #expect(input.source.documentRevision == 1)
            let data = try Data(contentsOf: input.inputURL)
            #expect(data.count == input.sampleCount * 4)
            #expect(digest(data) == input.inputSHA256)
            let samples = data.withUnsafeBytes { raw in (0..<input.sampleCount).map { i in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            } }
            #expect(samples.allSatisfy { $0.isFinite })
            let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            #expect(abs(crossings - 220) <= 2)
            let asset = try #require(await store.snapshot().assets.first)
            #expect(try Data(contentsOf: await store.assetURL(for: asset)) == original)
            #expect(try Data(contentsOf: root.appendingPathComponent("source.wav")) == original)
        }
    }

    @Test func acceptRejectExportReopenPreservesOriginalAndHistory() async throws {
        try await withPitchFixture { root, store, document, original in
            let (result, asset) = try await pitchCandidate(store: store, documentID: document.id, project: root.appendingPathComponent("Pitch.dproject"))
            #expect(try await store.readPitchAnalysis(assetID: asset.id) == result)
            #expect(await store.snapshot().documents.last?.audioDraft == document.audioDraft)
            let saved = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
            #expect(saved.documents.last?.pitchAnalysis?.acceptedAssetIDs == [asset.id])
            let (_, other) = try await pitchCandidate(store: store, documentID: document.id, project: root.appendingPathComponent("Pitch.dproject"))
            let rejected = try await store.decidePitchAnalysis(assetID: other.id, documentID: document.id, accept: false)
            #expect(rejected.documents.last?.pitchAnalysis?.selectedAssetID == asset.id)
            #expect(rejected.documents.last?.pitchAnalysis?.rejectedAssetIDs == [other.id])
            let target = root.appendingPathComponent("音高 候选.json")
            try await store.exportPitchAnalysis(assetID: asset.id, to: target)
            let bytes = try Data(contentsOf: target)
            #expect(!String(decoding: bytes, as: UTF8.self).contains(root.path))
            await #expect(throws: ProjectStoreError.self) { try await store.exportPitchAnalysis(assetID: asset.id, to: target) }
            #expect(try Data(contentsOf: target) == bytes)
            try await store.close()
            let reopened = try await ProjectStore.open(at: root.appendingPathComponent("Pitch.dproject"))
            #expect(await reopened.snapshot() == rejected)
            #expect(try await reopened.readPitchAnalysis(assetID: asset.id) == result)
            let source = try #require(await reopened.snapshot().assets.first)
            #expect(try Data(contentsOf: await reopened.assetURL(for: source)) == original)
            try await reopened.close()
        }
    }

    @Test func changedDraftMakesCandidateStaleAndRefusesAnotherUndecidedRun() async throws {
        try await withPitchFixture { root, store, document, _ in
            let (_, asset) = try await pitchCandidate(store: store, documentID: document.id, project: root.appendingPathComponent("Pitch.dproject"))
            var draft = try #require(document.audioDraft); draft.revision = 1; draft.note = "changed 原声 e\u{301}"
            _ = try await store.saveAudioDraft(draft, documentID: document.id, expectedRevision: 0)
            await #expect(throws: ProjectStoreError.self) { try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true) }
            let id = UUID(), input = try await store.preparePitchInput(documentID: document.id, runID: UUID())
            await #expect(throws: ProjectStoreError.self) {
                try await store.enqueue(request: .init(id: id, model: pitchModel, input: .pitch(input)), documentID: document.id)
            }
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: false)
            #expect(await store.snapshot().documents.last?.audioDraft == draft)
        }
    }

    @Test func wrongResultSourceAndBrokenSaveKeepPriorManifestAndAllowRetry() async throws {
        try await withPitchFixture { root, store, document, _ in
            let project = root.appendingPathComponent("Pitch.dproject"), id = UUID()
            let request = try await store.preparePitchInput(documentID: document.id, runID: id)
            _ = try await store.enqueue(request: .init(id: id, model: pitchModel, input: .pitch(request)), documentID: document.id)
            let output = project.appendingPathComponent("Tasks/\(id.uuidString)/pitch.json")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let wrong = pitchResult(request: request, id: UUID())
            try JSONEncoder().encode(wrong).write(to: output)
            let completion = InferenceResult(artifacts: [.init(url: output, mediaType: PitchAnalysisResult.mediaType)])
            await #expect(throws: ProjectStoreError.self) { try await store.complete(id: id, result: completion) }
            #expect(await store.snapshot().assets.count == 1)
            let correct = pitchResult(request: request, id: id)
            try JSONEncoder().encode(correct).write(to: output)
            let completed = try await store.complete(id: id, result: completion)
            let asset = try #require(completed.assets.last)
            let manifest = project.appendingPathComponent(ProjectStore.manifestFilename), before = try Data(contentsOf: manifest)
            let sentinel = Data("controlled external edit".utf8); try sentinel.write(to: manifest)
            await #expect(throws: ProjectStoreError.externalModification) { try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true) }
            #expect(try Data(contentsOf: manifest) == sentinel)
            #expect(await store.snapshot() == completed)
            try before.write(to: manifest)
            _ = try await store.decidePitchAnalysis(assetID: asset.id, documentID: document.id, accept: true)
        }
    }

    @Test func schemaElevenBackupIsExactAndCannotSmugglePitchState() async throws {
        try await withPitchFixture { root, store, _, original in
            let previous = await store.snapshot(); try await store.close()
            let project = root.appendingPathComponent("Pitch.dproject"), file = project.appendingPathComponent(ProjectStore.manifestFilename)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["schemaVersion"] = 11
            let old = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]); try old.write(to: file)
            let reopened = try await ProjectStore.open(at: project)
            #expect(await reopened.snapshot().schemaVersion == 12)
            #expect(await reopened.snapshot().documents == previous.documents)
            #expect(try Data(contentsOf: project.appendingPathComponent("project.v11.backup.json")) == old)
            let asset = try #require(await reopened.snapshot().assets.first)
            #expect(try Data(contentsOf: await reopened.assetURL(for: asset)) == original)
            try await reopened.close()
            var docs = try #require(object["documents"] as? [[String: Any]])
            docs[docs.count - 1]["pitchAnalysis"] = ["acceptedAssetIDs": [], "rejectedAssetIDs": []]
            object["documents"] = docs
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            await #expect(throws: ProjectStoreError.self) { try await ProjectStore.open(at: project) }
        }
    }
}

private let pitchModel = ModelReference(directory: URL(fileURLWithPath: "/fixture/swift_f0"), revision: PitchAnalysisRequest.modelSHA256)
private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func pitchResult(request: PitchAnalysisRequest, id: UUID) -> PitchAnalysisResult {
    .init(runID: id, source: request.source, inputSHA256: request.inputSHA256, sampleCount: request.sampleCount,
          frames: Array(repeating: .init(pitchHz: 440, confidence: 0.99, voiced: true), count: request.sampleCount / 256))
}
private func pitchCandidate(store: ProjectStore, documentID: UUID, project: URL) async throws -> (PitchAnalysisResult, ProjectAsset) {
    let id = UUID(), request = try await store.preparePitchInput(documentID: documentID, runID: id)
    _ = try await store.enqueue(request: .init(id: id, model: pitchModel, input: .pitch(request)), documentID: documentID)
    let result = pitchResult(request: request, id: id), output = project.appendingPathComponent("Tasks/\(id.uuidString)/pitch.json")
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(result).write(to: output)
    let completed = try await store.complete(id: id, result: .init(artifacts: [.init(url: output, mediaType: PitchAnalysisResult.mediaType)]))
    return (result, try #require(completed.assets.last))
}
private func withPitchFixture(rate: Int = 16_000, body: (URL, ProjectStore, ProjectDocument, Data) async throws -> Void) async throws {
    let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? FileManager.default.temporaryDirectory.path
    let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.wav")
    let samples = (0..<rate).map { Float(0.4 * sin(2 * Double.pi * 440 * Double($0) / Double(rate))) }
    try AudioTestMedia.writePCM(to: source, samples: [samples], sampleRate: Double(rate), bitDepth: 32, floatingPoint: true)
    let store = try await ProjectStore.create(at: root.appendingPathComponent("Pitch.dproject"), name: "Pitch")
    let imported = try await store.importAudio(at: source, name: "哼唱 🎵")
    try await body(root, store, try #require(imported.documents.last), Data(contentsOf: source))
    try await store.close()
}
