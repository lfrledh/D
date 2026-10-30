import Foundation
import DInference
import Testing
@testable import DWorkbench

@Suite("VLM shared form and response closeout")
struct WorkflowLanguageCloseoutTests {
    @Test func layeredSupportUsesExactProfileAndPreservesSavedChoice() throws {
        let profiles = try TextModelProfiles.registeredVLM()
        #expect(profiles.contains { $0.quantizationBits == 4 })
        #expect(profiles.contains { $0.quantizationBits == 0 })
        for profile in profiles {
            let identity = "text:" + profile.revision
            #expect(!WorkflowModelRoutes.rejectsTextLoading(modelIdentity: identity, strategy: "ssdLayered"))
            #expect(!WorkflowModelRoutes.rejectsTextLoading(modelIdentity: identity, strategy: "resident"))
        }
        #expect(!WorkflowModelRoutes.rejectsTextLoading(modelIdentity: "Qwen3.5-9B-4bit", strategy: "ssdLayered"))
        #expect(!WorkflowModelRoutes.rejectsTextLoading(modelIdentity: nil, strategy: "ssdLayered"))
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:" + (try #require(profiles.first { $0.quantizationBits == 4 })).revision)
        node.parameters["loadingStrategy"] = .text("ssdLayered")
        let before = node
        #expect(!WorkflowModelRoutes.rejectsTextLoading(modelIdentity: node.parameters["modelID"]?.string, strategy: node.parameters["loadingStrategy"]?.string ?? ""))
        #expect(node == before)
        // Rendering preserves old selections. The backend still validates exact packed files.
        #expect(try WorkflowLanguageMessageForm.loadingStrategy(node.parameters) == .ssdLayered)
    }

    @Test func orderedMediaAndRoleFormPreservesMeaningAndRejectsUnusedInputs() throws {
        let image = TextImageReference(url: URL(fileURLWithPath: "/fixture/a.png"), width: 1, height: 1,
                                      byteCount: 3, contentSHA256: String(repeating: "a", count: 64))
        let json = #"[{"role":"system","parts":[{"type":"text","text":"Keep roles"}]},{"role":"user","parts":[{"type":"text","text":"before"},{"type":"image","index":0},{"type":"text","text":"after"}]}]"#
        let parsed = try WorkflowLanguageMessageForm.messages(json, images: [image], videos: [])
        let messages = try #require(parsed)
        #expect(messages.map(\.role) == [.system, .user])
        #expect(messages[1].parts == [.text("before"), .image(image), .text("after")])
        #expect(throws: (any Error).self) { try WorkflowLanguageMessageForm.messages(json, images: [], videos: []) }
        #expect(throws: (any Error).self) { try WorkflowLanguageMessageForm.messages(#"[{"role":"user","parts":[{"type":"text","text":"missing"}]}]"#, images: [image], videos: []) }
        #expect(throws: (any Error).self) { try WorkflowLanguageMessageForm.messages(#"[{"role":"user","content":"silently lost","parts":[{"type":"text","text":"known"}]}]"#, images: [], videos: []) }
    }
    @Test func optionalFormsDoNotMutateOldNodeAndSeedIsLossless() throws {
        let registry = WorkflowRegistry.standard
        var node = try #require(registry.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        for key in WorkflowLanguageMessageForm.optionalFields { node.parameters.removeValue(forKey: key) }
        let before = node
        try registry.validate(node)
        #expect(node == before)
        #expect(try WorkflowLanguageMessageForm.seed(["seed": .text(String(UInt64.max))]) == UInt64.max)
        #expect(throws: (any Error).self) { try WorkflowLanguageMessageForm.seed(["seed": .text("1e3")]) }
        #expect(try WorkflowLanguageMessageForm.thinking([:]) == nil)
        #expect(try WorkflowLanguageMessageForm.thinking(["thinking": .text("off")])?.enableThinking == false)
    }
    @Test @MainActor func explicitDirectoryReplacesOnlyItsInstallationBinding() throws {
        let suite = "D-closeout-model-binding-" + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let store = WorkflowModelBookmarks(settings: settings)
        let first = ModelID(rawValue: UUID()), second = ModelID(rawValue: UUID())
        try store.rememberInstallation(identity: "image:first", id: first)
        try store.rememberInstallation(identity: "text:second", id: second)
        try store.remember(identity: "image:first", kind: .image, name: "Explicit", bookmark: Data([1, 2, 3]))
        #expect(try store.installation(for: "image:first") == nil)
        #expect(try store.installation(for: "text:second") == second)
        #expect(try WorkflowModelBookmarks(settings: settings).entries().first?.name == "Explicit")
    }
}

