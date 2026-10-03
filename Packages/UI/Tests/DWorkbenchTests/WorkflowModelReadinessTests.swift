import CryptoKit
import Darwin
import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor ReadinessEngine: InferenceEngine {
    private(set) var submissions = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        submissions += 1
        throw WorkflowIssue("Readiness checks must not generate")
    }
}

private actor ReadinessValidator {
    var calls = 0
    var suspendNext = false
    var failSuspended = true
    var pending: [CheckedContinuation<Void, Never>] = []
    func arm(fail: Bool = true) { suspendNext = true; failSuspended = fail }
    func finish() { if !pending.isEmpty { pending.removeFirst().resume() } }
    func validate() async throws {
        calls += 1
        if suspendNext {
            suspendNext = false
            let fail = failSuspended
            await withCheckedContinuation { pending.append($0) }
            if fail { throw WorkflowIssue("old inspection failed after a new installation was selected") }
        }
    }
    var waiting: Bool { !pending.isEmpty }
    var pendingCount: Int { pending.count }
}

@Suite(.serialized) @MainActor
struct WorkflowModelReadinessTests {
    @Test func selectionRefreshesReadinessAndPeerChoicesWithoutChangingDraftOrGraph() async throws {
        try await exercise(staleInspection: false)
    }
    @Test func olderReadinessFailureCannotOverwriteNewValidatedSelection() async throws {
        try await exercise(staleInspection: true)
    }

