import DInference
import DMLXBackend
import DRuntime
import Foundation
import Testing
@testable import DWorkbench

// Opt-in integration in the existing package test runner. No App, view, model
// download, or replacement executor: the production comparison and Store call
// the real Runtime and backend. Installation/TCC/GUI are separate acceptance.
private actor ChatRealTrace {
    var lifecycle: [MLXLifecycleEvent] = []
    var requests: [InferenceRequest] = []
    var results: [InferenceResult] = []
    func event(_ value: MLXLifecycleEvent) { lifecycle.append(value) }
    func request(_ value: InferenceRequest) { requests.append(value) }
    func result(_ value: InferenceResult) { results.append(value) }
}

private struct RecordedChatBackend: InferenceBackend {
    let backend: MLXQwenVLMBackend
    let trace: ChatRealTrace
    let root: URL
    var descriptor: BackendDescriptor { backend.descriptor }
    func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate { try await backend.estimate(request) }
    func execute(_ request: InferenceRequest, emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        await trace.request(request)
        try realChatWrite(request, to: root.appendingPathComponent("request-\(request.id).json"))
        let result = try await backend.execute(request, emit: emit)
        await trace.result(result)
        try realChatWrite(result, to: root.appendingPathComponent("result-\(request.id).json"))
        return result
    }
    func release() async { await backend.release() }
}

private func realChatWrite<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .withoutOverwriting)
}