private actor CloseoutResponseEngine: InferenceEngine {
    var response: TextResponse
    var calls = 0
    var requests: [InferenceRequest] = []
    var action: (@Sendable () async throws -> Void)?
    init(_ response: TextResponse) { self.response = response }
    func replaceResponse(_ value: TextResponse) { response = value }
    func beforeReturn(_ value: @escaping @Sendable () async throws -> Void) { action = value }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1; requests.append(request); try await action?()
        let response = response
        return .init(id: request.id, events: AsyncThrowingStream { stream in
            if let text = response.finalText { stream.yield(.textDelta(text)) }; stream.finish()
        }, cancel: {}, outcome: { .completed(.init(textResponse: response)) })
    }
}

@MainActor extension WorkflowLanguageCloseoutTests {
    @Test func auxiliaryPriorityIsIdenticalAtSubmissionAndPublication() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("aux-priority-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Fixture.dproject"), name: "Auxiliary")
        let engine = CloseoutResponseEngine(.init(rawText: "result", finalText: "result", finishReason: .stop))
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let service = WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: root), backendID: "fixture", operationID: WorkflowModelRoutes.qwen35,
                  textCapability: .init(maximumPromptTokens: 2048, maximumOutputTokens: 256, profile: TextExecutionCapability.qwen35VLMProfile))
        }
        try service.useBackgroundLanguageAdmission()
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture"); node.parameters["outputMode"] = .text("response")
        try service.beginPlan()
        #expect(throws: (any Error).self) { try service.useBackgroundLanguageAdmission() }
        let step = UUID()
        _ = try await service.executeCall(.init(node: node, stepID: step, inputs: [:]))
        let submitted = try #require(await engine.requests.first)
        let record = try #require(try await store.workflowState().archive?.assets.first { $0.request?.id == step })
        #expect(submitted.priority == .background && record.request == submitted)
        try await store.close()
    }

    @Test func longResponsePublishesOnceSurvivesOutputFailureReopenAndCopy() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("response-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("original.dproject"), name: "response")
        let long = String(repeating: "思考\"\n", count: 270_000)
        let response = TextResponse(rawText: long + "ok", reasoningText: long, finalText: "ok", finishReason: .stop)
        let engine = CloseoutResponseEngine(response)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let service = WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: root), backendID: "fixture", operationID: WorkflowModelRoutes.qwen35,
                  textCapability: .init(maximumPromptTokens: 2048, maximumOutputTokens: 256, profile: TextExecutionCapability.qwen35VLMProfile))
        }
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture"); node.parameters["outputMode"] = .text("response")
        node.parameters["loadingStrategy"] = .text("ssdLayered")
        try service.beginPlan()
        var retained: WorkflowAssetReference?
        do { _ = try await service.executeCall(.init(node: node, stepID: UUID(), inputs: [:])); Issue.record("Long reasoning must fail datum budget after durable publication") }
        catch let failure as WorkflowOutputValidationFailure { retained = failure.raw }
        let ref = try #require(retained)
        #expect(!service.hasPendingSaves)
        #expect(await engine.calls == 1)
        #expect(try await service.readLanguageResponse(ref) == response)
        #expect(try await service.readText(ref) == response.rawText)
        let bytes = try await store.workflowData(ref)
        #expect(bytes.count > 1_048_576)
        let snapshot = try #require(try await store.workflowState().archive)
        #expect(snapshot.assets.first?.metadata["textResponse.v1"] == nil)
        guard case .text(let savedRequest) = snapshot.assets.first?.request?.input else { Issue.record("Missing text request"); return }
        #expect(savedRequest.loadingStrategy == .ssdLayered)
        #expect(try JSONEncoder().encode(snapshot).count < 64 * 1024)
        node.parameters["outputMode"] = .text("text")
        #expect(try await WorkflowLanguageOperations.outputs(raw: ref, node: node, services: service)["output"] == .data(.text("ok")))
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.workflowData(ref) == bytes)
        #expect(try await reopened.workflowText(ref) == response.rawText)
        let destination = try await ProjectStore.create(at: root.appendingPathComponent("copy.dproject"), name: "copy")
        let copied = try await destination.copyWorkflowAsset(ref, from: reopened)
        #expect(try await destination.workflowData(copied) == bytes)
        #expect(try await destination.workflowTextResponse(copied) == response)
        let copiedRecord = try #require(try await destination.workflowState().archive?.assets.first { $0.reference == copied })
        guard case .text(let copiedRequest) = copiedRecord.request?.input else { Issue.record("Missing copied request"); return }
        #expect(copiedRequest.loadingStrategy == .ssdLayered)
        let exportID = UUID()
        _ = try await destination.exportWorkflowAssets([copied], name: "text-recipe", exportID: exportID, directory: root)
        let recipe = try String(contentsOf: root.appendingPathComponent("text-recipe-" + exportID.uuidString + ".dexport/recipe.json"), encoding: .utf8)
        #expect(recipe.contains("ssdLayered"))
        #expect(!recipe.contains(root.path))
        try await destination.close(); try await reopened.close()
    }
    @Test func legacyMetadataResponseStillReadsAndDoesNotExecuteTools() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("old-response-" + UUID().uuidString + ".dproject")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root, name: "legacy response")
        let response = TextResponse(rawText: "preamble<tool_call>untrusted</tool_call>", finalText: "preamble", toolCalls: [.init(id: "call_1", name: "no_execute", arguments: [:])], finishReason: .toolCalls)
        let ref = try await store.publishWorkflowAsset(data: Data(response.rawText.utf8), mediaType: "text/plain", name: "old", operationID: "fixture",
            details: ["textResponse.v1": String(decoding: JSONEncoder().encode(response), as: UTF8.self)]).record.reference
        let engine = CloseoutResponseEngine(response)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let service = WorkflowServices(store: store, session: session) { _, _ in throw WorkflowIssue("No loading") }
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        do { _ = try await WorkflowLanguageOperations.outputs(raw: ref, node: node, services: service); Issue.record("Tool preamble cannot become final text") }
        catch let error as WorkflowOutputValidationFailure { #expect(error.raw == ref) }
        node.parameters["outputMode"] = .text("response")
        let result = try await WorkflowLanguageOperations.outputs(raw: ref, node: node, services: service)
        #expect(result["raw"] == .asset(ref))
        #expect(await engine.calls == 0)
        try await store.close()
    }
}

