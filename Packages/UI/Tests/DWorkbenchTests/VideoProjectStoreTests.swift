@preconcurrency import AVFoundation
import DInference
import Foundation
import Testing
import VideoToolbox
@testable import DWorkbench

/// Software-encoded synthetic media, independent of the inference implementation.
enum VideoProjectFixture {
    static func draft(_ prompt: String = "红色方块 e\u{301} 🎞️") -> VideoCreationDraft {
        .init(prompt: prompt, widthText: "64", heightText: "48", framesText: "5", stepsText: "1")
    }
    static func root() throws -> URL {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("video-project-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    static func write(_ url: URL, input: VideoRequest) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: input.width, AVVideoHeightKey: input.height,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false],
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]])
        track.mediaTimeScale = input.frameRate.numerator
        writer.movieTimeScale = input.frameRate.numerator
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: input.width, kCVPixelBufferHeightKey as String: input.height])
        writer.add(track)
        guard writer.startWriting() else { throw writer.error ?? ProjectStoreError.invalidTransition }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now + .seconds(15)
        for frame in 0..<input.frameCount {
            while !track.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            try #require(CVPixelBufferCreate(kCFAllocatorDefault, input.width, input.height,
                kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<input.height {
                for x in 0..<input.width {
                    let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                    bytes[offset] = 20; bytes[offset + 1] = UInt8(40 + frame)
                    bytes[offset + 2] = 180; bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            try #require(adaptor.append(pixels, withPresentationTime: CMTime(
                value: Int64(frame) * Int64(input.frameRate.denominator), timescale: input.frameRate.numerator)))
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(input.frameCount) * Int64(input.frameRate.denominator),
                                             timescale: input.frameRate.numerator))
        track.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
    }
    static func output(project: URL, runID: UUID) throws -> URL {
        let directory = project.appendingPathComponent("Tasks/\(runID.uuidString.lowercased())-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("output.mp4")
    }
}

@Suite("Video project ownership and persistence", .serialized)
struct VideoProjectStoreTests {
    @Test func completeChooseRejectRestoreExportAndReopen() async throws {
        let root = try VideoProjectFixture.root(), project = root.appendingPathComponent("作品 🎞️.dproject")
        let store = try await ProjectStore.create(at: project, name: "视频")
        let created = try await store.createVideoCreation()
        let document = try #require(created.activeDocument)
        let draft = VideoProjectFixture.draft()
        let saved = try await store.saveVideoCreation(draft, documentID: document.id, expectedRevision: document.videoCreation!.revision)
        var edited = draft; edited.prompt = "保存和排队之间的新编辑"; edited.revision = UUID()
        _ = try await store.saveVideoCreation(edited, documentID: document.id, expectedRevision: draft.revision)
        let request = InferenceRequest(model: .init(directory: root, revision: "CPU fixture"), input: .video(try draft.makeRequest()))
        _ = try await store.enqueue(request: request, documentID: document.id, capturedVideoDocument: saved.activeDocument)
        #expect(await store.snapshot().activeDocument?.videoCreation == edited)
        let output = try VideoProjectFixture.output(project: project, runID: request.id)
        try await VideoProjectFixture.write(output, input: draft.makeRequest())
        let original = try Data(contentsOf: output)
        let done = try await store.complete(id: request.id, result: .init(artifacts: [.init(url: output, mediaType: "video/mp4")],
            metadata: ["recordPath": output.deletingLastPathComponent().appendingPathComponent("frames/result.json").path]))
        let asset = try #require(done.assets.last)
        #expect(done.activeDocument?.adoptedAssetID == nil && done.activeDocument?.selectedAssetID == nil)
        #expect(done.jobs.last?.resultMetadata["recordPath"]?.hasPrefix("Tasks/") == true)
        await #expect(throws: ProjectStoreError.self) {
            _ = try await store.createDocument(name: "wrong modality", sourceAssetID: asset.id)
        }
        _ = try await store.setSelectedAsset(asset.id, documentID: document.id)
        #expect((await store.snapshot()).activeDocument?.adoptedAssetID == nil)
        _ = try await store.adoptAsset(id: asset.id, documentID: document.id)
        _ = try await store.setVideoCandidateRejected(id: asset.id, rejected: true, documentID: document.id)
        #expect((await store.snapshot()).activeDocument?.adoptedAssetID == nil)
        #expect((await store.snapshot()).activeDocument?.selectedAssetID == nil)
        await #expect(throws: ProjectStoreError.self) { try await store.adoptAsset(id: asset.id, documentID: document.id) }
        _ = try await store.setVideoCandidateRejected(id: asset.id, rejected: false, documentID: document.id)
        _ = try await store.adoptAsset(id: asset.id, documentID: document.id)
        let exported = root.appendingPathComponent("导出 🎞️.mp4")
        try await store.exportVideoAsset(id: asset.id, to: exported)
        await #expect(throws: ProjectStoreError.self) { try await store.exportVideoAsset(id: asset.id, to: exported) }
        #expect(try Data(contentsOf: exported) == original)
        for mode in ["source", "staged", "published"] {
            let destination = root.appendingPathComponent("fault-\(mode).mp4")
            await #expect(throws: (any Error).self) {
                try await store.exportVideoAsset(id: asset.id, to: destination, checkpoint: { point in
                    switch point {
                    case .contentDurable(let staged):
                        if mode == "source" { try Data("changed source".utf8).write(to: output) }
                        if mode == "staged" { try Data("changed staging".utf8).write(to: staged) }
                    case .published:
                        if mode == "published" { throw ProjectStoreError.invalidTransition }
                    }
                })
            }
            if mode == "source" { try original.write(to: output) } // Restore only our intentionally modified fixture.
            if mode == "published" { #expect(try Data(contentsOf: destination) == original) }
            else { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
            #expect(try Data(contentsOf: output) == original)
        }
        let other = try await store.createVideoCreation()
        await #expect(throws: ProjectStoreError.self) { try await store.adoptAsset(id: asset.id, documentID: other.activeDocumentID) }
        _ = try await store.selectDocument(id: document.id)
        try await store.close()
        let reopened = try await ProjectStore.open(at: project)
        let restored = await reopened.snapshot()
        #expect(restored.activeDocument?.adoptedAssetID == asset.id)
        #expect(restored.activeDocument?.videoCreation?.hasSameEditableRepresentation(as: edited) == true)
        #expect(restored.activeDocument?.videoCreation?.rejectedAssetIDs == [])
        #expect(restored.jobs.last?.request == request)
        #expect(try await reopened.inspectVideoAsset(id: asset.id) == output)
        #expect(try Data(contentsOf: output) == original)
        try await reopened.close()
    }

