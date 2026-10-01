import AVFoundation
import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("H3 and LTX audiovisual MP4 inspection", .serialized)
struct VideoAVMediaInspectorTests {
    @Test(arguments: [ExternalVideoExecutionProfile.h3BF16Full,
                      .ltx23BF16Full, .ltx23Q8GemmaQ4, .ltx25BF16Full])
    func acceptsFullyDecodedBFramesAndAAC(profile: ExternalVideoExecutionProfile) async throws {
        try await withAVFixtureDirectory { directory in
            let rate = profile == .h3BF16Full ? 32_000 : 48_000
            let frames = profile == .h3BF16Full ? 22 : 9
            let file = directory.appendingPathComponent("av-\(profile.rawValue).mp4")
            try writeAVFixture(to: file, frames: frames, sampleRate: rate)
            #expect(try await hasReorderedH264Samples(file))
            let sampleSummary = try await compressedVideoSampleSummary(file)
            #expect(sampleSummary.frames == frames && sampleSummary.emptyMarkers > 0)
            let request = avRequest(profile, frames: frames)
            let bytes = try Data(contentsOf: file)
            let value = try await VideoMediaInspector.inspect(at: file, expected: request)
            #expect(value.width == 64 && value.height == 64 && value.frameCount == frames)
            #expect(value.hasAudio && value.audioTrack?.codec == "aac")
            #expect(value.audioTrack?.sampleRate == rate && value.audioTrack?.channels == 2)
            #expect((value.audioTrack?.decodedSampleCount ?? 0) > 0)
            #expect(value.byteCount == UInt64(bytes.count))
            try value.validateStoredMedia()
            let imported = try await VideoMediaInspector.inspectImported(at: file)
            #expect(imported == value)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func audioTailMayExtendPastAVAssetPresentationDuration() async throws {
        try await withAVFixtureDirectory { directory in
            let file = directory.appendingPathComponent("valid-audio-tail.mp4")
            try writeAVFixture(to: file, frames: 22, sampleRate: 32_000, audioTail: 1.0 / 120)
            let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            let videoRange = try await #require(videos.first).load(.timeRange)
            let audioRange = try await #require(audios.first).load(.timeRange)
            let duration = try await asset.load(.duration)
            let videoEnd = CMTimeRangeGetEnd(videoRange)
            let audioEnd = CMTimeRangeGetEnd(audioRange)
            #expect(audioEnd > videoEnd)
            // Assert the actual platform behavior behind the original H3 rejection.
            #expect(CMTimeCompare(duration, videoEnd) == 0)
            let original = try Data(contentsOf: file)
            let inspected = try await VideoMediaInspector.inspect(at: file,
                expected: avRequest(.h3BF16Full, frames: 22))
            #expect(inspected.hasAudio && inspected.frameCount == 22)
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func rejectsAbsentExtraAndWrongAudio() async throws {
        try await withAVFixtureDirectory { directory in
            let request = avRequest(.ltx23BF16Full, frames: 9)
            for (name, tracks, rate, channels) in [
                ("absent", 0, 48_000, 2), ("extra", 2, 48_000, 2),
                ("rate", 1, 44_100, 2), ("mono", 1, 48_000, 1)
            ] {
                let file = directory.appendingPathComponent("\(name).mp4")
                try writeAVFixture(to: file, frames: 9, sampleRate: rate,
                                   channels: channels, audioTracks: tracks)
                await #expect(throws: (any Error).self) {
                    try await VideoMediaInspector.inspect(at: file, expected: request)
                }
                if name != "absent" {
                    await #expect(throws: (any Error).self) {
                        try await VideoMediaInspector.inspectImported(at: file)
                    }
                }
            }
        }
    }

    @Test func exactRecipeSelectsTheAudioRateAndWanStaysSilent() async throws {
        try await withAVFixtureDirectory { directory in
            let rate32 = directory.appendingPathComponent("32k.mp4")
            let rate48 = directory.appendingPathComponent("48k.mp4")
            try writeAVFixture(to: rate32, frames: 9, sampleRate: 32_000)
            try writeAVFixture(to: rate48, frames: 22, sampleRate: 48_000)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: rate32,
                    expected: avRequest(.ltx23BF16Full, frames: 9))
            }
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: rate48,
                    expected: avRequest(.h3BF16Full, frames: 22))
            }
            let wan = VideoRequest(prompt: "fixture", negativePrompt: "", width: 64, height: 64,
                frameCount: 9, frameRate: .init(numerator: 24), steps: 2,
                guidanceScale: 1, scheduleShift: 1, seed: 1,
                executionProfile: VideoExecutionCapability.wan21.profile)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: rate32, expected: wan)
            }
        }
    }

    @Test func rejectsTruncationAndShiftedTimelines() async throws {
        try await withAVFixtureDirectory { directory in
            let request = avRequest(.ltx23Q8GemmaQ4, frames: 9)
            let valid = directory.appendingPathComponent("valid.mp4")
            try writeAVFixture(to: valid, frames: 9, sampleRate: 48_000)
            let truncated = directory.appendingPathComponent("truncated.mp4")
            var bytes = try Data(contentsOf: valid)
            bytes.removeLast(bytes.count / 2)
            try bytes.write(to: truncated)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: truncated, expected: request)
            }
            let corrupt = directory.appendingPathComponent("corrupt.mp4")
            var damaged = try Data(contentsOf: valid)
            damaged.replaceSubrange(4..<8, with: Array("bad!".utf8))
            try damaged.write(to: corrupt)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: corrupt, expected: request)
            }
            let shiftedAudio = directory.appendingPathComponent("shifted-audio.mp4")
            try writeAVFixture(to: shiftedAudio, frames: 9, sampleRate: 48_000,
                               audioOffset: 0.20)
            let shiftedAudioTracks = try await AVURLAsset(url: shiftedAudio).loadTracks(withMediaType: .audio)
            let shiftedAudioSegments = try await #require(shiftedAudioTracks.first).load(.segments)
            let shiftedContent = try #require(shiftedAudioSegments.first(where: { !$0.isEmpty }))
            #expect(shiftedContent.timeMapping.target.start.seconds > 0.15)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: shiftedAudio, expected: request)
            }
            let shiftedVideo = directory.appendingPathComponent("shifted-video.mp4")
            try writeAVFixture(to: shiftedVideo, frames: 9, sampleRate: 48_000,
                               videoOffset: 0.25)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: shiftedVideo, expected: request)
            }
        }
    }

    @Test func emptyMarkersCannotReplaceAMissingPresentationFrame() async throws {
        try await withAVFixtureDirectory { directory in
            let file = directory.appendingPathComponent("missing-frame.mp4")
            try writeAVFixture(to: file, frames: 9, sampleRate: 48_000, dropVideoFrame: 4)
            let summary = try await compressedVideoSampleSummary(file)
            #expect(summary.frames == 8 && summary.emptyMarkers > 0)
            let videoTracks = try await AVURLAsset(url: file).loadTracks(withMediaType: .video)
            let videoTrack = try #require(videoTracks.first)
            let range = try await videoTrack.load(.timeRange)
            #expect(CMTimeCompare(range.duration, CMTime(value: 9, timescale: 24)) == 0)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: file,
                    expected: avRequest(.ltx23BF16Full, frames: 9))
            }
        }
    }

    @Test func movieDurationCannotBorrowAVAlignmentTolerance() async throws {
        try await withAVFixtureDirectory { directory in
            let valid = directory.appendingPathComponent("valid-duration.mp4")
            let altered = directory.appendingPathComponent("movie-duration-only.mp4")
            try writeAVFixture(to: valid, frames: 9, sampleRate: 48_000)
            let original = try Data(contentsOf: valid)
            let changed = try changeOnlyMovieDuration(original, additionalSeconds: 0.05)
            #expect(changed.count == original.count)
            let changedBytes = zip(original, changed).filter { pair in pair.0 != pair.1 }.count
            #expect((1...8).contains(changedBytes))
            try changed.write(to: altered)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: altered,
                    expected: avRequest(.ltx23BF16Full, frames: 9))
            }
        }
    }

    @Test func cancellationDuringAudioDecodeDrainsBeforeReturn() async throws {
        try await withAVFixtureDirectory { directory in
            let file = directory.appendingPathComponent("cancel.mp4")
            try writeAVFixture(to: file, frames: 9, sampleRate: 48_000)
            let gate = AVInspectionGate()
            let request = avRequest(.ltx23BF16Full, frames: 9)
            let task = Task {
                try await VideoInspectionTestHooks.$checkpoint.withValue({ gate.reach($0) }) {
                    try await VideoMediaInspector.inspect(at: file, expected: request)
                }
            }
            guard gate.waitUntilBlocked() else {
                task.cancel(); gate.release(); _ = try? await task.value
                Issue.record("AAC PCM 解码边界未到达")
                return
            }
            task.cancel()
            gate.release()
            do {
                _ = try await task.value
                Issue.record("取消后错误地发布了音视频元数据")
            } catch is CancellationError {
                // Cancellation is observed only after the owner has drained the reader.
            }
            let readsAtReturn = gate.reachCount
            try await Task.sleep(for: .milliseconds(20))
            #expect(gate.reachCount == readsAtReturn)
        }
    }

    @Test func replacingPathDuringAudioDecodeCannotPublish() async throws {
        try await withAVFixtureDirectory { directory in
            let selected = directory.appendingPathComponent("selected.mp4")
            let replacement = directory.appendingPathComponent("replacement.mp4")
            let held = directory.appendingPathComponent("held.mp4")
            try writeAVFixture(to: selected, frames: 9, sampleRate: 48_000)
            try writeAVFixture(to: replacement, frames: 9, sampleRate: 48_000)
            let gate = AVInspectionGate()
            let request = avRequest(.ltx23BF16Full, frames: 9)
            let task = Task {
                try await VideoInspectionTestHooks.$checkpoint.withValue({ gate.reach($0) }) {
                    try await VideoMediaInspector.inspect(at: selected, expected: request)
                }
            }
            guard gate.waitUntilBlocked() else {
                task.cancel(); gate.release(); _ = try? await task.value
                Issue.record("路径替换前未到达 AAC 解码边界")
                return
            }
            do {
                try FileManager.default.moveItem(at: selected, to: held)
                try FileManager.default.moveItem(at: replacement, to: selected)
            } catch {
                task.cancel(); gate.release(); _ = try? await task.value
                throw error
            }
            gate.release()
            do {
                _ = try await task.value
                Issue.record("路径替换后错误地发布了音视频元数据")
            } catch {
                #expect(error.localizedDescription.contains("身份"))
            }
        }
    }

    @Test func oldJSONAndIndependentMetadataValidation() throws {
        let silent = VideoAssetMetadata(width: 64, height: 64, frameCount: 9,
            frameRate: .init(numerator: 24), durationNumerator: 9, durationDenominator: 24,
            codec: "h264", hasAudio: false, byteCount: 100,
            contentSHA256: String(repeating: "a", count: 64))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(silent)) as! [String: Any]
        json.removeValue(forKey: "audioTrack")
        let decoded = try JSONDecoder().decode(VideoAssetMetadata.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.audioTrack == nil && !decoded.hasAudio)
        try decoded.validateStoredMedia()

        let audio = VideoAudioTrackMetadata(codec: "aac", sampleRate: 48_000, channels: 2,
            decodedSampleCount: 18_000, startNumerator: 0, startDenominator: 1,
            durationNumerator: 18_000, durationDenominator: 48_000)
        let valid = VideoAssetMetadata(width: 64, height: 64, frameCount: 9,
            frameRate: .init(numerator: 24), durationNumerator: 9, durationDenominator: 24,
            codec: "h264", hasAudio: true, byteCount: 100,
            contentSHA256: String(repeating: "b", count: 64), audioTrack: audio)
        try valid.validateStoredMedia()
        let inconsistent = VideoAssetMetadata(width: 64, height: 64, frameCount: 9,
            frameRate: .init(numerator: 24), durationNumerator: 9, durationDenominator: 24,
            codec: "h264", hasAudio: false, byteCount: 100,
            contentSHA256: String(repeating: "b", count: 64), audioTrack: audio)
        #expect(throws: (any Error).self) { try inconsistent.validateStoredMedia() }
        let distant = VideoAudioTrackMetadata(codec: "aac", sampleRate: 48_000, channels: 2,
            decodedSampleCount: 18_000, startNumerator: 1, startDenominator: 1,
            durationNumerator: 18_000, durationDenominator: 48_000)
        let badTimeline = VideoAssetMetadata(width: 64, height: 64, frameCount: 9,
            frameRate: .init(numerator: 24), durationNumerator: 9, durationDenominator: 24,
            codec: "h264", hasAudio: true, byteCount: 100,
            contentSHA256: String(repeating: "b", count: 64), audioTrack: distant)
        #expect(throws: (any Error).self) { try badTimeline.validateStoredMedia() }
        let badHash = VideoAssetMetadata(width: 64, height: 64, frameCount: 9,
            frameRate: .init(numerator: 24), durationNumerator: 9, durationDenominator: 24,
            codec: "h264", hasAudio: true, byteCount: 100,
            contentSHA256: "not-a-digest", audioTrack: audio)
        #expect(throws: (any Error).self) { try badHash.validateStoredMedia() }
    }

    @Test func unknownOrMismatchedProfilesCannotSelectMediaPolicy() throws {
        let valid = avRequest(.ltx23BF16Full, frames: 9)
        #expect(try VideoOutputInspectionPolicy.resolve(for: valid) == .ltx23BF16)
        let unknown = VideoRequest(prompt: "fixture", negativePrompt: "", width: 64, height: 64,
            frameCount: 9, frameRate: .init(numerator: 24), steps: 2,
            guidanceScale: 1, scheduleShift: 1, seed: 1,
            executionProfile: .init(identifier: "unrecognized-video-v1"),
            adapterOptions: .ltx(streamWeights: false, spatiotemporalGuidance: 0))
        #expect(throws: (any Error).self) { try VideoOutputInspectionPolicy.resolve(for: unknown) }
        let wrongRevision = VideoRequest(prompt: "fixture", negativePrompt: "", width: 64, height: 64,
            frameCount: 9, frameRate: .init(numerator: 24), steps: 2,
            guidanceScale: 1, scheduleShift: 1, seed: 1,
            executionProfile: .init(identifier: valid.executionProfile.identifier, revision: 2),
            adapterOptions: .ltx(streamWeights: false, spatiotemporalGuidance: 0))
        #expect(throws: (any Error).self) { try VideoOutputInspectionPolicy.resolve(for: wrongRevision) }
        let wrongOptions = VideoRequest(prompt: "fixture", negativePrompt: "", width: 64, height: 64,
            frameCount: 9, frameRate: .init(numerator: 24), steps: 2,
            guidanceScale: 1, scheduleShift: 1, seed: 1,
            executionProfile: valid.executionProfile,
            adapterOptions: .h3(streamWeights: false))
        #expect(throws: (any Error).self) { try VideoOutputInspectionPolicy.resolve(for: wrongOptions) }
    }
    @Test func generatedAVPublishesReopensAndExportsActualBytes() async throws {
        try await withAVFixtureDirectory { directory in
            let project = directory.appendingPathComponent("影片.dproject")
            let store = try await ProjectStore.create(at: project, name: "AV")
            let video = avRequest(.ltx23Q8GemmaQ4, frames: 9)
            let request = InferenceRequest(model: .init(directory: directory.appendingPathComponent("model"),
                revision: ExternalVideoExecutionProfile.ltx23Q8GemmaQ4.modelIdentity), input: .video(video))
            let output = try VideoProjectFixture.output(project: project, runID: request.id)
            try writeAVFixture(to: output, frames: 9, sampleRate: 48_000)
            let bytes = try await store.readWorkflowBackendMedia(.init(url: output, mediaType: "video/mp4"), request: request)
            let published = try await store.publishWorkflowVideo(data: bytes, expected: video, name: "候选",
                operationID: "d.video.ltx23", request: request)
            #expect(published.asset.metadata.video?.hasAudio == true)
            #expect(published.asset.metadata.video?.audioTrack?.sampleRate == 48_000)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            #expect(try await reopened.workflowData(published.record.reference) == bytes)
            let item = try await reopened.workflowMedia(published.record.reference)
            #expect(item.1.metadata.video == published.asset.metadata.video)
            let export = try await reopened.exportWorkflowAssets([published.record.reference], name: "AV-export",
                exportID: UUID(), directory: directory)
            #expect(export.names == ["1.mp4", "recipe.json"])
            try await reopened.close()
            #expect(try Data(contentsOf: output) == bytes)
        }
    }

    @Test func version18MigrationBacksUpWithoutChangingExistingMedia() async throws {
        try await withAVFixtureDirectory { directory in
            let project = directory.appendingPathComponent("old.dproject")
            let store = try await ProjectStore.create(at: project, name: "legacy")
            let published = try await store.publishWorkflowAsset(data: Data("kept text".utf8), mediaType: "text/plain",
                name: "original", operationID: "d.asset.import")
            try await store.close()
            let file = project.appendingPathComponent(ProjectStore.manifestFilename)
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            json["schemaVersion"] = 18
            let original = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try original.write(to: file)
            let reopened = try await ProjectStore.open(at: project)
            #expect(await reopened.snapshot().schemaVersion == 19)
            #expect(try Data(contentsOf: project.appendingPathComponent(ProjectStore.versionEighteenBackupFilename)) == original)
            #expect(try await reopened.workflowData(published.record.reference) == Data("kept text".utf8))
            try await reopened.close()
            #expect(try Data(contentsOf: project.appendingPathComponent(published.asset.relativePath)) == Data("kept text".utf8))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_TEST_REAL_AV_FILE"] != nil))
    func realSmokeOutputPublishesReopensAndExports() async throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(env["D_TEST_REAL_AV_FILE"]))
        let name = try #require(env["D_TEST_REAL_AV_PROFILE"])
        let profile = try #require(ExternalVideoExecutionProfile(rawValue: name))
        let original = try Data(contentsOf: source)
        try await withAVFixtureDirectory { directory in
            let project = directory.appendingPathComponent("real-output.dproject")
            let store = try await ProjectStore.create(at: project, name: "Real generated media validation")
            let h3 = profile == .h3BF16Full
            let legacyVideo = VideoRequest(prompt: "A red ceramic cup on a wooden table, steady camera, natural light.",
                negativePrompt: "", width: 256, height: 256, frameCount: h3 ? 22 : 9,
                frameRate: .init(numerator: 24), steps: 2, guidanceScale: 1, scheduleShift: 1,
                seed: 42, executionProfile: profile.reference,
                adapterOptions: h3 ? .h3(streamWeights: true) : .ltx(streamWeights: true, spatiotemporalGuidance: 0))
            let request: InferenceRequest
            if let path = env["D_TEST_REAL_AV_REQUEST"] {
                request = try JSONDecoder().decode(InferenceRequest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                let result = try JSONDecoder().decode(InferenceResult.self, from: Data(contentsOf:
                    URL(fileURLWithPath: try #require(env["D_TEST_REAL_AV_RESULT"]))))
                try #require(result.artifacts.count == 1 && result.artifacts.first?.url == source)
                try #require(UUID(uuidString: String(source.deletingLastPathComponent().lastPathComponent.prefix(36))) == request.id)
                try #require(result.metadata["profile"] == profile.rawValue)
                try #require(result.metadata["modelRevision"] == profile.modelRevision)
                guard case .video(let originalVideo) = request.input else { throw AVFixtureError("Expected video request") }
                try #require(result.metadata["firstFrameSHA256"] == originalVideo.firstFrame?.contentSHA256)
                try #require(result.metadata["lastFrameSHA256"] == originalVideo.lastFrame?.contentSHA256)
            } else {
                request = InferenceRequest(model: .init(directory: directory.appendingPathComponent("model-not-read"),
                    revision: profile.modelIdentity), input: .video(legacyVideo))
            }
            guard case .video(let video) = request.input else { throw AVFixtureError("Expected the original video request") }
            try #require(video.executionProfile == profile.reference)
            let output = try VideoProjectFixture.output(project: project, runID: request.id)
            try original.write(to: output, options: .withoutOverwriting)
            let bytes = try await store.readWorkflowBackendMedia(.init(url: output, mediaType: "video/mp4"), request: request)
            let published = try await store.publishWorkflowVideo(data: bytes, expected: video, name: "Real smoke output",
                operationID: WorkflowVideoRecipe(profile: profile).operationID, request: request)
            #expect(published.asset.metadata.video?.hasAudio == true)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            #expect(try await reopened.workflowData(published.record.reference) == original)
            #expect(try await reopened.workflowState().archive?.assets.first { $0.reference == published.record.reference }?.request == request)
            let export = try await reopened.exportWorkflowAssets([published.record.reference], name: "real-export",
                exportID: UUID(), directory: directory)
            #expect(export.names == ["1.mp4", "recipe.json"])
            let package = directory.appendingPathComponent("real-export-\(export.id).dexport")
            #expect(try Data(contentsOf: package.appendingPathComponent("1.mp4")) == original)
            let recipe = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("recipe.json"))) as? [String: Any])
            let item = try #require((recipe["items"] as? [[String: Any]])?.first)
            #expect(item["modelRevision"] as? String == request.model.revision)
            #expect(item["operationID"] as? String == WorkflowVideoRecipe(profile: profile).operationID)
            // Current public video recipe omits the request; full conditions remain private.
            #expect(item["input"] == nil)
            try await reopened.close()
        }
        #expect(try Data(contentsOf: source) == original)
        print("D_REAL_AV_STORE profile=\(profile.rawValue) source=\(source.path) bytes=\(original.count)")
    }

}