@MainActor extension WorkflowLanguageCloseoutTests {
    @Test func responseManifestSyncFailureReconcilesOnlyOwnExactBytes() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("response-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for tamper in [false, true] {
            let store = try await ProjectStore.create(at: root.appendingPathComponent("\(tamper).dproject"), name: "sync failure")
            let data = try WorkflowTextResponseFile.encode(.init(rawText: "完整原文", finalText: "完整原文", finishReason: .stop))
            let id = UUID()
            do {
                _ = try await store.publishWorkflowAsset(data: data, mediaType: WorkflowTextResponseFile.mediaType, metadata: .init(), name: "result", parents: [], operationID: "fixture", stepID: nil, request: nil, details: [:], assetID: id, checkpoint: { stage in
                    if case .manifestPublished = stage { throw ProjectStoreError.io("controlled post-rename directory sync failure") }
                }); Issue.record("Expected injected sync failure")
            } catch let error as ProjectStoreError { if case .io = error {} else { Issue.record("Wrong failure") } }
            if tamper {
                let path = store.rootURL.appendingPathComponent(ProjectStore.manifestFilename)
                var bytes = try Data(contentsOf: path); bytes.append(Data("\n".utf8)); try bytes.write(to: path)
                do { _ = try await store.workflowState(); Issue.record("Unowned manifest bytes accepted") }
                catch { #expect(error as? ProjectStoreError == .externalModification) }
                // No restore: the controlled external bytes remain for this fixture's lifetime.
            } else {
                // This method constructs its candidate before commit reconciles the pending rename.
                // It must not overwrite the newly published response with an older manifest.
                do { _ = try await store.createTextDocument(name: "interleaved", text: "保留"); Issue.record("Stale candidate committed") }
                catch let error as ProjectStoreError { if case .io = error {} else { Issue.record("Wrong stale write failure") } }
                #expect(await store.snapshot().assets.filter { $0.id == id }.count == 1)
                _ = try await store.createTextDocument(name: "interleaved", text: "保留")
                let published = try await store.publishWorkflowAsset(data: data, mediaType: WorkflowTextResponseFile.mediaType, name: "result", operationID: "fixture", assetID: id)
                #expect(try await store.workflowData(published.record.reference) == data)
                #expect(await store.snapshot().assets.filter { $0.id == id }.count == 1)
                try await store.flush(); try await store.close()
                let reopened = try await ProjectStore.open(at: store.rootURL)
                #expect(try await reopened.workflowData(published.record.reference) == data)
                try await reopened.close()
            }
        }
    }
    @Test func responseDiskRetryDoesNotGenerateAgain() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("response-retry-" + UUID().uuidString + ".dproject")
        let moved = root.appendingPathExtension("offline")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: moved) }
        let store = try await ProjectStore.create(at: root, name: "retry")
        let response = TextResponse(rawText: "ok", finalText: "ok", finishReason: .stop)
        let engine = CloseoutResponseEngine(response)
        await engine.beforeReturn { try FileManager.default.moveItem(at: root, to: moved) }
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        var leases = 0
        let service = WorkflowServices(store: store, session: session) { _, identity in
            leases += 1
            return .init(identity: identity, reference: .init(directory: root), backendID: "fixture", operationID: WorkflowModelRoutes.qwen35, textCapability: .init(maximumPromptTokens: 2048, maximumOutputTokens: 256, profile: TextExecutionCapability.qwen35VLMProfile))
        }
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode()); node.parameters["modelID"] = .text("text:fixture")
        let context = WorkflowExecutionContext(node: node, stepID: UUID(), inputs: [:])
        try service.beginPlan()
        do { _ = try await service.executeCall(context); Issue.record("Missing volume must fail") }
        catch { #expect(error is WorkflowSaveFailure) }
        #expect(service.hasPendingSaves)
        try FileManager.default.moveItem(at: moved, to: root)
        try service.beginPlan(); _ = try await service.executeCall(context)
        #expect(!service.hasPendingSaves && leases == 1)
        #expect(await engine.calls == 1)
        try await store.close()
    }
}

