import DInference
import DMLXBackend
import DWorkbench
import Foundation
import ImageIO
import Testing
@testable import D

/// Opt-in tests use the same Quick controller and production runtime. They are not GUI evidence.
@Suite(.serialized) @MainActor
struct QuickGenerationRealTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_BASELINE02_REAL_KIND"] != nil), .timeLimit(.minutes(20)))
    func productionQuickCallPreservesDraftAndReopens() async throws {
        let env = ProcessInfo.processInfo.environment
        let rawKind = try #require(env["D_BASELINE02_REAL_KIND"])
        let kind = try #require(WorkflowModelKind(rawValue: rawKind))
        try #require([WorkflowModelKind.text, .image, .music, .video].contains(kind))
        let modelURL = URL(fileURLWithPath: try #require(env["D_BASELINE02_REAL_MODEL"]))
        let sessionID = try #require(env["D_UI_TEST_SESSION"].flatMap(UUID.init(uuidString:)))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("D/Baseline02/" + sessionID.uuidString)
        let access = root.appendingPathComponent("Access")
        try FileManager.default.createDirectory(at: access, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let projectURL = root.appendingPathComponent("Quick.dproject")
        let store = try await ProjectStore.create(at: projectURL, name: "Quick real " + kind.rawValue)
        let suite = "D.Baseline02.Real." + sessionID.uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let resources = try #require(Bundle.main.resourceURL)
        let musicEngine = kind == .music ? try BundledAudioEngine.resolve(resourceDirectory: resources, family: .mrt2Music) : nil
        let videoEngine = kind == .video ? try BundledAudioEngine.resolve(resourceDirectory: resources, family: .video) : nil
        if kind == .music {
            try #require(env["D_NODE_LANGUAGE_MUSIC_ACKNOWLEDGED"] == "1")
            let authorization = try #require(env["D_NODE_LANGUAGE_MUSIC_AUTHORIZATION_SOURCE"])
            try #require(FileManager.default.isReadableFile(atPath: authorization))
            settings.set(true, forKey: "audio.model-use.mrt2-small." + MRT2BackendConfiguration.registeredModelRevision)
        }
        let session = try await AppSessionFactory.makeSession(artifactDirectory: store.artifactDirectory,
            bundledMusicEngine: musicEngine, musicConsent: AudioModelUsePermission(settings: settings, model: .mrt2Music),
            audioAccessRoot: access, bundledVideoEngine: videoEngine, videoAccessRoot: access)
        let start = Date()
        do {
            let reference: ModelReference
            let backend: String
            let operation: String
            switch kind {
            case .text:
                reference = try await #require(session.validateTextModel)(modelURL)
                backend = try #require(session.textBackendID); operation = "d.model.language"
            case .image:
                try await session.validateModel(modelURL)
                reference = ModelReference(directory: modelURL, revision: "ef52ee019fd1d0e75ae4deb40476ba65989716d7")
                backend = session.backendID; operation = "d.image.generate"
            case .music:
                reference = try await #require(session.validateMusicModel)(modelURL)
                backend = try #require(session.musicBackendID); operation = "d.music.generate"
            case .video:
                reference = try await #require(session.validateVideoModel)(modelURL)
                backend = try #require(session.videoBackendID); operation = "d.video.generate"
            default: throw WorkflowIssue("Unsupported test kind")
            }
            let identity = kind.rawValue + ":" + (reference.revision ?? "unknown")
            func services() -> WorkflowServices {
                WorkflowServices(store: store, session: session, resolveModel: { requested, selected in
                    guard requested == kind, selected == identity else { throw WorkflowIssue("Unexpected model binding") }
                    return .init(identity: identity, reference: reference, backendID: backend)
                })
            }
            let quick = QuickGenerationController(store: store, makeServices: services)
            await quick.load(); quick.select(operationID: operation, modelID: identity)
            let draftID = try #require(quick.draft?.id)
            func set(_ key: String, _ value: WorkflowScalar) { quick.setParameter(key, value: value, draftID: draftID) }
            if kind == .text {
                set("task", .text("Describe a small red teapot on a wooden table in one short English sentence."))
                set("maximumOutputTokens", .integer(48)); set("temperature", .decimal(0))
            } else {
                set("promptText", .text(kind == .music ? "Gentle solo piano, clear individual notes, no percussion." : "A small red teapot on a wooden table, fixed camera, soft light."))
                set("seed", .text("42"))
            }
            if kind == .image { set("width", .integer(512)); set("height", .integer(512)); set("steps", .integer(4)) }
            if kind == .music { set("durationFrames", .integer(100)) }
            if kind == .video {
                set("width", .integer(320)); set("height", .integer(192)); set("steps", .integer(4))
                set("frameCount", .integer(17)); set("frameRate", .integer(16)); set("memoryBudgetGiB", .integer(14))
            }
            let frozen = try #require(quick.draft)
            try #require(quick.canStart)
            quick.start()
            // An immediate selection change must not cancel or move this real request.
            quick.select(operationID: "d.model.language", modelID: "text:unprepared-next-draft")
            await quick.waitForCompletion()
            let run = try #require(quick.state.runs.last)
            try #require(run.status == .completed, Comment(rawValue: run.issue ?? quick.error ?? "incomplete"))
            #expect(run.draft == frozen)
            #expect(quick.visibleRuns.isEmpty)
            let refs = run.outputs.values.compactMap(\.asset) + run.outputs.values.flatMap { $0.candidates.compactMap(\.asset) }
            try #require(!refs.isEmpty)
            for ref in refs {
                let bytes = try await store.workflowData(ref); try #require(!bytes.isEmpty)
                if ref.kind == .image {
                    let image = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
                    try #require(CGImageSourceCreateImageAtIndex(image, 0, nil) != nil)
                }
                if [.audio, .video].contains(ref.kind) { _ = try await store.workflowMedia(ref) }
            }
            if kind == .text { try #require(run.outputs["output"]?.datum?.text?.isEmpty == false) }
            #expect(await session.status().activeRunID == nil)
            #expect(await session.status().queuedRunIDs.isEmpty)
            quick.select(operationID: operation, modelID: identity)
            #expect(quick.draft == frozen)
            let canvas = WorkflowController(services: services()); await canvas.load(); canvas.addBlankGraph()
            try await canvas.insertQuickResult(refs[0], target: try #require(canvas.canvasInsertionTarget()))
            #expect(canvas.runs.isEmpty)
            let exported = try await store.exportWorkflowAssets([refs[0]], name: "Quick-result", exportID: UUID(), directory: root)
            try await quick.prepareForTermination(); try await canvas.close()
            let expected = quick.state
            try await store.close(); await session.shutdown(); try await session.cleanup()
            let reopened = try await ProjectStore.open(at: projectURL)
            #expect(try await reopened.quickCreationState() == expected)
            try await reopened.close()
            let report: [String: Any] = ["kind": kind.rawValue, "model": identity, "backend": backend,
                "run": run.id.uuidString, "project": projectURL.path, "elapsedSeconds": Date().timeIntervalSince(start),
                "assets": refs.map { ["id": $0.assetID.uuidString, "sha256": $0.sha256, "kind": $0.kind.rawValue] },
                "export": String(describing: exported), "guiValidated": false, "driver": "QuickGenerationController / production AppSessionFactory"]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("quick-result.json"), options: .withoutOverwriting)
            print("D_BASELINE02_REAL_PASS=\(root.path)")
        } catch {
            await session.shutdown()
            try? await store.close()
            throw error
        }
    }
}
