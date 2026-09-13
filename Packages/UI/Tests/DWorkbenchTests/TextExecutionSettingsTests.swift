import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor SettingsCaptureEngine: InferenceEngine {
    private(set) var requests: [InferenceRequest] = []

    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        return InferenceRun(
            id: request.id,
            events: AsyncThrowingStream { continuation in
                continuation.yield(.textDelta("replacement"))
                continuation.finish()
            },
            cancel: {},
            outcome: { .completed(.init(metadata: ["fixture": "settings"])) })
    }
}

private actor SettingsGatedEngine: InferenceEngine {
    private var continuation: AsyncThrowingStream<InferenceOutput, Error>.Continuation?
    private(set) var request: InferenceRequest?

    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        self.request = request
        let (stream, continuation) = AsyncThrowingStream<InferenceOutput, Error>.makeStream()
        self.continuation = continuation
        continuation.yield(.textDelta("late replacement"))
        return InferenceRun(id: request.id, events: stream, cancel: {}, outcome: { .completed(.init()) })
    }

    func finish() { continuation?.finish() }
}

@Suite("Text execution settings", .serialized) @MainActor
struct TextExecutionSettingsTests {
    private let model = ModelReference(directory: URL(fileURLWithPath: "/declared/settings-model"))
    private let custom = TextGenerationSettings(
        maximumPromptTokens: 1024,
        maximumOutputTokens: 96,
        profile: TextExecutionCapability.qwen2Profile)

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func defaultsAndLegacyArchiveDecodeAreStable() throws {
        #expect(TextGenerationSettings() == .legacy)
        #expect(TextGenerationSettings.legacy.maximumPromptTokens == 2048)
        #expect(TextGenerationSettings.legacy.maximumOutputTokens == 256)
        #expect(TextGenerationSettings.legacy.profile == TextExecutionCapability.qwen2Profile)

        let legacy = Data(#"{"schema_version":1,"document":{"id":"11111111-1111-1111-1111-111111111111","revision":"22222222-2222-2222-2222-222222222222","text":"legacy"}}"#.utf8)
        let decoded = try TextDraftArchive.decode(legacy)
        #expect(decoded.text == "legacy")
        #expect(decoded.generationSettings == .legacy)
    }

    @Test func schemaTwoRoundTripsUnknownProfileButRequiresSettingsField() throws {
        let unknown = TextGenerationSettings(
            maximumPromptTokens: 700,
            maximumOutputTokens: 80,
            profile: ExecutionProfileReference(identifier: "future-text", revision: 7))
        let document = try TextDraftDocument(text: "history", generationSettings: unknown)
        let data = try TextDraftArchive.encode(document)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema_version"] as? Int == 2)
        #expect(try TextDraftArchive.decode(data) == document)

        let missing = Data(#"{"schema_version":2,"document":{"id":"11111111-1111-1111-1111-111111111111","revision":"22222222-2222-2222-2222-222222222222","text":"malformed"}}"#.utf8)
        #expect(throws: TextDraftError.malformedArchive) { try TextDraftArchive.decode(missing) }
        let presentNull = Data(#"{"schema_version":1,"document":{"id":"11111111-1111-1111-1111-111111111111","revision":"22222222-2222-2222-2222-222222222222","text":"malformed","generationSettings":null}}"#.utf8)
        #expect(throws: TextDraftError.malformedArchive) { try TextDraftArchive.decode(presentNull) }
        let fractional = Data(#"{"schema_version":2.0,"document":{}}"#.utf8)
        #expect(throws: TextDraftError.malformedArchive) { try TextDraftArchive.decode(fractional) }
    }

    @Test func editAcceptAndUndoPreserveSettings() async throws {
        let engine = SettingsCaptureEngine()
        let original = try TextDraftDocument(text: "before old after", generationSettings: custom)
        let session = TextDraftSession(document: original, engine: engine, backendID: "fixture")
        try session.editText("prefix old suffix")
        #expect(session.document.generationSettings == custom)
        let selection = try session.selection(inUTF16: NSRange(location: 7, length: 3))
        try await session.requestRewrite(selection: selection, instruction: "revise", model: model)
        try session.acceptCandidate()
        #expect(session.document.generationSettings == custom)
        try session.undoAcceptedRewrite()
        #expect(session.document.text == "prefix old suffix")
        #expect(session.document.generationSettings == custom)
    }

    @Test func requestSnapshotsSettingsAndExplicitLegacyOutputOverrideWins() async throws {
        let settingsEngine = SettingsCaptureEngine()
        let settingsSession = TextDraftSession(
            document: try TextDraftDocument(text: "draft", generationSettings: custom),
            engine: settingsEngine,
            backendID: "fixture")
        try await settingsSession.requestRewrite(
            selection: settingsSession.selection(inUTF16: NSRange(location: 0, length: 5)),
            instruction: "settings",
            model: model)
        let settingsRequest = try #require(await settingsEngine.requests.first)
        let text = try #require({
            if case .text(let value) = settingsRequest.input { return value }
            return nil
        }())
        #expect(text.maxTokens == custom.maximumOutputTokens)
        #expect(text.execution == TextExecutionSelection(
            profile: custom.profile, maximumPromptTokens: custom.maximumPromptTokens))

        let overrideEngine = SettingsCaptureEngine()
        let overrideSession = TextDraftSession(
            document: try TextDraftDocument(text: "draft", generationSettings: custom),
            engine: overrideEngine,
            backendID: "fixture")
        try await overrideSession.requestRewrite(
            selection: overrideSession.selection(inUTF16: NSRange(location: 0, length: 5)),
            instruction: "override",
            model: model,
            maxTokens: 11)
        let overrideRequest = try #require(await overrideEngine.requests.first)
        if case .text(let override) = overrideRequest.input {
            #expect(override.maxTokens == 11)
            #expect(override.execution?.maximumPromptTokens == custom.maximumPromptTokens)
        } else {
            Issue.record("Expected text request")
        }
    }