@MainActor extension WorkflowLanguageCloseoutTests {
    @Test func explicitMemoryBudgetReachesRuntimeWithoutChangingModelOrOldNodes() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("language-budget-" + UUID().uuidString + ".dproject")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root, name: "budget")
        let engine = CloseoutResponseEngine(.init(rawText: "ok", finalText: "ok", finishReason: .stop))
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let service = WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: root), backendID: "fixture", operationID: WorkflowModelRoutes.qwen35,
                  textCapability: .init(maximumPromptTokens: 2048, maximumOutputTokens: 256, profile: TextExecutionCapability.qwen35VLMProfile))
        }
        let registry = WorkflowRegistry.standard
        var node = try #require(registry.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture")
        for (budget, strategy): (Int?, String?) in [(nil, nil), (0, "resident"), (15, "ssdLayered")] {
            node.parameters["memoryBudgetGiB"] = budget.map(WorkflowScalar.integer)
            node.parameters["loadingStrategy"] = strategy.map(WorkflowScalar.text)
            let before = node
            try registry.validate(node)
            #expect(node == before)
            try service.beginPlan()
            _ = try await service.executeCall(.init(node: node, stepID: UUID(), inputs: [:]))
            let request = try #require(await engine.requests.last)
            let expectedBytes: UInt64? = budget == 15 ? 15 * 1_073_741_824 : nil
            #expect(request.memoryBudgetBytes == expectedBytes)
            guard case .text(let text) = request.input else { Issue.record("Expected text"); return }
            #expect(text.loadingStrategy == strategy.flatMap(TextLoadingStrategy.init(rawValue:)))
            #expect(request.model.directory == root)
        }
        for invalid: WorkflowScalar in [.integer(-1), .integer(Int.max), .text("15"), .decimal(15)] {
            node.parameters["memoryBudgetGiB"] = invalid
            #expect(throws: (any Error).self) { try registry.validate(node) }
            #expect(throws: (any Error).self) { try WorkflowLanguageMessageForm.memoryBudgetBytes(node.parameters) }
        }
        node.parameters["memoryBudgetGiB"] = nil
        for route in [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38] {
            var invalidNode = try #require(registry.operation(route)?.definition.makeNode())
            for invalid: WorkflowScalar in [.text("unsupported"), .integer(1), .decimal(0)] {
                invalidNode.parameters["loadingStrategy"] = invalid
                #expect(throws: (any Error).self) { try registry.validate(invalidNode) }
                #expect(throws: (any Error).self) { try WorkflowLanguageMessageForm.loadingStrategy(invalidNode.parameters) }
            }
        }
        #expect(await engine.calls == 3)
        try await store.close()
    }
}