@Suite("Real chat comparison and template", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["D_REAL_CHAT_PAIR"] == "1"))
@MainActor struct ChatRealModelTests {
    // Reuses a captured real backend response; does not repeat inference merely
    // to make a bounded reasoning model produce a final answer. Length is valid.
    @Test func recordedActualChannelsSurviveIndependentReopen() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["D_REAL_CHAT_CHANNEL_CAPTURE"]))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let resultURL = try #require(files.first { $0.lastPathComponent.hasPrefix("result-") && $0.pathExtension == "json" })
        let result = try JSONDecoder().decode(InferenceResult.self, from: Data(contentsOf: resultURL))
        let actual = try #require(result.textResponse)
        #expect(actual.reasoningText?.isEmpty == false)
        let store = try await ProjectStore.open(at: root.appendingPathComponent("Channels.dproject"))
        do {
            let saved = try await store.chatState()
            let attempt = try #require(saved.sessions.first?.attempts.last)
            #expect(attempt.response == actual)
            #expect(attempt.rawText == actual.rawText)
            if actual.finishReason == .incomplete {
                #expect(attempt.status == .partial)
                #expect(actual.finalText == nil)
                #expect(result.metadata["stopReason"] == "length")
            } else {
                #expect(attempt.status == .completed)
                #expect(actual.finalText?.isEmpty == false)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test(.timeLimit(.minutes(60)))
    func frozenQuestionAcrossInstalledModelsAndCustomTemplate() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("Chat-real-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let profiles = try TextModelProfiles.registeredVLM()
        let profileIDs = ["Qwen/Qwen3.5-9B", "Qwen/Qwen3.8-27B"]
        let paths = [try #require(env["D_REAL_CHAT_9B"]), try #require(env["D_REAL_CHAT_27B"])]
        let chosen = try profileIDs.map { id in try #require(profiles.first { $0.id == id && $0.quantizationBits == 0 }) }
        let references = zip(paths, chosen).map { ModelReference(directory: URL(fileURLWithPath: $0.0), revision: $0.1.revision) }
        for model in references { _ = try MLXQwenVLMBackend.validateModel(at: model.directory, revision: model.revision) }
        let identities = chosen.map { "text:" + $0.revision }
        let operations = [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38]
        let trace = ChatRealTrace()
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Comparison.dproject"), name: "Real cross-model comparison")
        let backend = try MLXQwenVLMBackend(configuration: .init(artifactDirectory: store.artifactDirectory,
            maximumPromptTokens: 4096, maximumOutputTokens: 64), observer: { await trace.event($0) })
        let engine = try InferenceRuntime(backends: [RecordedChatBackend(backend: backend, trace: trace, root: root)],
            configuration: .init(memoryBudgetBytes: 15 * 1024 * 1024 * 1024))
        let runtime = WorkbenchSession(engine: engine, backendID: backend.descriptor.id, status: {
            let state = await engine.snapshot()
            return .init(activeRunID: state.activeRunID, phase: state.phase?.rawValue, queuedRunIDs: state.queuedRunIDs)
        }, shutdown: { await engine.shutdown() }, cleanup: {}, validateModel: { _ in },
            textBackendID: backend.descriptor.id, previewTextTemplate: { try await ChatTemplatePreviewProvider.preview(model: $0, request: $1) },
            textCapability: backend.executionCapability, defaultMemoryBudgetBytes: 15 * 1024 * 1024 * 1024)
        var leases: [String] = []
        let chat = ChatController(store: store) {
            WorkflowServices(store: store, session: runtime) { kind, identity in
                guard kind == .text, let i = identities.firstIndex(of: identity) else { throw WorkflowIssue("Unexpected model identity") }
                leases.append("acquire:" + identity)
                return .init(identity: identity, reference: references[i], backendID: backend.descriptor.id,
                    operationID: operations[i], textCapability: backend.executionCapability,
                    release: { leases.append("release:" + identity) })
            }
        }
        func configuration(_ i: Int) throws -> WorkflowNode {
            var node = try #require(WorkflowRegistry.standard.operation(operations[i])?.definition.makeNode())
            node.parameters["modelID"] = .text(identities[i])
            node.parameters["maximumPromptTokens"] = .integer(1024)
            node.parameters["maximumOutputTokens"] = .integer(32)
            node.parameters["temperature"] = .decimal(0)
            node.parameters["thinking"] = .text("off")
            node.parameters["seed"] = .text("42")
            node.parameters["memoryBudgetGiB"] = .integer(15)
            node.parameters["loadingStrategy"] = .text("ssdLayered")
            return node
        }
        print("D_REAL_CHAT_ROOT=\(root.path)")
        do {
            await chat.load()
            let owner = try chat.newSession()
            var firstNode = try configuration(0)
            try chat.updateConfiguration(firstNode, sessionID: owner)
            try chat.setSystemPrompt("Answer briefly in English.", sessionID: owner)
            try chat.updateDraft("Name two primary colors in one short sentence.", sessionID: owner)
            let baseline = try await chat.previewTemplate(sessionID: owner)
            // The installed template has macros outside the editable finite subset.
            // Reuse the finite template already verified against the real tokenizer.
            let finiteTemplate = """
        {% for message in messages %}<|im_start|>{{ message.role }}\n
        {% if message.role == 'tool' %}<tool_response>\n{% endif %}
        {% for part in message.content %}{% if part.type == 'text' %}{{ part.text }}{% elif part.type == 'image' %}<|vision_start|><|image_pad|><|vision_end|>{% elif part.type == 'video' %}<|vision_start|><|video_pad|><|vision_end|>{% endif %}{% endfor %}
        {% if message.reasoning_content %}{{ message.reasoning_content }}{% endif %}{% if message.tool_calls %}{{ message.tool_calls | tojson }}{% endif %}<|im_end|>\n
        {% endfor %}{% if tools %}{% for tool in tools %}{{ tool | tojson }}{% endfor %}{% endif %}{% if add_generation_prompt %}<|im_start|>assistant\n<think>\n{% if enable_thinking == false %}\n</think>\n\n{% endif %}{% endif %}
        """
            let override = "D-integration-template-marker\n" + finiteTemplate
            firstNode.parameters["chatTemplateOverride"] = .text(override)
            try chat.updateConfiguration(firstNode, sessionID: owner)
            let preview = try await chat.previewTemplate(sessionID: owner)
            try #require(preview.renderedTemplate.hasPrefix("D-integration-template-marker\n"))
            try #require(preview.templateTokenIDs != baseline.templateTokenIDs && preview.templateTokenIDs.count != baseline.templateTokenIDs.count)
            try realChatWrite(["default": baseline.renderedTemplate, "edited": preview.renderedTemplate, "override": override], to: root.appendingPathComponent("template.json"))
            try realChatWrite(["default": baseline.templateTokenIDs, "edited": preview.templateTokenIDs], to: root.appendingPathComponent("template-tokens.json"))
            try await chat.send(sessionID: owner); await chat.waitForCompletion()
            let first = try #require(chat.selectedSession?.attempts.last)
            try #require(first.status == .completed, "First model: \(first.status), \(first.issue ?? "")")
            try #require(!first.rawText.isEmpty && first.node.parameters["chatTemplateOverride"]?.string == override)
            let firstState = await engine.snapshot()
            try #require(firstState.activeRunID == nil && firstState.reservedBytes == 0)
            print("D_REAL_CHAT_FIRST_COMPLETED=\(first.id)")
            // Future edits and another selected session must not replace the frozen question.
            try chat.setSystemPrompt("Future-only rules.", sessionID: owner)
            try chat.updateDraft("Unsent future question 👩🏽‍🎨", sessionID: owner)
            let other = try chat.newSession()
            try await chat.compare(first.id, configuration: configuration(1), sessionID: owner)
            await chat.waitForCompletion()
            let state = try #require(chat.state.sessions.first { $0.id == owner })
            let second = try #require(state.attempts.last)
            try #require(second.status == .completed, "Second model: \(second.status), \(second.issue ?? "")")
            try #require(state.attempts.count == 2 && state.attempts.first == first && !second.rawText.isEmpty)
            #expect(second.comparisonSourceAttemptID == first.id && second.userMessageID == first.userMessageID)
            #expect(second.messagesJSON == first.messagesJSON && second.inputs == first.inputs && second.systemPrompt == first.systemPrompt)
            #expect(chat.selectedSession?.id == other && chat.selectedSession?.attempts.isEmpty == true)
            #expect(state.draft == "Unsent future question 👩🏽‍🎨")
            let requests = await trace.requests, results = await trace.results, events = await trace.lifecycle
            try #require(requests.count == 2 && results.count == 2)
            for i in 0..<2 {
                #expect(requests[i].model == references[i] && results[i].metadata["modelRevision"] == references[i].revision)
                #expect(results[i].metadata["loadingStrategy"] == "ssdLayered")
                let runEvents = events.filter { $0.runID == requests[i].id }
                #expect(runEvents.map(\.phase) == [.loading, .loaded, .generating, .drained, .released])
                #expect(runEvents.last?.memory.activeBytes == 0 && runEvents.last?.memory.cacheBytes == 0)
            }
            guard case .text(let actualFirst) = requests[0].input, case .text(let actualSecond) = requests[1].input else { throw WorkflowIssue("Wrong request type") }
            #expect(actualFirst.messages == actualSecond.messages && actualFirst.thinking == actualSecond.thinking && actualFirst.seed == actualSecond.seed)
            #expect(actualFirst.chatTemplateOverride == override && actualSecond.chatTemplateOverride == nil)
            #expect(results[0].metadata["promptTokens"] == String(preview.templateTokenIDs.count))
            #expect(results[0].metadata["promptTokens"] != String(baseline.templateTokenIDs.count))
            let firstRelease = try #require(events.last { $0.runID == requests[0].id && $0.phase == .released })
            let secondLoad = try #require(events.first { $0.runID == requests[1].id && $0.phase == .loading })
            #expect(firstRelease.uptimeSeconds < secondLoad.uptimeSeconds)
            var expectedLeases: [String] = []
            for _ in 0..<3 { expectedLeases += ["acquire:" + identities[0], "release:" + identities[0]] }
            expectedLeases += ["acquire:" + identities[1], "release:" + identities[1]]
            #expect(leases == expectedLeases)
            let finalState = await engine.snapshot()
            #expect(finalState.activeRunID == nil && finalState.reservedBytes == 0 && finalState.queuedRunIDs.isEmpty)
            try chat.selectLeaf(second.assistantMessageID, sessionID: owner)
            let path = try #require(chat.state.sessions.first { $0.id == owner }).path(to: second.assistantMessageID)
            #expect(path.map(\.id) == [first.userMessageID, second.assistantMessageID])
            let context = try chat.contextPreview(sessionID: owner)
            let messages = try #require(JSONSerialization.jsonObject(with: Data(context.messagesJSON.utf8)) as? [[String: Any]])
            let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
            let parts = try #require(assistant["parts"] as? [[String: Any]])
            #expect(parts.first?["text"] as? String == second.response?.finalText)
            try await chat.prepareForTermination()
            let saved = chat.state
            try realChatWrite(events, to: root.appendingPathComponent("lifecycle.json"))
            try realChatWrite(saved, to: root.appendingPathComponent("saved-chat.json"))
            try realChatWrite(["selectedNextContext": context.messagesJSON], to: root.appendingPathComponent("context.json"))
            await engine.shutdown(); try await store.close()
            let reopened = try await ProjectStore.open(at: store.rootURL)
            do {
                #expect(try await reopened.chatState() == saved)
                for attempt in [first, second] {
                    let output = try #require(attempt.output)
                    #expect(!(try await reopened.workflowData(output)).isEmpty)
                }
                try await reopened.close()
            } catch { try? await reopened.close(); throw error }
            print("D_REAL_CHAT_PAIR_COMPLETE=\(root.path)")
        } catch {
            await chat.cancelAll(); await chat.waitForCompletion(); await engine.shutdown()
            try? await chat.prepareForTermination(); try? await store.close()
            try? realChatWrite(await trace.lifecycle, to: root.appendingPathComponent("failure-lifecycle.json"))
            throw error
        }
    }
}