    @Test func settingsChangesIncludingABAInvalidateAnInflightCandidate() async throws {
        let engine = SettingsGatedEngine()
        let original = try TextDraftDocument(text: "one two three")
        let session = TextDraftSession(document: original, engine: engine, backendID: "fixture")
        let selection = try session.selection(inUTF16: NSRange(location: 4, length: 3))
        let rewrite = Task {
            try await session.requestRewrite(selection: selection, instruction: "late", model: model)
        }
        try await waitUntil { await engine.request != nil }
        try session.updateGenerationSettings(custom)
        let revisionB = session.document.revision
        try session.updateGenerationSettings(.legacy)
        #expect(session.document.revision != original.revision)
        #expect(session.document.revision != revisionB)
        #expect(session.document.text == original.text)
        await engine.finish()
        try await rewrite.value
        #expect(session.candidate != nil)
        #expect(!session.canAcceptCandidate)
        #expect(session.candidate?.selection.documentRevision == original.revision)
        #expect(session.document.generationSettings == .legacy)
    }

    @Test func controllerSettingsUpdateUsesSerialPersistenceAndKeepsBody() async throws {
        let original = try TextDraftDocument(text: "unchanged body")
        var snapshots: [TextDraftDocument] = []
        let controller = ProjectTextController(
            document: original,
            engine: SettingsCaptureEngine(),
            backendID: "fixture") { document, revision in
                #expect(revision == original.revision)
                snapshots.append(document)
            }
        controller.updateGenerationSettings(custom)
        #expect(controller.editor.document.text == original.text)
        #expect(controller.editor.document.revision != original.revision)
        #expect(controller.editor.document.generationSettings == custom)
        try await controller.flush()
        #expect(snapshots == [controller.editor.document])
        #expect(!controller.isDirty)
    }
}