private actor PreviewCloseoutEngine: InferenceEngine {
    private var continuation: AsyncThrowingStream<InferenceOutput, Error>.Continuation?
    private var completed: RunOutcome = .cancelled
    var ready: Bool { continuation != nil }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        let pair = AsyncThrowingStream<InferenceOutput, Error>.makeStream()
        continuation = pair.continuation
        return .init(id: request.id, events: pair.stream,
            cancel: { await self.end(.cancelled) }, outcome: { await self.outcome() })
    }
    func send(_ text: String) { continuation?.yield(.textDelta(text)) }
    func end(_ value: RunOutcome) { completed = value; continuation?.finish(); continuation = nil }
    private func outcome() -> RunOutcome { completed }
}

@MainActor extension WorkflowLanguageCloseoutTests {
    @Test func transientPreviewHandsOffAcceptedContentBeforeSavingEveryTerminalOutcome() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for end in ["success", "failure", "cancel", "empty", "integrity", "cleanup"] {
            let store = try await ProjectStore.create(at: root.appendingPathComponent(end + ".dproject"), name: end)
            let engine = PreviewCloseoutEngine()
            let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
            let service = WorkflowServices(store: store, session: session) { _, identity in
                .init(identity: identity, reference: .init(directory: root), backendID: "fixture", operationID: WorkflowModelRoutes.qwen35,
                    textCapability: .init(maximumPromptTokens: 2048, maximumOutputTokens: 256, profile: TextExecutionCapability.qwen35VLMProfile))
            }
            var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
            node.parameters["modelID"] = .text("text:fixture"); node.parameters["outputMode"] = .text("text")
            let id = UUID(); var received: [(UUID, String)] = []
            service.languagePreviewChanged = { received.append(($0, $1)) }
            try service.beginPlan()
            let task = Task { try await service.executeCall(.init(node: node, stepID: id, inputs: [:])) }
            for _ in 0..<500 { if await engine.ready { break }; try await Task.sleep(for: .milliseconds(5)) }
            guard await engine.ready else { task.cancel(); Issue.record("No submitted run"); continue }
            if end != "empty" { await engine.send("你好🌍") }
            if end != "empty" { for _ in 0..<500 { if received.last?.1 == "你好🌍" { break }; try await Task.sleep(for: .milliseconds(5)) } }
            #expect(received.last?.0 == id && received.last?.1 == (end == "empty" ? "" : "你好🌍"))
            #expect((try await store.workflowState().archive?.assets ?? []).isEmpty)
            switch end {
            case "success": await engine.end(.completed(.init(textResponse: .init(rawText: "你好🌍", finalText: "你好🌍", finishReason: .stop))))
            case "failure", "empty": await engine.end(.failed(.backendFailed("controlled failure")))
            case "integrity": await engine.end(.failed(.inputIntegrityChanged("controlled file change")))
            case "cleanup": await engine.end(.failed(.resourceCleanupUnconfirmed("controlled cleanup")))
            default: await service.cancel()
            }
            let result = await task.result
            if end == "success" {
                if case .failure(let error) = result { Issue.record("Unexpected failure: \(error)") }
                #expect((try await store.workflowState().archive?.assets ?? []).count == 1)
            } else if end == "empty" {
                if case .success = result { Issue.record("Empty must not succeed") }
                #expect((try await store.workflowState().archive?.assets ?? []).isEmpty)
            } else {
                if case .success = result { Issue.record("Partial must not succeed") }
                let assets = try await store.workflowState().archive?.assets ?? []
                #expect(assets.count == 1)
                let raw = try #require(assets.first?.reference)
                let content = try await store.workflowLanguageContent(raw)
                #expect(content.rawText == "你好🌍" && content.response == nil)
                let expected: WorkflowLanguageEnd.Cause = end == "cancel" ? .stopped : end == "integrity" ? .inputIntegrity : end == "cleanup" ? .cleanupUnconfirmed : .executionError
                #expect(content.end?.cause == expected)
                if content.end?.inspectionOnly == true {
                    await #expect(throws: WorkflowIssue.self) { try await service.readText(raw) }
                    #expect(try await store.workflowText(raw) == "你好🌍")
                }
                if case .failure(let error) = result {
                    let failure = try #require(error as? WorkflowOutputValidationFailure)
                    #expect(failure.raw == raw)
                }
            }
            #expect(received.last?.0 == id && received.last?.1 == (end == "empty" ? "" : "你好🌍"))
            #expect(service.retainedLanguageContent(stepID: id)?.rawText == (end == "empty" ? nil : "你好🌍"))
            try await store.close()
        }
    }
}