    @Test func cancelledRecoveryAndCorruptResultNeverBecomeAcceptedSuccess() async throws {
        let root = try VideoProjectFixture.root(), project = root.appendingPathComponent("Recovery.dproject")
        let store = try await ProjectStore.create(at: project, name: "恢复")
        let created = try await store.createVideoCreation(), draft = VideoProjectFixture.draft()
        _ = try await store.saveVideoCreation(draft, documentID: created.activeDocumentID,
                                              expectedRevision: created.activeDocument!.videoCreation!.revision)
        let request = InferenceRequest(model: .init(directory: root), input: .video(try draft.makeRequest()))
        _ = try await store.enqueue(request: request)
        let output = try VideoProjectFixture.output(project: project, runID: request.id)
        try Data("broken MP4".utf8).write(to: output)
        let before = await store.snapshot()
        await #expect(throws: (any Error).self) { try await store.complete(id: request.id, result: .init(artifacts: [.init(url: output, mediaType: "video/mp4")])) }
        #expect(await store.snapshot() == before)
        // This is an owned fixture file; replacing its intentionally malformed bytes
        // supplies a valid published output with no authoritative completion.
        try FileManager.default.removeItem(at: output)
        try await VideoProjectFixture.write(output, input: draft.makeRequest())
        _ = try await store.updateJob(id: request.id, state: .cancelled)
        let recovered = try await store.recoverPublishedArtifacts()
        let asset = try #require(recovered.assets.last)
        #expect(recovered.jobs.last?.state == .cancelled)
        await #expect(throws: ProjectStoreError.self) { try await store.adoptAsset(id: asset.id, documentID: created.activeDocumentID) }
        let duplicate = try VideoProjectFixture.output(project: project, runID: request.id)
        try await VideoProjectFixture.write(duplicate, input: draft.makeRequest())
        let duplicateBytes = try Data(contentsOf: duplicate)
        #expect(try await store.recoverPublishedArtifacts().jobs.last?.artifactIDs == [asset.id])
        try await store.close()
        let reopened = try await ProjectStore.open(at: project)
        #expect(await reopened.snapshot().jobs.last?.artifactIDs == [asset.id])
        #expect(try Data(contentsOf: duplicate) == duplicateBytes)
        try await reopened.close()
    }