private func avRequest(_ profile: ExternalVideoExecutionProfile, frames: Int) -> VideoRequest {
    let h3 = profile == .h3BF16Full
    return VideoRequest(prompt: "fixture", negativePrompt: "", width: 64, height: 64,
        frameCount: frames, frameRate: .init(numerator: 24), steps: 2,
        guidanceScale: 1, scheduleShift: 1, seed: 1, executionProfile: profile.reference,
        adapterOptions: h3 ? .h3(streamWeights: false)
                           : .ltx(streamWeights: false, spatiotemporalGuidance: 0))
}

private func withAVFixtureDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    guard let root = ProcessInfo.processInfo.environment["D_TEST_WORKBENCH_ROOT"] else {
        throw AVFixtureError("设置 D_TEST_WORKBENCH_ROOT 为本任务 tmp 后运行音视频测试")
    }
    let directory = URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent("avmedia-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory.resolvingSymlinksInPath())
}

private func writeAVFixture(to url: URL, frames: Int, sampleRate: Int, channels: Int = 2,
                            audioTracks: Int = 1, audioOffset: Double = 0,
                            videoOffset: Double = 0, dropVideoFrame: Int? = nil, audioTail: Double = 0) throws {
    let executable = "/opt/homebrew/bin/ffmpeg"
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw AVFixtureError("固定 FFmpeg 不可用：\(executable)")
    }
    if audioTail != 0 {
        let raw = url.deletingPathExtension().appendingPathExtension("video-source.mp4")
        try writeAVFixture(to: raw, frames: frames, sampleRate: sampleRate, audioTracks: 0)
        let mux = Process()
        mux.executableURL = URL(fileURLWithPath: executable)
        mux.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-i", raw.path, "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=\(sampleRate)",
            "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac",
            "-ar", String(sampleRate), "-ac", String(channels),
            "-t", String(Double(frames) / 24 + audioTail), "-movflags", "+faststart", url.path]
        mux.standardOutput = FileHandle.nullDevice; mux.standardError = FileHandle.nullDevice
        try mux.run(); mux.waitUntilExit()
        guard mux.terminationStatus == 0 else { throw AVFixtureError("Audio-tail mux failed") }
        return
    }
    if audioOffset != 0 || videoOffset != 0 {
        let raw = url.deletingPathExtension().appendingPathExtension("unaltered.mp4")
        try writeAVFixture(to: raw, frames: frames, sampleRate: sampleRate, channels: channels,
                           audioTracks: audioTracks, dropVideoFrame: dropVideoFrame)
        let offset = audioOffset != 0 ? audioOffset : videoOffset
        let shift = Process()
        shift.executableURL = URL(fileURLWithPath: executable)
        // A pure remux preserves real shifted timestamps. The former lavfi
        // offset was filled with silence by FFmpeg and did not create this case.
        shift.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-copyts",
                           "-itsoffset", String(offset), "-i", raw.path, "-i", raw.path,
                           "-map", audioOffset != 0 ? "1:v" : "0:v",
                           "-map", audioOffset != 0 ? "0:a" : "1:a", "-c", "copy", url.path]
        shift.standardOutput = FileHandle.nullDevice; shift.standardError = FileHandle.nullDevice
        try shift.run(); shift.waitUntilExit()
        guard shift.terminationStatus == 0 else { throw AVFixtureError("Shifted remux failed") }
        return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=24",
        "-f", "lavfi"]
    if audioOffset != 0 { arguments += ["-itsoffset", String(audioOffset)] }
    arguments += ["-i", "sine=frequency=440:sample_rate=\(sampleRate)",
        "-map", "0:v"]
    for _ in 0..<audioTracks { arguments += ["-map", "1:a"] }
    var filters = [String]()
    if videoOffset != 0 { filters.append("setpts=PTS+\(videoOffset)/TB") }
    if let dropVideoFrame { filters.append("select=not(eq(n\\,\(dropVideoFrame)))") }
    if !filters.isEmpty { arguments += ["-vf", filters.joined(separator: ",")] }
    if dropVideoFrame != nil { arguments += ["-fps_mode", "passthrough"] }
    arguments += ["-c:v", "libx264", "-preset", "medium", "-bf", "2",
        "-g", String(frames), "-sc_threshold", "0", "-pix_fmt", "yuv420p",
        "-threads", "1", "-frames:v", String(frames - (dropVideoFrame == nil ? 0 : 1)),
        "-t", String(Double(frames) / 24 + audioTail), "-movflags", "+faststart"]
    if audioTracks > 0 {
        arguments += ["-c:a", "aac", "-ar", String(sampleRate), "-ac", String(channels),
                      "-b:a", "96k"]
    }
    arguments += [url.path]
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw AVFixtureError("FFmpeg 合成夹具失败：\(process.terminationStatus)")
    }
}