@MainActor extension WorkflowLanguageCloseoutTests {
    @Test func terminalEnvelopeDoesNotDuplicateRawAndPreservesLegacyAndRawOnly() throws {
        let raw = String(repeating: "中e\u{301}👩🏽‍💻", count: 100_000)
        let response = TextResponse(rawText: raw, reasoningText: raw, finishReason: .incomplete)
        let old = try WorkflowTextResponseFile.encode(response)
        let current = WorkflowLanguageContent(rawText: raw, response: response, end: .init(.length))
        let bytes = try WorkflowTextResponseFile.encode(current)
        #expect(bytes.count < old.count + 128)
        #expect(try WorkflowTextResponseFile.decodeContent(bytes) == current)
        #expect(try WorkflowTextResponseFile.decode(old) == response)
        let unparsed = WorkflowLanguageContent(rawText: raw, end: .init(.stopped))
        #expect(try WorkflowTextResponseFile.decodeContent(WorkflowTextResponseFile.encode(unparsed)) == unparsed)
        #expect(throws: WorkflowIssue.self) { try WorkflowTextResponseFile.decode(WorkflowTextResponseFile.encode(unparsed)) }
    }

    @Test func interruptedPublicationObstructionRetainsOwnerAndSaveRetryCannotRunAgain() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("partial-obstruction-" + UUID().uuidString + ".dproject")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root, name: "partial")
        let obstruction = root.appendingPathComponent("WorkflowAssets")
        try Data("protected fixture".utf8).write(to: obstruction)
        let response = TextResponse(rawText: "partial answer", finalText: "partial answer", finishReason: .length)
        let engine = CloseoutResponseEngine(response)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let service = WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: root), backendID: "fixture", operationID: WorkflowModelRoutes.qwen35,
                textCapability: .init(maximumPromptTokens: 2048, maximumOutputTokens: 256, profile: TextExecutionCapability.qwen35VLMProfile))
        }
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("fixture"); node.parameters["outputMode"] = .text("text")
        let context = WorkflowExecutionContext(node: node, stepID: UUID(), inputs: [:])
        try service.beginPlan()
        do { _ = try await service.executeCall(context); Issue.record("Expected obstruction") }
        catch let failure as WorkflowSaveFailure { #expect(failure.languageEnd?.cause == .length) }
        #expect(service.hasPendingPublication(stepID: context.stepID))
        #expect(service.retainedPublicationContext(stepID: context.stepID)?.node == node)
        #expect(service.retainedLanguageContent(stepID: context.stepID)?.rawText == response.rawText)
        #expect(try String(contentsOf: obstruction, encoding: .utf8) == "protected fixture")
        #expect(await engine.calls == 1)
        // Remove only the test-created obstruction; the original app path is never touched.
        try FileManager.default.removeItem(at: obstruction)
        var reference: WorkflowAssetReference?
        do { _ = try await service.retryQuickPublications(context); Issue.record("Saved partial must not become a completed output") }
        catch let failure as WorkflowOutputValidationFailure { reference = failure.raw; #expect(failure.end.cause == .length) }
        #expect(!service.hasPendingSaves)
        #expect(await engine.calls == 1)
        let ref = try #require(reference)
        #expect(try await store.workflowLanguageContent(ref).response == response)
        #expect((try await store.workflowState().archive?.assets ?? []).count == 1)
        try await store.close()
        let reopened = try await ProjectStore.open(at: root)
        #expect(try await reopened.workflowLanguageContent(ref).end?.cause == .length)
        #expect(try await reopened.workflowText(ref) == response.rawText)
        try await reopened.close()
    }
}

