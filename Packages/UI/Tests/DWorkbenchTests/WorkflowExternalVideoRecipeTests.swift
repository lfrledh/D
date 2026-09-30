import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("External video node recipes")
struct WorkflowExternalVideoRecipeTests {
    @Test func registeredNodesFreezeDistinctProfilesAndStreamingDoesNotChangeNumerics() throws {
        let registry = WorkflowRegistry.standard
        var identities = Set<String>()
        for profile in ExternalVideoExecutionProfile.allCases {
            let recipe = WorkflowVideoRecipe(profile: profile)
            let definition = try #require(registry.operation(recipe.operationID)?.definition)
            var node = definition.makeNode()
            try registry.validate(node)
            let prompt = "原文 👩🏽‍🎨 e\u{301} — unchanged"
            let streamed = try recipe.request(node: node, prompt: prompt, seed: 42)
            node.parameters["streamWeights"] = .flag(false)
            let resident = try recipe.request(node: node, prompt: prompt, seed: 42)
            #expect(streamed.prompt == prompt && resident.prompt == prompt)
            #expect(streamed.executionProfile == profile.reference)
            #expect(resident.executionProfile == profile.reference)
            #expect(streamed.width == resident.width && streamed.height == resident.height)
            #expect(streamed.frameCount == resident.frameCount && streamed.steps == resident.steps)
            #expect(streamed.seed == resident.seed && streamed.guidanceScale == resident.guidanceScale)
            #expect(streamed.frameRate == resident.frameRate)
            if profile == .h3BF16Full {
                #expect(streamed.adapterOptions == .h3(streamWeights: true))
                #expect(resident.adapterOptions == .h3(streamWeights: false))
            } else {
                #expect(streamed.adapterOptions == .ltx(streamWeights: true, spatiotemporalGuidance: 0))
                #expect(resident.adapterOptions == .ltx(streamWeights: false, spatiotemporalGuidance: 0))
            }
            #expect(identities.insert(profile.modelIdentity).inserted)
            #expect(definition.fields.contains { $0.id == "streamWeights" })
            #expect(definition.outputs.map(\.kinds) == [[.video]])
        }
    }

    @Test func invalidAndMissingParametersNeverSubstituteDefaults() throws {
        let registry = WorkflowRegistry.standard
        for profile in ExternalVideoExecutionProfile.allCases {
            let recipe = WorkflowVideoRecipe(profile: profile)
            let definition = try #require(registry.operation(recipe.operationID)?.definition)
            var node = definition.makeNode()
            node.parameters["streamWeights"] = nil
            #expect(throws: (any Error).self) { try recipe.request(node: node, prompt: "p", seed: 42) }
            node = definition.makeNode()
            node.parameters["width"] = .integer(257)
            #expect(throws: (any Error).self) { try registry.validate(node) }
            node = definition.makeNode()
            node.parameters["frameCount"] = .integer(2)
            #expect(throws: (any Error).self) { try registry.validate(node) }
        }
    }

    @Test @MainActor func legacyWanBindingRemainsWithoutAnExternalRecipe() throws {
        let binding = WorkflowModelBinding(identity: "video:wan-fixture",
            reference: .init(directory: URL(fileURLWithPath: "/fixture-only/wan")), backendID: "fixture.wan")
        #expect(binding.videoRecipe == nil)
        let old = try #require(WorkflowRegistry.standard.operation("d.video.generate")?.definition).makeNode()
        #expect(old.parameters["streamWeights"] == nil)
        try WorkflowRegistry.standard.validate(old)
    }
}

private enum VideoAdmissionProbeFailure: Error { case stoppedBeforeModel }
private actor VideoAdmissionProbe: InferenceEngine {
    private(set) var calls: [(InferenceRequest, String)] = []
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls.append((request, backendID))
        throw VideoAdmissionProbeFailure.stoppedBeforeModel
    }
}