private func hasReorderedH264Samples(_ url: URL) async throws -> Bool {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { return false }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    guard reader.startReading() else { return false }
    var reordered = false
    while let sample = output.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        if dts.isNumeric && CMTimeCompare(pts, dts) != 0 { reordered = true }
    }
    return reader.status == .completed && reordered
}

private func compressedVideoSampleSummary(_ url: URL) async throws -> (frames: Int, emptyMarkers: Int) {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { throw AVFixtureError("夹具没有视频轨") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    guard reader.startReading() else { throw AVFixtureError("无法读取夹具压缩样本") }
    var frames = 0, emptyMarkers = 0
    while let sample = output.copyNextSampleBuffer() {
        let count = CMSampleBufferGetNumSamples(sample)
        if count == 0 { emptyMarkers += 1 }
        else { frames += count }
    }
    guard reader.status == .completed else { throw AVFixtureError("夹具压缩样本读取未完成") }
    return (frames, emptyMarkers)
}

/// Change only mvhd.duration; all track headers, sample tables and media stay byte identical.
private func changeOnlyMovieDuration(_ original: Data, additionalSeconds: Double) throws -> Data {
    var bytes = original
    let moov = try avFixtureBox(named: "moov", in: bytes, range: 0..<bytes.count)
    let mvhd = try avFixtureBox(named: "mvhd", in: bytes,
                               range: (moov.lowerBound + 8)..<moov.upperBound)
    guard mvhd.count >= 40 else { throw AVFixtureError("mvhd 过短") }
    let version = bytes[mvhd.lowerBound + 8]
    guard version == 0 || version == 1 else { throw AVFixtureError("mvhd 版本不支持") }
    let timescaleOffset = mvhd.lowerBound + (version == 0 ? 20 : 28)
    let durationOffset = mvhd.lowerBound + (version == 0 ? 24 : 32)
    let durationWidth = version == 0 ? 4 : 8
    guard durationOffset + durationWidth <= mvhd.upperBound else {
        throw AVFixtureError("mvhd 时长字段被截断")
    }
    let timescale = avFixtureBigEndian(bytes, offset: timescaleOffset, count: 4)
    let oldDuration = avFixtureBigEndian(bytes, offset: durationOffset, count: durationWidth)
    let delta = UInt64((Double(timescale) * additionalSeconds).rounded())
    guard timescale > 0, delta > 0, oldDuration <= UInt64.max - delta,
          durationWidth == 8 || oldDuration + delta <= UInt64(UInt32.max) else {
        throw AVFixtureError("mvhd 时长修改无效")
    }
    let newDuration = oldDuration + delta
    for offset in 0..<durationWidth {
        bytes[durationOffset + offset] = UInt8(truncatingIfNeeded:
            newDuration >> (8 * (durationWidth - offset - 1)))
    }
    return bytes
}

private func avFixtureBox(named name: String, in bytes: Data, range: Range<Int>) throws -> Range<Int> {
    var offset = range.lowerBound
    while offset + 8 <= range.upperBound {
        let size = avFixtureBigEndian(bytes, offset: offset, count: 4)
        guard size >= 8, size <= UInt64(range.upperBound - offset) else {
            throw AVFixtureError("MP4 夹具数据块长度无效")
        }
        let end = offset + Int(size)
        let type = String(data: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)
        if type == name { return offset..<end }
        offset = end
    }
    throw AVFixtureError("MP4 夹具缺少 \(name)")
}

private func avFixtureBigEndian(_ bytes: Data, offset: Int, count: Int) -> UInt64 {
    (0..<count).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[offset + $1]) }
}

private struct AVFixtureError: Error { let message: String; init(_ message: String) { self.message = message } }

private final class AVInspectionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false
    private var count = 0

    func reach(_ point: VideoInspectionTestCheckpoint) {
        condition.lock()
        if point == .audioDecodedSampleRead {
            count += 1
            if !blocked {
                blocked = true
                condition.broadcast()
                while !released { condition.wait() }
            }
        }
        condition.unlock()
    }

    func waitUntilBlocked() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let end = Date().addingTimeInterval(5)
        while !blocked, condition.wait(until: end) {}
        return blocked
    }

    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }

    var reachCount: Int {
        condition.lock(); defer { condition.unlock() }; return count
    }
}
