import DInference
import Foundation
import Testing
@testable import UI

private actor CloseTransactionGate {
    private(set) var reached = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        reached = true
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CloseRecordingEngine: InferenceEngine {
    private(set) var submissions: [InferenceRequest] = []
    private(set) var isClosed = false

    func submit(_ request: InferenceRequest, backendID: String) throws -> InferenceRun {
        guard !isClosed else { throw InferenceFailure.runtimeClosed }
        submissions.append(request)
        return InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() },
                            cancel: {}, outcome: { .cancelled })
    }

    func shutdown() { isClosed = true }
}

private actor FailFirstCleanup {
    private var shouldFail = true
    func perform() throws {
        if shouldFail {
            shouldFail = false
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}

@Suite(.serialized) @MainActor
struct WorkbenchModelConcurrencyTests {
    private func directory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let folder = base.appendingPathComponent("close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for the close transaction checkpoint")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func idleCloseKeepsAdmissionLockedThroughSuspendedShutdown() async throws {
        let folder = try directory()
        let suite = "D.WorkbenchCloseTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer {
            settings.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let engine = CloseRecordingEngine()
        let shutdown = CloseTransactionGate()
        let subject = WorkbenchModel(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "test.close", status: {
                WorkbenchRuntimeStatus(activeRunID: nil, phase: nil, queuedRunIDs: [])
            }, shutdown: {
                await shutdown.arriveAndWait()
                await engine.shutdown()
            }, cleanup: {}, validateModel: { _ in })
        }, settings: settings)
        await subject.createProject(at: folder.appendingPathComponent("Idle.dproject"))
        try #require(subject.manifest != nil, Comment(rawValue: subject.errorMessage ?? "Project did not open"))
        await subject.registerModel(at: folder)
        subject.prompt = "Must never enter inference during close"
        #expect(subject.canGenerate)

        let closing = Task { await subject.requestClose() }
        try await waitUntil { await shutdown.reached }
        #expect(subject.isChangingProject)
        #expect(!subject.canGenerate)
        await subject.generate()
        #expect(await engine.submissions.isEmpty)
        #expect(subject.manifest?.jobs.isEmpty == true)

        await shutdown.open()
        #expect(await closing.value)
        #expect(subject.manifest == nil)
        #expect(await engine.isClosed)
    }

    @Test func cleanupFailureLeavesRuntimeUsableAndCloseCanBeRetried() async throws {
        let folder = try directory()
        let suite = "D.WorkbenchCloseTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer {
            settings.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let engine = CloseRecordingEngine()
        let cleanup = FailFirstCleanup()
        let subject = WorkbenchModel(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "test.close", status: {
                WorkbenchRuntimeStatus(activeRunID: nil, phase: nil, queuedRunIDs: [])
            }, shutdown: { await engine.shutdown() },
            cleanup: { try await cleanup.perform() }, validateModel: { _ in })
        }, settings: settings)
        await subject.createProject(at: folder.appendingPathComponent("Retry.dproject"))
        try #require(subject.manifest != nil, Comment(rawValue: subject.errorMessage ?? "Project did not open"))
        await subject.registerModel(at: folder)
        subject.prompt = "Retry after a close failure"

        #expect(await subject.requestClose() == false)
        #expect(subject.errorMessage != nil)
        #expect(subject.manifest != nil)
        #expect(await engine.isClosed == false)
        #expect(subject.canGenerate)

        subject.clearError()
        await subject.generate()
        try await waitUntil { !subject.isBusy }
        #expect(await engine.submissions.count == 1)
        #expect(subject.manifest?.jobs.first?.state == .cancelled)
        #expect(subject.errorMessage == nil)
        #expect(await subject.requestClose())
        #expect(subject.manifest == nil)
        #expect(await engine.isClosed)
    }
}