    @Test func editsAndCancellationDuringActualInspectionCannotBeOverwritten() async throws {
        for cancel in [false, true] {
            let root = try VideoProjectFixture.root(), project = root.appendingPathComponent("Reentrant.dproject")
            let store = try await ProjectStore.create(at: project, name: "reentrant")
            let created = try await store.createVideoCreation(), draft = VideoProjectFixture.draft()
            _ = try await store.saveVideoCreation(draft, documentID: created.activeDocumentID,
                expectedRevision: created.activeDocument!.videoCreation!.revision)
            let request = InferenceRequest(model: .init(directory: root), input: .video(try draft.makeRequest()))
            _ = try await store.enqueue(request: request)
            let output = try VideoProjectFixture.output(project: project, runID: request.id)
            try await VideoProjectFixture.write(output, input: draft.makeRequest())
            let gate = VideoProjectInspectionGate(.afterFullDecode)
            let task = Task {
                try await VideoInspectionTestHooks.$checkpoint.withValue({ gate.reach($0) }) {
                    try await store.complete(id: request.id, result: .init(artifacts: [.init(url: output, mediaType: "video/mp4")]))
                }
            }
            do {
                try await gate.waitForArrival()
                var edited = draft; edited.prompt = "检查中保留的新条件"; edited.revision = UUID()
                _ = try await store.saveVideoCreation(edited, documentID: created.activeDocumentID, expectedRevision: draft.revision)
                if cancel { _ = try await store.updateJob(id: request.id, state: .cancelled) }
                gate.release()
                if cancel { await #expect(throws: ProjectStoreError.self) { try await task.value } }
                else { _ = try await task.value }
                let final = await store.snapshot()
                #expect(final.activeDocument?.videoCreation == edited)
                #expect(final.jobs.last?.state == (cancel ? .cancelled : .completed))
                #expect(final.assets.count == (cancel ? 0 : 1))
                try await store.close()
            } catch {
                gate.release(); task.cancel(); _ = await task.result
                try? await store.close()
                throw error
            }
        }
    }

    @Test func versionSevenBackupsStrictnessAndInvalidDraftSurvival() async throws {
        let root = try VideoProjectFixture.root(), project = root.appendingPathComponent("Legacy.dproject")
        let store = try await ProjectStore.create(at: project, name: "legacy")
        try await store.close()
        let file = project.appendingPathComponent(ProjectStore.manifestFilename)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["schemaVersion"] = 7
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try original.write(to: file)
        let upgraded = try await ProjectStore.open(at: project)
        #expect(try Data(contentsOf: project.appendingPathComponent(ProjectStore.versionSevenBackupFilename)) == original)
        #expect(await upgraded.snapshot().schemaVersion == 9)
        let created = try await upgraded.createVideoCreation()
        var draft = VideoProjectFixture.draft(); draft.widthText = "未完成"; draft.memoryBudgetMiBText = "-"
        _ = try await upgraded.saveVideoCreation(draft, documentID: created.activeDocumentID,
                                                 expectedRevision: created.activeDocument!.videoCreation!.revision)
        try await upgraded.close()
        let reopened = try await ProjectStore.open(at: project)
        #expect(await reopened.snapshot().activeDocument?.videoCreation == draft)
        try await reopened.close()
        var documents = try #require(object["documents"] as? [[String: Any]])
        var image = try #require(documents[0]["draft"] as? [String: Any])
        image.removeValue(forKey: "imageSettings"); documents[0]["draft"] = image; object["documents"] = documents
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        try corrupt.write(to: file)
        await #expect(throws: ProjectStoreError.self) { _ = try await ProjectStore.open(at: project) }
        #expect(try Data(contentsOf: file) == corrupt)
    }
}

/// Synchronous instrumentation gate only; every wait is bounded and every task is drained by its caller.
final class VideoProjectInspectionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let checkpoint: VideoInspectionTestCheckpoint
    private var arrived = false, released = false
    init(_ checkpoint: VideoInspectionTestCheckpoint) { self.checkpoint = checkpoint }
    func reach(_ point: VideoInspectionTestCheckpoint) {
        condition.lock(); defer { condition.unlock() }
        guard point == checkpoint, !arrived else { return }
        arrived = true
        let deadline = Date().addingTimeInterval(8)
        while !released, condition.wait(until: deadline) {}
    }
    private var hasArrived: Bool {
        condition.lock(); defer { condition.unlock() }; return arrived
    }
    func waitForArrival() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !hasArrived {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}
