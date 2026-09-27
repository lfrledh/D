import DInference
import DMLXBackend
import DWorkbench
import Foundation
import Testing
@testable import D

/// Opt-in production-node checks. No GUI or listening conclusion follows from these tests.
@Suite(.serialized) @MainActor
struct NodeQualityRealTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NODE_QUALITY_REAL"] == "video"), .timeLimit(.minutes(30)))
    func sameInputFourAndFiftyStepVideo() async throws { try await run(kind: .video) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NODE_QUALITY_REAL"] == "music"), .timeLimit(.minutes(15)))
    func musicWithoutNotesIsUnconstrainedAndPersists() async throws { try await run(kind: .music) }

    private func run(kind: WorkflowModelKind) async throws {
        let env = ProcessInfo.processInfo.environment
        let sessionID = try #require(env["D_UI_TEST_SESSION"].flatMap(UUID.init(uuidString:)))
        let modelURL = URL(fileURLWithPath: try #require(env["D_NODE_QUALITY_MODEL"]))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("D/NodeQuality/" + UUID().uuidString)
        let access = root.appendingPathComponent("Access")
        try FileManager.default.createDirectory(at: access, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let project = root.appendingPathComponent("Quality.dproject")
        print("D_NODE_QUALITY_ROOT=\(root.path)")
        let resources = try #require(Bundle.main.resourceURL)
        let engine = try #require(try BundledAudioEngine.resolve(resourceDirectory: resources,
                                   family: kind == .video ? .video : .mrt2Music))
        let suite = "D.NodeQuality." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        if kind == .music {
            try #require(env["D_NODE_LANGUAGE_MUSIC_ACKNOWLEDGED"] == "1")
            let source = try #require(env["D_NODE_LANGUAGE_MUSIC_AUTHORIZATION_SOURCE"])
            try #require(FileManager.default.isReadableFile(atPath: source))
            // Reflect only the existing same-model development authorization in this test suite.
            settings.set(true, forKey: "audio.model-use.mrt2-small." + MRT2BackendConfiguration.registeredModelRevision)
        }
        let store = try await ProjectStore.create(at: project, name: "Quality checks")
        var runtime: WorkbenchSession?
        var controller: WorkflowController?
        do {
            let session = try await AppSessionFactory.makeSession(artifactDirectory: store.artifactDirectory,
                bundledMusicEngine: kind == .music ? engine : nil,
                musicConsent: AudioModelUsePermission(settings: settings, model: .mrt2Music),
                audioAccessRoot: kind == .music ? access : nil,
                bundledVideoEngine: kind == .video ? engine : nil,
                videoAccessRoot: kind == .video ? access : nil)
            runtime = session
            let reference: ModelReference
            let backend: String
            if kind == .video {
                let validate = try #require(session.validateVideoModel)
                reference = try await validate(modelURL)
                backend = try #require(session.videoBackendID)
            } else {
                let validate = try #require(session.validateMusicModel)
                reference = try await validate(modelURL)
                backend = try #require(session.musicBackendID)
            }
            let identity = kind.rawValue + ":" + (reference.revision ?? "unknown")
            var node = try #require(WorkflowRegistry.standard.operation(kind == .video ? "d.video.generate" : "d.music.generate")).definition.makeNode()
            node.parameters["modelID"] = .text(identity)
            if kind == .video {
                node.parameters["promptText"] = .text("A small red toy car slowly rolling across a wooden desk, fixed camera, natural daylight, simple background.")
                node.parameters["negativePrompt"] = .text("blurry, overexposed, distorted, low quality, watermark")
                node.parameters["width"] = .integer(320); node.parameters["height"] = .integer(192)
                node.parameters["frameCount"] = .integer(17); node.parameters["frameRate"] = .integer(16)
                node.parameters["guidance"] = .decimal(6); node.parameters["scheduleShift"] = .decimal(8)
                node.parameters["memoryBudgetGiB"] = .integer(14)
            } else {
                node.parameters["promptText"] = .text("Gentle solo piano, clear individual notes, no percussion.")
                node.parameters["durationFrames"] = .integer(100)
            }
            node.parameters["seed"] = .text("42")
            let initial = try #require(try await store.workflowState().archive)
            _ = try await store.saveWorkflow(graphs: [.init(name: "Standalone model capability", nodes: [node])],
                                             runs: [], expectedRevision: initial.revision)
            let services = WorkflowServices(store: store, session: session, defaultIdentity: { _ in identity }, resolveModel: { requested, selected in
                guard requested == kind, selected == identity else { throw WorkflowIssue("Unexpected model binding") }
                return .init(identity: identity, reference: reference, backendID: backend)
            })
            let subject = WorkflowController(services: services); controller = subject
            await subject.load()
            var reports: [[String: Any]] = []
            let settingsSteps = kind == .video ? [4, 50] : [0]
            for steps in settingsSteps {
                if kind == .video { subject.setParameter(nodeID: node.id, key: "steps", value: .integer(steps)) }
                let start = Date()
                await subject.run(target: node.id, only: false)
                try #require(subject.errorMessage == nil, Comment(rawValue: subject.errorMessage ?? "run failed"))
                let run = try #require(subject.runs.last)
                try #require(run.status == .completed)
                let call = try #require(run.planCheckpoint?.records.first { $0.step.node.id == node.id && $0.step.status == .completed })
                try #require(call.step.inputs.isEmpty)
                let ref = try #require(call.step.outputs["output"]?.asset)
                await subject.save()
                try #require(subject.errorMessage == nil && !subject.hasPendingSaves)
                let archive = try #require(try await store.workflowState().archive)
                let record = try #require(archive.assets.first { $0.reference == ref })
                let request = try #require(record.request)
                try #require(request.model == reference && record.parents.isEmpty && request.id == call.step.id)
                let media = try await store.workflowMedia(ref)
                if kind == .video {
                    guard case .video(let input) = request.input else { throw WorkflowIssue("Wrong video request") }
                    let expected = VideoRequest(
                        prompt: "A small red toy car slowly rolling across a wooden desk, fixed camera, natural daylight, simple background.",
                        negativePrompt: "blurry, overexposed, distorted, low quality, watermark",
                        width: 320, height: 192, frameCount: 17, frameRate: .init(numerator: 16), steps: steps,
                        guidanceScale: 6, scheduleShift: 8, seed: 42,
                        executionProfile: try #require(session.videoCapability).profile)
                    try #require(input == expected && request.memoryBudgetBytes == 14 * 1_024 * 1_024 * 1_024)
                    let inspected = try await VideoMediaInspector.inspect(at: media.0, expected: input)
                    try #require(inspected.frameCount == 17 && inspected.byteCount > 0)
                } else {
                    guard case .audio(let input) = request.input else { throw WorkflowIssue("Wrong music request") }
                    let sequence = try #require(input.noteSequence)
                    try #require(sequence.notes == nil && sequence.durationFrames == 100 && input.seed == 42)
                    let inspected = try AudioMediaInspector.inspect(at: media.0, policy: .generated)
                    try #require(inspected.format.sampleRate == 48_000 && inspected.format.channelCount == 2 && inspected.format.frameCount == 192_000)
                }
                let status = await session.status()
                try #require(status.activeRunID == nil && status.queuedRunIDs.isEmpty)
                reports.append(["steps": steps, "elapsedSeconds": Date().timeIntervalSince(start),
                    "media": media.0.path, "runID": run.id.uuidString,
                    "record": try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))])
            }
            try await subject.close()
            let saved = try #require(try await store.workflowState().archive)
            let expectedCount = kind == .video ? 2 : 1
            try #require(saved.runs.count == expectedCount && saved.assets.count == expectedCount)
            try #require(Set(saved.assets.map { $0.reference.assetID }).count == expectedCount)
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            try #require(try await reopened.workflowState().archive == saved)
            for asset in saved.assets { _ = try await reopened.workflowData(asset.reference) }
            try await reopened.close()
            await session.shutdown(); runtime = nil
            let report: [String: Any] = ["kind": kind.rawValue, "project": project.path, "reports": reports,
                "backend": backend, "revision": reference.revision ?? "unknown", "gui": false, "listening": false,
                "hostSession": sessionID.uuidString,
                "authorizationSource": env["D_NODE_LANGUAGE_MUSIC_AUTHORIZATION_SOURCE"] ?? "not_applicable"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("quality-result.json"), options: .withoutOverwriting)
            print("D_NODE_QUALITY_PASS=\(root.path)")
        } catch {
            if let controller { await controller.cancel(); try? await controller.close() }
            if let runtime { await runtime.shutdown() }
            try? await store.close(preserveExternalChanges: true)
            throw error
        }
    }
}
