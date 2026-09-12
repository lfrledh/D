import DInference
import DRuntime
import Foundation
import Testing
@testable import DWorkbench

private actor AudioCreationCPUProbe {
    var started: Set<String> = []
    var releaseCount = 0
    func begin(_ prompt: String) { started.insert(prompt) }
    func didRelease() { releaseCount += 1 }
}

private actor AudioCreationCPUBackend: InferenceBackend {
    nonisolated let descriptor = BackendDescriptor(id: "fixture.audio", version: "1", capabilities: [.audioGeneration])
    let root: URL
    let probe: AudioCreationCPUProbe
    init(root: URL, probe: AudioCreationCPUProbe) { self.root = root; self.probe = probe }
    func estimate(_ request: InferenceRequest) throws -> ResourceEstimate { .init(peakBytes: 1) }
    func execute(_ request: InferenceRequest,
                 emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        try Task.checkCancellation()
        guard case .audio(let input) = request.input else { throw ProjectStoreError.invalidTransition }
        await probe.begin(input.prompt)
        // Explicit synthetic modes exercise the host's cancellation/error wiring, not a model.
        if input.prompt == "CPU wait for cancellation" {
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        if input.prompt == "CPU fail without output" {
            throw InferenceFailure.backendFailed("Controlled CPU fixture failure")
        }
        let folder = root.appendingPathComponent("\(request.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())/job")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("output.wav")
        let samples = [Float](repeating: 0.125, count: Int((input.durationSeconds * 44_100).rounded()))
        try AudioTestMedia.writePCM(to: url, samples: [samples, samples], sampleRate: 44_100,
                                   bitDepth: 32, floatingPoint: true)
        let artifact = ArtifactReference(url: url, mediaType: "audio/wav")
        try await emit(.artifact(artifact))
        return .init(artifacts: [artifact], metadata: ["evidence": "CPU fixture, not model or acoustic validation"])
    }
    func release() async { await probe.didRelease() }
}

@Suite("Audio creation session assembly", .serialized) @MainActor
struct AudioCreationSessionTests {
    private func fixture() throws -> (URL, UserDefaults, String) {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("audio-creation-session-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "D.AudioCreationCPU.\(UUID().uuidString)"
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }
    private func session(settings: UserDefaults, probe: AudioCreationCPUProbe = .init()) -> ProjectSession {
        ProjectSession(sessionFactory: { artifacts in
            let backend = AudioCreationCPUBackend(root: artifacts, probe: probe)
            let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 100))
            return WorkbenchSession(engine: runtime, backendID: "fixture.image", status: {
                let state = await runtime.snapshot()
                return .init(activeRunID: state.activeRunID, phase: state.phase?.rawValue, queuedRunIDs: state.queuedRunIDs)
            }, shutdown: { await runtime.shutdown() }, cleanup: {}, validateModel: { _ in },
            audioBackendID: backend.descriptor.id,
            validateAudioModel: { .init(directory: $0, revision: "CPU fixture; no weights loaded") })
        }, settings: settings, audioEnabled: true)
    }
    private func waitForIdle(_ subject: ProjectSession) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while subject.isBusy {
            try #require(ContinuousClock.now < deadline, "Audio task did not reach an authoritative terminal state")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test func generatedCandidateNeedsExplicitAdoptionAndDecisionsSurviveReopen() async throws {
        let (root, settings, suite) = try fixture()
        defer { settings.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Composition.dproject")
        let model = root.appendingPathComponent("FixtureModel")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false)
        let subject = session(settings: settings)
        await subject.createProject(at: project)
        await subject.createAudioCreation()
        await subject.registerAudioModel(at: model)
        let document = try #require(subject.activeDocumentID)
        let context = subject.audioCreationContextID
        var draft = try #require(subject.audioCreationDraft)
        draft.prompt = "中文 e\u{301} 👩‍💻 钢琴"
        draft.durationText = "0.02"
        draft.seedText = "4294967294"
        subject.updateAudioCreationDraft(draft, contextID: context, documentID: document)
        try #require(subject.canGenerateAudioCreation)
        await subject.generateAudioCreation(contextID: context, documentID: document)
        try await waitForIdle(subject)
        let job = try #require(subject.documentJobs.first)
        #expect(job.state == .completed)
        guard case .audio(let request) = job.request.input else { Issue.record("Wrong modality"); return }
        #expect(request.prompt == draft.prompt && request.seed == 4_294_967_294)
        let asset = try #require(subject.audioCreationCandidates.first)
        #expect(subject.activeDocument?.adoptedAssetID == nil)
        #expect(subject.activeDocument?.selectedAssetID == nil)
        await subject.mutateAudioCreationCandidate(.select(asset.id), contextID: context, documentID: document)
        #expect(subject.activeDocument?.adoptedAssetID == nil)
        await subject.mutateAudioCreationCandidate(.adopt(asset.id), contextID: context, documentID: document)
        #expect(subject.activeDocument?.adoptedAssetID == asset.id)
        await subject.mutateAudioCreationCandidate(.reject(asset.id, true), contextID: context, documentID: document)
        #expect(subject.activeDocument?.adoptedAssetID == nil)
        #expect(subject.audioCreationCandidates.count == 1)
        #expect(await subject.saveAudioCreation(contextID: context, documentID: document))
        #expect(await subject.cancelAndCloseProject())
        await subject.openProject(at: project)
        #expect(subject.activeDocumentID == document)
        #expect(subject.audioCreationDraft?.prompt == draft.prompt)
        #expect(subject.audioCreationDraft?.rejectedAssetIDs == [asset.id])
        #expect(subject.audioCreationCandidates.first?.id == asset.id)
        let newContext = subject.audioCreationContextID
        await subject.mutateAudioCreationCandidate(.reject(asset.id, false), contextID: newContext, documentID: document)
        await subject.mutateAudioCreationCandidate(.adopt(asset.id), contextID: newContext, documentID: document)
        let destination = root.appendingPathComponent("作品.wav")
        await subject.exportAudioCreationAsset(id: asset.id, to: destination, contextID: newContext, documentID: document)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: project.appendingPathComponent(asset.relativePath)))
        #expect(await subject.cancelAndCloseProject())
    }
    @Test func cancellationAndBackendErrorKeepAdoptedAudioAndReachReleasedTerminalState() async throws {
        let (root, settings, suite) = try fixture()
        defer { settings.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Cancellation.dproject")
        let model = root.appendingPathComponent("FixtureModel")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false)
        let probe = AudioCreationCPUProbe()
        let subject = session(settings: settings, probe: probe)
        await subject.createProject(at: project)
        await subject.createAudioCreation()
        await subject.registerAudioModel(at: model)
        let document = try #require(subject.activeDocumentID)
        let context = subject.audioCreationContextID
        var draft = try #require(subject.audioCreationDraft)
        draft.prompt = "Keep this adopted audio"
        draft.durationText = "0.02"
        subject.updateAudioCreationDraft(draft, contextID: context, documentID: document)
        await subject.generateAudioCreation(contextID: context, documentID: document)
        try await waitForIdle(subject)
        let original = try #require(subject.audioCreationCandidates.first)
        let originalURL = project.appendingPathComponent(original.relativePath)
        let originalBytes = try Data(contentsOf: originalURL)
        await subject.mutateAudioCreationCandidate(.adopt(original.id), contextID: context, documentID: document)

        draft = try #require(subject.audioCreationDraft)
        draft.prompt = "CPU wait for cancellation"
        subject.updateAudioCreationDraft(draft, contextID: context, documentID: document)
        await subject.generateAudioCreation(contextID: context, documentID: document)
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await probe.started.contains(draft.prompt)) {
            try #require(ContinuousClock.now < deadline, "Synthetic backend never started")
            try await Task.sleep(for: .milliseconds(10))
        }
        await subject.cancelAudioCreation(contextID: context, documentID: document)
        try await waitForIdle(subject)
        #expect(subject.documentJobs.contains { $0.state == .cancelled })
        #expect(await probe.releaseCount == 2)
        #expect(subject.activeDocument?.adoptedAssetID == original.id)
        #expect(subject.audioCreationCandidates.map(\.id) == [original.id])
        #expect(try Data(contentsOf: originalURL) == originalBytes)

        draft = try #require(subject.audioCreationDraft)
        draft.prompt = "CPU fail without output"
        subject.updateAudioCreationDraft(draft, contextID: context, documentID: document)
        await subject.generateAudioCreation(contextID: context, documentID: document)
        try await waitForIdle(subject)
        #expect(subject.documentJobs.contains { $0.state == .failed })
        #expect(await probe.releaseCount == 3)
        #expect(subject.activeDocument?.adoptedAssetID == original.id)
        #expect(subject.audioCreationCandidates.map(\.id) == [original.id])
        #expect(try Data(contentsOf: originalURL) == originalBytes)
        #expect(await subject.cancelAndCloseProject())
    }

    @Test func referenceVariationAndInpaintKeepOriginalAndPersistExactFrameInput() async throws {
        let (root, settings, suite) = try fixture()
        defer { settings.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Reference.dproject")
        let model = root.appendingPathComponent("FixtureModel")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false)
        let sourceURL = root.appendingPathComponent("原始参考.wav")
        let samples = (0..<882).map { Float($0 % 20) / 40 }
        try AudioTestMedia.writePCM(to: sourceURL, samples: [samples, samples], sampleRate: 44_100,
                                   bitDepth: 32, floatingPoint: true)
        let subject = session(settings: settings)
        await subject.createProject(at: project)
        await subject.registerAudioModel(at: model)
        try #require(await subject.importAudio(at: sourceURL, name: "原声"))
        let sourceAsset = try #require(subject.manifest?.assets.first(where: { $0.role == .original }))
        let ownedURL = project.appendingPathComponent(sourceAsset.relativePath)
        let originalBytes = try Data(contentsOf: ownedURL)
        var lastDocument: UUID?
        for operation in [AudioOperation.variation, .inpaint] {
            await subject.createAudioCreation(sourceAssetID: sourceAsset.id)
            let document = try #require(subject.activeDocumentID)
            lastDocument = document
            let context = subject.audioCreationContextID
            var draft = try #require(subject.audioCreationDraft)
            draft.operation = operation
            draft.prompt = "CPU reference \(operation.rawValue)"
            draft.durationText = "hidden, not an operative parameter"
            draft.strengthText = "0.4"
            draft.editRegion = operation == .inpaint ? .init(startFrame: 100, endFrame: 400) : nil
            subject.updateAudioCreationDraft(draft, contextID: context, documentID: document)
            await subject.generateAudioCreation(contextID: context, documentID: document)
            try await waitForIdle(subject)
            let job = try #require(subject.documentJobs.first)
            #expect(job.state == .completed)
            guard case .audio(let input) = job.request.input else { Issue.record("Wrong modality"); return }
            let frozen = try #require(input.source)
            #expect(input.operation == operation && input.durationSeconds == Double(882) / 44_100)
            #expect(input.diffusion?.strength == Float(0.4))
            #expect(frozen.sha256 == sourceAsset.metadata.audio?.contentSHA256)
            #expect(frozen.url.path == project.appendingPathComponent("AudioInputs/\(job.id.uuidString)/source.wav").path)
            #expect(try Data(contentsOf: frozen.url) == originalBytes)
            if operation == .inpaint {
                #expect(input.editRegion == AudioEditRegion(startFrame: 100, endFrame: 400))
            } else { #expect(input.editRegion == nil) }
            #expect(subject.activeDocument?.adoptedAssetID == nil)
            #expect(try Data(contentsOf: ownedURL) == originalBytes)
        }
        #expect(await subject.cancelAndCloseProject())
        await subject.openProject(at: project)
        #expect(subject.activeDocumentID == lastDocument)
        #expect(subject.audioCreationDraft?.operation == .inpaint)
        #expect(subject.audioCreationDraft?.editRegion == AudioFrameRange(startFrame: 100, endFrame: 400))
        #expect(subject.activeDocument?.sourceAssetID == sourceAsset.id)
        #expect(try Data(contentsOf: ownedURL) == originalBytes)
        #expect(await subject.cancelAndCloseProject())
        // This proves host/request/file ownership; synthetic output is not model inpaint quality evidence.
    }

    @Test func oldDocumentInputCannotOverwriteNewDocumentAndSaveFailurePreservesBothVersions() async throws {
        let (root, settings, suite) = try fixture()
        defer { settings.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Protected.dproject")
        let subject = session(settings: settings)
        await subject.createProject(at: project)
        await subject.createAudioCreation()
        let oldID = try #require(subject.activeDocumentID)
        let context = subject.audioCreationContextID
        var oldDraft = try #require(subject.audioCreationDraft)
        oldDraft.prompt = "旧文档不能覆盖新文档"
        await subject.createAudioCreation()
        let newID = try #require(subject.activeDocumentID)
        let newDraft = try #require(subject.audioCreationDraft)
        subject.updateAudioCreationDraft(oldDraft, contextID: context, documentID: oldID)
        #expect(subject.audioCreationDraft == newDraft)
        await subject.selectDocument(id: oldID)
        let reloaded = subject.audioCreationDraft
        #expect(subject.audioCreationContextID != context)
        subject.updateAudioCreationDraft(oldDraft, contextID: context, documentID: oldID)
        #expect(subject.audioCreationDraft == reloaded)
        await subject.selectDocument(id: newID)
        let currentContext = subject.audioCreationContextID
        var edited = newDraft
        edited.prompt = "需要保留的未保存内容"
        subject.updateAudioCreationDraft(edited, contextID: currentContext, documentID: newID)
        let manifestURL = project.appendingPathComponent("project.json")
        let original = try Data(contentsOf: manifestURL)
        var external = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var documents = try #require(external["documents"] as? [[String: Any]])
        let index = try #require(documents.firstIndex { ($0["id"] as? String)?.lowercased() == newID.uuidString.lowercased() })
        var storedDraft = try #require(documents[index]["audioCreation"] as? [String: Any])
        storedDraft["prompt"] = "另一个编辑器保存的作品条件"
        documents[index]["audioCreation"] = storedDraft
        external["documents"] = documents
        let changed = try JSONSerialization.data(withJSONObject: external, options: [.sortedKeys])
        try changed.write(to: manifestURL)
        #expect(!(await subject.saveAudioCreation(contextID: currentContext, documentID: newID)))
        #expect(subject.audioCreationDraft?.prompt == edited.prompt)
        #expect(try Data(contentsOf: manifestURL) == changed)
        #expect(subject.errorMessage != nil)
        // Restore only this test-owned simulated external edit so teardown can drain safely.
        try original.write(to: manifestURL)
        #expect(await subject.saveAudioCreation(contextID: currentContext, documentID: newID))
        #expect(await subject.cancelAndCloseProject())
    }
}