@MainActor extension WorkflowLanguageCloseoutTests {
    private func partialFixture() async throws -> (ProjectStore, CloseoutResponseEngine, WorkflowServices) {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("partial-owner-" + UUID().uuidString + ".dproject")
        let store = try await ProjectStore.create(at: root, name: "Partial owners")
        let engine = CloseoutResponseEngine(.init(rawText: "保留 partial", finalText: "保留 partial", finishReason: .length))
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let services = WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: root), backendID: "fixture", operationID: WorkflowModelRoutes.qwen35,
                textCapability: .init(maximumPromptTokens: 2048, maximumOutputTokens: 256, profile: TextExecutionCapability.qwen35VLMProfile))
        }
        return (store, engine, services)
    }
    @Test func workflowRecomputeKeepsOriginalPartialRunAndCreatesFreshCall() async throws {
        let (store, engine, services) = try await partialFixture()
        let controller = WorkflowController(services: services); await controller.load()
        controller.addNode(operationID: WorkflowModelRoutes.qwen35)
        let node = try #require(controller.graph?.nodes.last)
        controller.setParameter(nodeID: node.id, key: "modelID", value: .text("text:fixture"))
        await engine.replaceResponse(.init(rawText: "更早成功", finalText: "更早成功", finishReason: .stop))
        await controller.run(target: node.id, only: true)
        let earlier = try #require(controller.runs.last)
        #expect(earlier.status == .completed)
        await engine.replaceResponse(.init(rawText: "保留 partial", finalText: "保留 partial", finishReason: .length))
        await controller.run(target: node.id, only: true)
        let original = try #require(controller.runs.last)
        #expect(original.status == .failed && original.steps.first?.languageEnd?.cause == .length)
        await engine.replaceResponse(.init(rawText: "完整 complete", finalText: "完整 complete", finishReason: .stop))
        await controller.resume(runID: original.id)
        #expect(controller.runs.count == 3 && controller.runs[0] == earlier && controller.runs[1] == original)
        let next = try #require(controller.runs.last)
        #expect(next.id != original.id && next.steps.first?.id != original.steps.first?.id)
        #expect(next.status == .completed && next.steps.first?.languageEnd?.interrupted != true)
        #expect(await engine.calls == 3)
        #expect(next.steps.first?.repeatRequested == true)
        let output = try #require(next.steps.first?.outputs["raw"]?.asset)
        #expect(try await store.workflowLanguageContent(output).rawText == "完整 complete")
        try await controller.close(); try await store.close()
    }
    @Test func quickSaveRecoveryRetainsValidationCauseWithoutGeneratingAgain() async throws {
        let (store, engine, services) = try await partialFixture()
        await engine.replaceResponse(.init(rawText: "{ broken", finalText: "{ broken", finishReason: .stop))
        let quick = QuickGenerationController(store: store) { services }; await quick.load()
        quick.select(operationID: WorkflowModelRoutes.qwen35, modelID: "text:fixture")
        let draft = try #require(quick.draft)
        quick.setParameter("outputMode", value: .text("json"), draftID: draft.id)
        quick.setDataConfiguration(.init(schema: .record([.init("required", .text)])), draftID: draft.id)
        #expect(quick.canStart, "Fixture must satisfy the production input contract: \(quick.inputIssue ?? "none")")
        services.publicationCheckpoint = { stage in if case .assetDurable = stage { throw ProjectStoreError.io("controlled asset durable failure") } }
        quick.start(); await quick.waitForCompletion()
        #expect(quick.pendingSaveRunID != nil && services.hasPendingSaves)
        let oldID = try #require(quick.state.runs.last?.id)
        services.publicationCheckpoint = nil
        await quick.retrySave()
        #expect(quick.state.runs.last?.id == oldID && quick.state.runs.last?.languageEnd?.cause == .invalidOutput)
        #expect(quick.state.runs.last?.status == .failed && !services.hasPendingSaves)
        #expect(await engine.calls == 1)
        let cold = QuickGenerationController(store: store) { throw WorkflowIssue("Cold read cannot infer") }; await cold.load()
        #expect(cold.state.runs.last?.languageEnd?.cause == .invalidOutput)
        #expect((try await store.workflowAssets(forStepID: oldID)).count == 1)
        try await quick.prepareForTermination(); try await store.close()
    }
}