    @Test func coldDemandChecksOnlyRequestedInstallationAndCoalescesAcrossOwners() async throws {
        try await withColdFixture { fixture in
            let quick = await fixture.owner(at: "quick")
            let canvas = await fixture.owner(at: "canvas")
            let identity = fixture.identity
            await canvas.openWorkflow()
            canvas.workflow?.addNode(operationID: "d.image.generate", modelID: identity)
            #expect(canvas.openGraphModelIdentities == [identity])
            quick.refreshWorkflowModels()
            canvas.refreshWorkflowModels()
            #expect(quick.explicitModelReadiness[identity] == nil)
            #expect(canvas.explicitModelReadiness[identity] == nil)
            await quick.checkExplicitModelReadiness(for: ["image:missing"])
            #expect(quick.explicitModelReadiness[identity] == nil)
            #expect(quick.explicitModelReadiness["image:missing"] == .unavailable)
            #expect(await fixture.validator.calls == 0)

            await fixture.validator.arm(fail: false)
            let first = Task { await quick.checkExplicitModelReadiness(for: [identity]) }
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await fixture.validator.waiting) && ContinuousClock.now < deadline { await Task.yield() }
            try #require(await fixture.validator.waiting)
            let second = Task { await canvas.checkExplicitModelReadiness(for: [identity]) }
            #expect(quick.explicitModelChecking.contains(identity))
            #expect(quick.explicitModelReadiness[identity] == .unknown)
            while !canvas.explicitModelChecking.contains(identity) && ContinuousClock.now < deadline { await Task.yield() }
            try #require(canvas.explicitModelChecking.contains(identity))
            await fixture.validator.finish()
            await first.value; await second.value
            #expect(await fixture.validator.calls == 1)
            #expect(quick.explicitModelReadiness[identity] == .available)
            #expect(canvas.explicitModelReadiness[identity] == .available)
            await quick.checkExplicitModelReadiness(for: [identity])
            #expect(await fixture.validator.calls == 1, "Unchanged cold demand reuses successful readiness")
            #expect(await fixture.engine.submissions == 0)

            try Data(repeating: 0x41, count: fixture.bytes.count + 1).write(to: fixture.model.appendingPathComponent("weights.bin"))
            await quick.checkExplicitModelReadiness(for: [identity])
            #expect(quick.explicitModelReadiness[identity] == .unavailable,
                    "A changed required file must revoke the cached ready state")
            #expect(await fixture.engine.submissions == 0)
            #expect(await quick.requestClose())
            #expect(await canvas.requestClose())
        }
    }

    @Test func successfulValidationCannotPublishAfterFilesChange() async throws {
        try await withColdFixture { fixture in
            let owner = await fixture.owner(at: "stale")
            owner.refreshWorkflowModels()
            await fixture.validator.arm(fail: false)
            let check = Task { await owner.checkExplicitModelReadiness(for: [fixture.identity]) }
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await fixture.validator.waiting) && ContinuousClock.now < deadline { await Task.yield() }
            try #require(await fixture.validator.waiting)
            try Data(repeating: 0x42, count: fixture.bytes.count + 1).write(to: fixture.model.appendingPathComponent("weights.bin"))
            await fixture.validator.finish()
            await check.value
            #expect(owner.explicitModelReadiness[fixture.identity] == .unavailable)
            #expect(owner.explicitModelIssues[fixture.identity] != nil)
            #expect(await fixture.engine.submissions == 0)
            #expect(await owner.requestClose())
        }
    }

    @Test func legacyStampRevokesSameInodeSameSizeAndRestoredMtime() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("legacy-stamp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("weights.bin")
        try Data("AAAA".utf8).write(to: file)
        let first = try WorkflowModelReadiness.stamps(in: root)
        var before = stat()
        try #require(lstat(file.path, &before) == 0)
        let key = WorkflowModelReadiness.Key(bookmark: Data([1]), identity: "image:legacy-stamp")
        var validations = 0
        try await WorkflowModelReadiness.check(key, stamps: first, force: false) { validations += 1 }
        #expect(WorkflowModelReadiness.hasSuccess(key, stamps: first))
        try await Task.sleep(for: .milliseconds(20))
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: Data("BBBB".utf8))
        try writer.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        try #require(utimensat(AT_FDCWD, file.path, &times, 0) == 0)
        var after = stat()
        try #require(lstat(file.path, &after) == 0)
        #expect(before.st_ino == after.st_ino && before.st_size == after.st_size)
        #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
                before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
        let changed = try WorkflowModelReadiness.stamps(in: root)
        #expect(first != changed, "ctime must revoke the legacy success despite restored mtime")
        #expect(!WorkflowModelReadiness.hasSuccess(key, stamps: changed))
        try await WorkflowModelReadiness.check(key, stamps: changed, force: false) { validations += 1 }
        #expect(validations == 2)
        WorkflowModelReadiness.invalidate(key)
    }

    @Test func cancelledReadinessRequestClearsItsCheckingState() async throws {
        try await withColdFixture { fixture in
            let owner = await fixture.owner(at: "cancelled")
            owner.refreshWorkflowModels()
            await fixture.validator.arm(fail: false)
            let check = Task { await owner.checkExplicitModelReadiness(for: [fixture.identity]) }
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await fixture.validator.waiting) && ContinuousClock.now < deadline { await Task.yield() }
            try #require(await fixture.validator.waiting)
            #expect(owner.explicitModelChecking.contains(fixture.identity))
            check.cancel()
            await fixture.validator.finish()
            await check.value
            #expect(!owner.explicitModelChecking.contains(fixture.identity))
            #expect(owner.explicitModelReadiness[fixture.identity] != .available)
            #expect(await fixture.engine.submissions == 0)
            #expect(await owner.requestClose())
        }
    }

    @Test(arguments: [false, true])
    func canvasOldInstallationCannotPublishAfterQuickRebind(oldFails: Bool) async throws {
        try await withColdFixture { fixture in
            let second = fixture.root.appendingPathComponent("other-model")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try fixture.bytes.write(to: second.appendingPathComponent("weights.bin"))
            let oldID = try #require(try WorkflowModelBookmarks(settings: fixture.settings).installation(for: fixture.identity))
            let newID = try await fixture.library.registerExisting(at: second, catalogID: ModelCatalog.flux2ID)
            #expect(newID != oldID)
            let quick = await fixture.owner(at: "quick-rebind")
            let canvas = await fixture.owner(at: "canvas-rebind")
            canvas.refreshWorkflowModels()
            await fixture.validator.arm(fail: oldFails)
            let old = Task { await canvas.checkExplicitModelReadiness(for: [fixture.identity]) }
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await fixture.validator.waiting) && ContinuousClock.now < deadline { await Task.yield() }
            try #require(await fixture.validator.waiting)
            #expect(canvas.explicitModelChecking.contains(fixture.identity))
            _ = try await quick.selectWorkflowInstallation(id: newID)
            #expect(quick.workflowInstallationID(for: fixture.identity) == newID)
            await fixture.validator.arm(fail: false)
            let newer = Task { await canvas.checkExplicitModelReadiness() }
            let newerDeadline = ContinuousClock.now + .seconds(3)
            while (await fixture.validator.pendingCount) < 2 && ContinuousClock.now < newerDeadline { await Task.yield() }
            try #require(await fixture.validator.pendingCount == 2)
            await fixture.validator.finish()
            await old.value
            #expect(canvas.explicitModelReadiness[fixture.identity] != .available)
            #expect(canvas.explicitModelChecking.contains(fixture.identity),
                    "An old completion must not clear the newer request's indicator")
            await fixture.validator.finish()
            await newer.value
            #expect(canvas.explicitModelReadiness[fixture.identity] == .available)
            #expect(!canvas.explicitModelChecking.contains(fixture.identity))
            #expect(await fixture.engine.submissions == 0)
            #expect(await quick.requestClose())
            #expect(await canvas.requestClose())
        }
    }

    @Test(arguments: [false, true])
    func canvasOldResultCannotPublishWhenSharedBindingChanges(oldFails: Bool) async throws {
        try await withColdFixture { fixture in
            let second = fixture.root.appendingPathComponent("replacement")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try fixture.bytes.write(to: second.appendingPathComponent("weights.bin"))
            let newID = try await fixture.library.registerExisting(at: second, catalogID: ModelCatalog.flux2ID)
            let quick = await fixture.owner(at: "quick-binding")
            let canvas = await fixture.owner(at: "canvas-binding")
            canvas.refreshWorkflowModels()
            await fixture.validator.arm(fail: oldFails)
            let old = Task { await canvas.checkExplicitModelReadiness(for: [fixture.identity]) }
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await fixture.validator.waiting) && ContinuousClock.now < deadline { await Task.yield() }
            try #require(await fixture.validator.waiting)
            _ = try await quick.selectWorkflowInstallation(id: newID)
            await fixture.validator.finish()
            await old.value
            #expect(canvas.explicitModelReadiness[fixture.identity] != .available)
            #expect(!canvas.explicitModelChecking.contains(fixture.identity))
            await canvas.checkExplicitModelReadiness(for: [fixture.identity])
            #expect(canvas.explicitModelReadiness[fixture.identity] == .available)
            #expect(await fixture.engine.submissions == 0)
            #expect(await quick.requestClose())
            #expect(await canvas.requestClose())
        }
    }

    @Test func rawInstallationIsUnpreparedWithoutSubmittingOrValidating() async throws {
        try await withColdFixture { fixture in
            let owner = await fixture.owner(at: "raw")
            owner.refreshWorkflowModels()
            let actual = await fixture.library.snapshot()
            var records = actual.records
            try #require(!records.isEmpty)
            records[0].state = .preparationRequired
            owner.observeModelAvailability(.init(revision: actual.revision + 1, rootURL: actual.rootURL,
                catalog: actual.catalog, records: records, downloadCredentialConnected: actual.downloadCredentialConnected,
                copyProgress: actual.copyProgress))
            #expect(owner.explicitModelReadiness[fixture.identity] == .unprepared)
            #expect(await fixture.validator.calls == 0)
            #expect(await fixture.engine.submissions == 0)
            #expect(await owner.requestClose())
        }
    }

    @MainActor private struct ColdFixture {
        let root: URL
        let model: URL
        let bytes: Data
        let identity: String
        let library: ModelLibrary
        let settings: UserDefaults
        let engine: ReadinessEngine
        let validator: ReadinessValidator
        func owner(at name: String) async -> ProjectSession {
            let result = ProjectSession(sessionFactory: { _ in
                WorkbenchSession(engine: engine, backendID: "fixture.image",
                    status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                    shutdown: {}, cleanup: {}, validateModel: { _ in try await validator.validate() })
            }, settings: settings, modelLibrary: library)
            await result.createProject(at: root.appendingPathComponent(name + ".dproject"))
            return result
        }
    }

    private func withColdFixture(_ body: @MainActor (ColdFixture) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("cold-readiness-" + UUID().uuidString)
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let bytes = Data("controlled CPU weights".utf8)
        try bytes.write(to: model.appendingPathComponent("weights.bin"))
        let realEntry = try ModelCatalog.flux2()
        let entry = ModelCatalogEntry(id: realEntry.id, title: "Cold Klein registration", repository: "fixture/klein",
            revision: realEntry.revision,
            files: [.init(path: "weights.bin", size: UInt64(bytes.count),
                          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
            imageProfile: .flux2Klein, workflowProfileID: "d.image.generate")
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("library"), catalog: [entry])
        let id = try await library.registerExisting(at: model, catalogID: entry.id)
        let identity = "image:" + entry.revision
        let suite = "D.ColdReadiness." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        try WorkflowModelBookmarks(settings: settings).rememberInstallation(identity: identity, id: id)
        let fixture = ColdFixture(root: root, model: model, bytes: bytes, identity: identity,
                                  library: library, settings: settings, engine: ReadinessEngine(), validator: ReadinessValidator())
        do { try await body(fixture) }
        catch { try? await library.shutdown(); throw error }
        try await library.shutdown()
    }

    private func exercise(staleInspection: Bool) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("readiness-" + UUID().uuidString)
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let bytes = Data("controlled CPU weights".utf8)
        try bytes.write(to: model.appendingPathComponent("weights.bin"), options: .withoutOverwriting)
        let realEntry = try ModelCatalog.flux2()
        let entry = ModelCatalogEntry(id: realEntry.id, title: "Controlled Klein registration", repository: "fixture/klein",
            revision: realEntry.revision,
            files: [.init(path: "weights.bin", size: UInt64(bytes.count),
                          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
            imageProfile: .flux2Klein, workflowProfileID: "d.image.generate")
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("library"), catalog: [entry])
        let beforeRegistration = await library.snapshot()
        let id = try await library.registerExisting(at: model, catalogID: entry.id)
        let suite = "D.Readiness." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let engine = ReadinessEngine(), validator = ReadinessValidator()
        func owner() -> ProjectSession {
            ProjectSession(sessionFactory: { _ in
                WorkbenchSession(engine: engine, backendID: "fixture.image",
                    status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                    shutdown: {}, cleanup: {}, validateModel: { _ in try await validator.validate() })
            }, settings: settings, modelLibrary: library)
        }
        let quickOwner = owner(), canvasOwner = owner()
        await quickOwner.createProject(at: root.appendingPathComponent("quick.dproject"))
        await canvasOwner.createProject(at: root.appendingPathComponent("canvas.dproject"))
        await canvasOwner.openWorkflow()
        let controller = try #require(canvasOwner.workflow)
        controller.addNode(operationID: "d.image.generate")
        let selected = controller.selectedNodeID
        let graph = controller.graph
        let quick = QuickGenerationController(store: try #require(quickOwner.currentStore),
            makeServices: { try quickOwner.makeExplicitOperationServices() })
        await quick.load()
        quick.select(operationID: "d.image.generate", modelID: "")
        let draft = try #require(quick.draft)
        quick.setParameter("promptText", value: .text("未完成的草稿 e\u{301} 👩🏽‍🎨"), draftID: draft.id)
        let expectedDraft = quick.draft
        let choice = try await quickOwner.selectWorkflowInstallation(id: id)
        #expect(quickOwner.explicitModelReadiness[choice.id] == .available)
        quickOwner.observeModelAvailability(beforeRegistration)
        #expect(quickOwner.explicitModelReadiness[choice.id] == .available,
                "A delayed snapshot from before registration cannot revoke the new validated selection")
        #expect(await validator.calls == 1, "A successful registration must not require a second content verification")
        if staleInspection {
            await validator.arm()
            let old = Task { await quickOwner.checkExplicitModelReadiness() }
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await validator.waiting) && ContinuousClock.now < deadline { await Task.yield() }
            try #require(await validator.waiting)
            _ = try await quickOwner.selectWorkflowInstallation(id: id)
            await validator.finish()
            await old.value
            #expect(quickOwner.explicitModelReadiness[choice.id] == .available)
            #expect(quickOwner.explicitModelIssues[choice.id] == nil)
            #expect(!quickOwner.explicitModelChecking.contains(choice.id))
        }
        canvasOwner.refreshWorkflowModels()
        #expect(controller.modelChoices.contains { $0.id == choice.id })
        #expect(canvasOwner.workflow === controller && controller.graph == graph && controller.selectedNodeID == selected)
        #expect(quick.draft == expectedDraft)
        #expect(await engine.submissions == 0)
        #expect(await library.snapshot().records.first?.activeLeaseCount == 0)
        try await library.remove(id)
        quickOwner.observeModelAvailability(await library.snapshot())
        #expect(quickOwner.explicitModelReadiness[choice.id] == .unavailable)
        #expect(quick.draft == expectedDraft && controller.graph == graph)
        #expect(try Data(contentsOf: model.appendingPathComponent("weights.bin")) == bytes)
        try await quick.flush()
        #expect(await quickOwner.requestClose())
        #expect(await canvasOwner.requestClose())
        try await library.shutdown()
    }
}