/// Real application service/lease wiring with a non-computing engine boundary.
/// Registration/reopen covers ProjectSession bookmarks with an isolated suite;
/// it does not claim real inference or native GUI.
@Suite("External video application service boundary", .serialized) @MainActor
struct WorkflowExternalVideoServicesTests {
    @Test func projectRegistrationRestoresExplicitModelAfterReopen() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]!)
            .appendingPathComponent("video-registration-" + UUID().uuidString)
        let pack = base.appendingPathComponent("已登记模型")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let profile = ExternalVideoExecutionProfile.ltx23Q8GemmaQ4
        try JSONEncoder().encode(ExternalVideoModelManifest(profile: profile))
            .write(to: pack.appendingPathComponent(ExternalVideoModelManifest.filename), options: .withoutOverwriting)
        let suite = "D.VideoRegistration." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let engine = VideoAdmissionProbe()
        let owner = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "unused.image",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in },
                videoAdapters: ExternalVideoExecutionProfile.allCases.map { selected in
                    .init(profile: selected, validateModel: { url in
                        let manifest = try JSONDecoder().decode(ExternalVideoModelManifest.self,
                            from: Data(contentsOf: url.appendingPathComponent(ExternalVideoModelManifest.filename)))
                        try manifest.validate()
                        guard manifest.profile == selected else { throw VideoAdmissionProbeFailure.stoppedBeforeModel }
                        return .init(directory: url, revision: selected.modelIdentity)
                    })
                })
        }, settings: settings)
        let project = base.appendingPathComponent("test.dproject")
        await owner.createProject(at: project)
        let choice = try await owner.registerExplicitModel(at: pack, kind: .video)
        #expect(choice.id == "video:" + profile.modelIdentity)
        #expect(choice.displayName == "LTX 2.3 dev · Q8 / Gemma Q4")
        await owner.openWorkflow()
        let controller = try #require(owner.workflow)
        controller.addNode(operationID: WorkflowVideoRecipe(profile: profile).operationID)
        let nodeID = try #require(controller.selectedNodeID)
        controller.setParameter(nodeID: nodeID, key: "modelID", value: .text(choice.id))
        await controller.run(target: nodeID, only: true)
        #expect(await engine.calls.count == 1)
        let closed = await owner.requestClose()
        try #require(closed)
        #expect(owner.workflow == nil && owner.currentStore == nil && owner.manifest == nil)
        try WorkflowModelBookmarks(settings: settings).remember(identity: choice.id, kind: .video,
            name: "old-random-pack-directory", bookmark: try #require(WorkflowModelBookmarks(settings: settings).entries().first(where: { $0.identity == choice.id })?.bookmark))
        await owner.openProject(at: project)
        await owner.openWorkflow()
        #expect(owner.explicitModelChoices.first(where: { $0.id == choice.id })?.displayName == "LTX 2.3 dev · Q8 / Gemma Q4")
        let reopened = try #require(owner.workflow)
        #expect(reopened !== controller)
        #expect(reopened.graph?.nodes.first(where: { $0.id == nodeID })?.parameters["modelID"] == .text(choice.id))
        await reopened.run(target: nodeID, only: true)
        let calls = await engine.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.1 == profile.backendID && $0.0.model.revision == profile.modelIdentity })
        for (index, call) in calls.enumerated() {
            print("D_VIDEO_REGISTRATION cycle=\(index) actual=\(call.0.model.directory.absoluteString) expected=\(pack.absoluteString)")
            // A restored directory bookmark includes a trailing slash. Compare
            // the complete physical path and inode, not URL spelling.
            let actual = call.0.model.directory.standardizedFileURL.resolvingSymlinksInPath()
            let expected = pack.standardizedFileURL.resolvingSymlinksInPath()
            #expect(actual.path == expected.path)
            let actualFile = try FileManager.default.attributesOfItem(atPath: actual.path)
            let expectedFile = try FileManager.default.attributesOfItem(atPath: expected.path)
            #expect(actualFile[.type] as? FileAttributeType == .typeDirectory)
            #expect(actualFile[.systemNumber] as? NSNumber == expectedFile[.systemNumber] as? NSNumber)
            #expect(actualFile[.systemFileNumber] as? NSNumber == expectedFile[.systemFileNumber] as? NSNumber)
        }
        #expect(await owner.requestClose())
    }
    @Test func cancelledRegistrationAfterFirstMatchDoesNotPersistBookmarkOrChoice() async throws {
        let base = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("cancel-video-registration-" + UUID().uuidString)
        let pack = base.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try JSONEncoder().encode(ExternalVideoModelManifest(profile: .h3BF16Full))
            .write(to: pack.appendingPathComponent(ExternalVideoModelManifest.filename), options: .withoutOverwriting)
        let suite = "D.CancelVideoRegistration." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let engine = VideoAdmissionProbe()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let owner = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "unused.image",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in },
                videoAdapters: [
                    .init(profile: .h3BF16Full, validateModel: { url in .init(directory: url, revision: ExternalVideoExecutionProfile.h3BF16Full.modelIdentity) }),
                    .init(profile: .ltx25BF16Full, validateModel: { _ in
                        signal.yield(())
                        try await Task.sleep(for: .seconds(5))
                        throw VideoAdmissionProbeFailure.stoppedBeforeModel
                    })])
        }, settings: settings)
        await owner.createProject(at: base.appendingPathComponent("test.dproject"))
        let registration = Task { @MainActor in
            defer { signal.finish() }
            return try await owner.registerExplicitModel(at: pack, kind: .video)
        }
        var iterator = entered.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        registration.cancel()
        await #expect(throws: CancellationError.self) { try await registration.value }
        #expect(try WorkflowModelBookmarks(settings: settings).entries().isEmpty)
        #expect(owner.explicitModelChoices.isEmpty)
        #expect(await engine.calls.isEmpty)
        #expect(await owner.requestClose())
    }
    @Test func mismatchedRecipeSubmitsNothingAndReleasesInstallation() async throws {
        try await checkBinding(mismatch: true)
    }
    @Test func frozenStreamingRequestUsesSelectedBackendAndFailureProtectsProject() async throws {
        try await checkBinding(mismatch: false)
    }
    private func checkBinding(mismatch: Bool) async throws {
        let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]!)
            .appendingPathComponent("video-service-" + UUID().uuidString + ".dproject")
        let store = try await ProjectStore.create(at: path, name: "Video service fixture")
        let before = await store.snapshot()
        let engine = VideoAdmissionProbe()
        let session = WorkbenchSession(engine: engine, backendID: "unrelated.image",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let selected = ExternalVideoExecutionProfile.ltx23Q8GemmaQ4
        let recipe = WorkflowVideoRecipe(profile: mismatch ? .h3BF16Full : selected)
        var acquired = 0, released = 0
        let service = WorkflowServices(store: store, session: session) { kind, identity in
            #expect(kind == .video && identity == "video:" + selected.modelIdentity)
            acquired += 1
            return .init(identity: identity, reference: .init(directory: path, revision: selected.modelIdentity),
                backendID: selected.backendID, videoRecipe: recipe, release: { released += 1 })
        }
        let definition = try #require(WorkflowRegistry.standard.operation(WorkflowVideoRecipe(profile: selected).operationID)?.definition)
        for stream in [true, false] {
            var node = definition.makeNode()
            node.parameters["modelID"] = .text("video:" + selected.modelIdentity)
            node.parameters["streamWeights"] = .flag(stream)
            node.parameters["promptText"] = .text("冻结原文 👩🏽‍🎨")
            try service.beginPlan()
            do {
                _ = try await service.executeCall(.init(node: node, stepID: UUID(), inputs: [:]))
                Issue.record("Expected explicit rejection or stopped CPU probe")
            } catch {
                if mismatch { #expect(error is WorkflowIssue) }
                else { #expect(error is VideoAdmissionProbeFailure) }
            }
        }
        #expect(acquired == 2 && released == 2)
        let calls = await engine.calls
        if mismatch { #expect(calls.isEmpty) }
        else {
            #expect(calls.count == 2)
            for (index, call) in calls.enumerated() {
                #expect(call.1 == selected.backendID)
                guard case .video(let request) = call.0.input else { Issue.record("Not video"); continue }
                #expect(request.executionProfile == selected.reference)
                #expect(request.prompt == "冻结原文 👩🏽‍🎨")
                #expect(request.adapterOptions == .ltx(streamWeights: index == 0, spatiotemporalGuidance: 0))
            }
        }
        let after = await store.snapshot()
        #expect(after.draft == before.draft && after.assets == before.assets)
        #expect(!service.hasPendingSaves)
        try await store.close()
    }
}
