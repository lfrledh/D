import CryptoKit
import Darwin
import DInference
import Foundation
import Synchronization
import Testing
@testable import DWorkbench

@Suite(.serialized)
struct DownloadManagementTests {
    private func wait(_ library: ModelLibrary, _ condition: (ModelLibrarySnapshot) -> Bool) async throws -> ModelLibrarySnapshot {
        for _ in 0..<500 {
            let value = await library.snapshot()
            if condition(value) { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ModelLibraryError.storage("Fixture condition timed out")
    }
    private func entry(_ f: LibraryFixture, id: String, preparation: ModelPreparation = .none, single: Bool = false) -> ModelCatalogEntry {
        .init(id: id, title: id, repository: "fixture/" + id, revision: f.entry.revision,
              files: single ? [f.entry.files[0]] : f.entry.files, imageProfile: .flux2Klein, preparation: preparation)
    }
    private func library(_ f: LibraryFixture, transport: FixtureTransfer, catalog: [ModelCatalogEntry]? = nil,
                         fault: FixtureFault = FixtureFault(), clock: FixtureClock? = nil) async throws -> ModelLibrary {
        try await ModelLibrary(stateDirectory: f.state, catalog: catalog ?? [f.entry], transport: transport,
            now: { clock?.now ?? Date() }, sleepUntil: { deadline in
                if let clock { try await clock.sleep(until: deadline) }
                else { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            }, checkpoint: { try fault.check($0) })
    }

    @Test(arguments: [ModelDownloadPostAction.filesOnly, .register])
    func downloadIntentAndHistoryAreIndependent(intent: ModelDownloadPostAction) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transport = FixtureTransfer(f.contents), library = try await self.library(f, transport: transport)
        try await library.configureRoot(at: f.destination)
        let task = try await library.enqueueDownloads([f.entry.id], postAction: intent)[0]
        let done = try await wait(library) { $0.downloads.first?.state == .completed }
        let resource = try #require(done.resources.first)
        #expect(resource.control.fileState == .verified)
        #expect(resource.record.registrationState == (intent == .register ? .registered : .unregistered))
        if intent == .filesOnly { await #expect(throws: ModelLibraryError.self) { try await library.acquire(resource.record.id) } }
        let count = await transport.requests
        try await library.reverifyResource(resource.id)
        #expect(await library.snapshot().records[0].registrationState == resource.record.registrationState)
        try await library.registerResource(resource.id)
        let lease = try await library.acquire(resource.record.id)
        await #expect(throws: ModelLibraryError.self) { try await library.deleteOwnedCopy(resource.id) }
        await #expect(throws: ModelLibraryError.self) { try await library.unregister(resource.record.id) }
        await library.release(lease)
        try await library.clearDownloadHistory([task.id])
        #expect(await library.snapshot().downloads.isEmpty)
        #expect(await library.snapshot().resources[0].control.origin == .download)
        try await library.unregister(resource.record.id)
        await #expect(throws: ModelLibraryError.self) { try await library.acquireKnownResource(lease.reference) }
        await #expect(throws: ModelLibraryError.self) { try await library.acquireKnownResource(.init(directory: lease.reference.directory)) }
        await #expect(throws: ModelLibraryError.self) { try await library.acquireKnownResource(.init(directory: lease.reference.directory, revision: "wrong")) }
        try await library.registerResource(resource.id)
        _ = try await library.enqueueDownloads([f.entry.id])
        #expect(await transport.requests == count)
        #expect(try ModelDirectory(lease.reference.directory).verify(f.entry.files).count == 2)
        try await library.shutdown()
    }
    @Test func preparedPostActionDoesNotBlockNextDownload() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transport = FixtureTransfer(f.contents)
        let library = try await self.library(f, transport: transport, catalog: [entry(f, id: "raw", preparation: .required), entry(f, id: "ready")])
        try await library.configureRoot(at: f.destination)
        _ = try await library.enqueueDownloads(["raw", "ready"], postAction: .register)
        let done = try await wait(library) { $0.downloads.count == 2 && $0.downloads.allSatisfy { $0.state == .completed } }
        #expect(done.downloads[0].postActionError != nil)
        #expect(done.resources[0].record.registrationState == .pending)
        #expect(done.resources[1].record.registrationState == .registered)
        #expect(await transport.maximumActive <= 2)
        try await library.shutdown()
    }
    @Test func busyQueuePersistsDeduplicatesAndReordersWithoutPreemption() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transport = FixtureTransfer(f.contents, gated: true)
        let catalog = [entry(f, id: "a"), entry(f, id: "b"), entry(f, id: "c")]
        let library = try await self.library(f, transport: transport, catalog: catalog)
        try await library.configureRoot(at: f.destination)
        let a = try await library.enqueueDownloads(["a"])[0]
        _ = try await wait(library) { $0.downloads.first?.attempts == 1 }
        let rest = try await library.enqueueDownloads(["b", "c"])
        let duplicate = try await library.enqueueDownloads(["a", "b"])
        #expect(duplicate.map(\.id) == [a.id, rest[0].id])
        try await library.moveWaitingDownload(rest[1].id, before: rest[0].id)
        let bytes = try Data(contentsOf: f.state.appendingPathComponent("index.json"))
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((object["downloads"] as? [[String: Any]])?.count == 3)
        await #expect(throws: ModelLibraryError.self) { try await library.moveWaitingDownload(a.id, before: rest[0].id) }
        await #expect(throws: ModelLibraryError.self) { try await library.clearDownloadHistory([a.id]) }
        #expect(await library.snapshot().downloads.filter { $0.id != a.id }.allSatisfy { $0.attempts == 0 })
        #expect(await transport.requestedRepositories.allSatisfy { $0 == "/fixture/a" })
        await transport.openGate()
        let done = try await wait(library) { $0.downloads.allSatisfy { $0.state == .completed } }
        var order: [String] = []
        for value in await transport.requestedRepositories where order.last != value { order.append(value) }
        #expect(order == ["/fixture/a", "/fixture/c", "/fixture/b"])
        #expect(done.downloads.map(\.catalogID) == ["a", "c", "b"])
        #expect(await transport.maximumActive <= 2)
        try await library.shutdown()
    }
    @Test(arguments: [false, true], [false, true])
    func cancelDrainClearAndContinueKeepControl(discard: Bool, lateFailure: Bool) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transport = FixtureTransfer(f.contents, gated: true, transient: lateFailure)
        var owner: ModelLibrary? = try await self.library(f, transport: transport)
        let id: ModelResourceID
        do {
            let library = try #require(owner)
            try await library.configureRoot(at: f.destination)
            let task = try await library.enqueueDownloads([f.entry.id])[0]; id = task.resourceID
            while await transport.requests == 0 { await Task.yield() }
            let cancelling = Task { try await library.cancelDownload(task.id, keepPartial: !discard) }
            _ = try await wait(library) { $0.downloads[0].state == .cancelled }
            await #expect(throws: ModelLibraryError.self) { try await library.clearDownloadHistory([task.id]) }
            let pausing = Task { try await library.pauseQueue() } // newer decision must win
            await Task.yield()
            await transport.openGate(); try await cancelling.value; try await pausing.value
            #expect(await library.snapshot().queueState == .paused)
            #expect(await library.snapshot().downloads[0].state == .cancelled)
            #expect(await library.snapshot().resources[0].record.registrationState == .unregistered)
            #expect(await library.snapshot().downloads[0].automaticRetries == 0)
            #expect(await library.snapshot().downloads[0].error == nil)
            try await library.clearDownloadHistory([task.id])
            #expect(await library.snapshot().downloads.isEmpty)
            try await library.shutdown()
        }
        owner = nil
        await transport.clearFailure()
        let reopened = try await self.library(f, transport: transport)
        let before = await transport.requests
        try await Task.sleep(for: .milliseconds(40)); #expect(await transport.requests == before)
        #expect(await reopened.snapshot().queueState == .waitingForResume)
        if discard { #expect(await reopened.snapshot().resources[0].control.fileState == .deleted) }
        else {
            let next = try await reopened.continuePartial(id)
            #expect(next.resourceID == id)
            _ = try await wait(reopened) { $0.downloads.first?.state == .completed }
        }
        try await reopened.shutdown()
    }
    @Test func individualPauseDoesNotResumeWithQueue() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transport = FixtureTransfer(f.contents, gated: true)
        let library = try await self.library(f, transport: transport, catalog: [entry(f, id: "a"), entry(f, id: "b")])
        try await library.configureRoot(at: f.destination)
        let tasks = try await library.enqueueDownloads(["a", "b"])
        while await transport.requests == 0 { await Task.yield() }
        let pause = Task { try await library.pauseDownload(tasks[0].id) }
        _ = try await wait(library) { $0.downloads[0].state == .paused }
        await transport.openGate(); try await pause.value
        _ = try await wait(library) { $0.downloads[1].state == .completed }
        try await library.resumeQueue()
        #expect(await library.snapshot().downloads[0].state == .paused)
        try await library.shutdown()
    }
    @Test func retryDeadlinesAreBoundedAndSurviveHistoryRemoval() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let clock = FixtureClock(), transport = FixtureTransfer(f.contents, transient: true)
        let library = try await self.library(f, transport: transport, catalog: [entry(f, id: "retry", single: true)], clock: clock)
        try await library.configureRoot(at: f.destination)
        _ = try await library.enqueueDownloads(["retry"])
        for retry in 1...3 {
            let waiting = try await wait(library) { $0.downloads[0].state == .waitingRetry && $0.downloads[0].automaticRetries == retry }
            let deadline = try #require(waiting.downloads[0].earliestRetry)
            #expect(deadline.timeIntervalSince(clock.now) == [2.0, 5.0, 15.0][retry - 1])
            clock.advance(to: deadline)
        }
        let failed = try await wait(library) { $0.downloads[0].state == .failed }
        #expect(failed.downloads[0].attempts == 4)
        #expect(await transport.requests == 4)
        try await library.shutdown()
    }
    @Test func retryAfterRemainsInResourceAfterCancelAndClear() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let clock = FixtureClock(), deadline = clock.now.addingTimeInterval(7200)
        let transport = FixtureTransfer(f.contents, transient: true, retryAfter: deadline)
        let library = try await self.library(f, transport: transport, catalog: [entry(f, id: "retry", single: true)], clock: clock)
        try await library.configureRoot(at: f.destination)
        let task = try await library.enqueueDownloads(["retry"])[0]
        _ = try await wait(library) { $0.downloads[0].state == .failed }
        try await library.clearDownloadHistory([task.id])
        await #expect(throws: ModelLibraryError.self) { try await library.continuePartial(task.resourceID) }
        #expect(await transport.requests == 1)
        try await library.shutdown()
    }
    @Test(arguments: ["completion.beforeWrite", "registration.beforeWrite"])
    func completionAndRegistrationSaveFailuresStayDistinct(point: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fault = FixtureFault(), transport = FixtureTransfer(f.contents, gated: true)
        let library = try await self.library(f, transport: transport, fault: fault)
        try await library.configureRoot(at: f.destination)
        _ = try await library.enqueueDownloads([f.entry.id], postAction: .register)
        fault.arm(point); await transport.openGate()
        let stopped = try await wait(library) { $0.queueError != nil && $0.downloads[0].state != .downloading }
        #expect(stopped.resources[0].control.fileState == .verified)
        if point.hasPrefix("completion") { #expect(stopped.downloads[0].state != .completed) }
        else { #expect(stopped.downloads[0].state == .completed); #expect(stopped.downloads[0].postActionError != nil) }
        await #expect(throws: ModelLibraryError.self) { try await library.acquire(stopped.records[0].id) }
        fault.clear(); try await library.shutdown()
    }
    @Test(arguments: ["deleteIntent.beforeWrite", "deleteIntent.afterRename", "delete.unlink.weights/payload.bin", "deleteResult.beforeWrite"])
    func deletionIntentAndTombstoneSurviveFailures(point: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fault = FixtureFault(), transport = FixtureTransfer(f.contents)
        var owner: ModelLibrary? = try await self.library(f, transport: transport, fault: fault)
        var resource: ModelResource!
        do {
            let library = try #require(owner)
            try await library.configureRoot(at: f.destination)
            _ = try await library.enqueueDownloads([f.entry.id], postAction: .register)
            resource = try await wait(library) { $0.downloads[0].state == .completed }.resources[0]
            fault.arm(point)
            await #expect(throws: (any Error).self) { try await library.deleteOwnedCopy(resource.id) }
            if point.hasPrefix("deleteIntent") {
                #expect(try ModelDirectory(resource.record.directory!).verify(f.entry.files).count == 2)
                // The same still-failing intent must also block a second destructive call.
                await #expect(throws: (any Error).self) { try await library.deleteOwnedCopy(resource.id) }
                #expect(try ModelDirectory(resource.record.directory!).verify(f.entry.files).count == 2)
            }
            fault.clear()
        }
        // No shutdown: cold-read exactly the failed operation's persisted state.
        owner = nil
        let reopened = try await self.library(f, transport: transport, fault: fault)
        try await reopened.deleteOwnedCopy(resource.id)
        let done = await reopened.snapshot()
        #expect(done.resources[0].record.registrationState == .registered)
        #expect(done.resources[0].control.fileState == .deleted)
        #expect(done.downloads[0].state == .completed)
        await #expect(throws: ModelLibraryError.self) { try await reopened.acquire(resource.record.id) }
        #expect(!FileManager.default.fileExists(atPath: resource.record.directory!.path))
        try await reopened.shutdown()
    }
    @Test func externalRebindPreservesRevocationAndExplicitRegistrationRestoresIt() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let library = try await f.library()
        let id = try await library.registerExisting(at: f.source, catalogID: f.entry.id)
        try await library.unregister(id)
        try await library.rebind(id, to: f.source)
        #expect(await library.snapshot().records[0].registrationState == .unregistered)
        #expect(try await library.registerExisting(at: f.source, catalogID: f.entry.id) == id)
        let lease = try await library.acquire(id)
        await #expect(throws: ModelLibraryError.self) { try await library.unregister(id) }
        await library.release(lease)
        await #expect(throws: ModelLibraryError.self) { try await library.deleteOwnedCopy(.init(rawValue: id.rawValue)) }
        try await library.shutdown()
    }
    @Test(arguments: ["installed", "preparationRequired", "registered", "queued", "downloading", "pausing", "verifying", "publishing", "paused", "failed"])
    func legacyMigrationPreservesExactBytesAndDoesNotDownload(state: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        var owner: ModelLibrary? = try await f.library()
        let id = try await owner!.registerExisting(at: f.source, catalogID: f.entry.id)
        try await owner!.shutdown(); owner = nil
        let index = f.state.appendingPathComponent("index.json")
        let current = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var oldRecord = try #require((current["records"] as? [[String: Any]])?.first)
        oldRecord.removeValue(forKey: "control"); oldRecord.removeValue(forKey: "deletion")
        var record = try #require(oldRecord["record"] as? [String: Any]); record["state"] = state; record.removeValue(forKey: "registrationState")
        oldRecord["record"] = record
        var legacy: [String: Any] = ["schemaVersion": 1, "libraryID": current["libraryID"]!, "revision": current["revision"]!, "records": [oldRecord]]
        for key in ["rootBookmark", "rootURL", "rootIdentity", "downloadCredentialBookmark"] { legacy[key] = current[key] }
        let original = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]); try original.write(to: index)
        let transport = FixtureTransfer(f.contents), migrated = try await self.library(f, transport: transport)
        let result = await migrated.snapshot()
        #expect(result.records[0].id == id)
        #expect(result.records[0].registrationState == (state == "installed" ? .registered : .unregistered))
        #expect(result.resources[0].control.lastVerified == nil)
        #expect(try Data(contentsOf: f.state.appendingPathComponent("index.v1.backup.json")) == original)
        #expect(await transport.requests == 0)
        let before = try Data(contentsOf: index)
        for _ in 0..<100 { _ = await migrated.snapshot() }
        #expect(try Data(contentsOf: index) == before)
        try await migrated.shutdown()
    }
    @Test func enqueueBatchFailureLeavesNoUncommittedResource() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transfer = FixtureTransfer(f.contents), library = try await self.library(f, transport: transfer)
        try await library.configureRoot(at: f.destination)
        await #expect(throws: ModelLibraryError.self) { try await library.enqueueDownloads([f.entry.id, "not-catalog"]) }
        #expect(await library.snapshot().resources.isEmpty)
        #expect(await library.snapshot().downloads.isEmpty)
        #expect(await transfer.requests == 0)
        try await library.shutdown()
    }
}

private final class FixtureFault: Sendable {
    private let point = Mutex<String?>(nil)
    func arm(_ value: String) { point.withLock { $0 = value } }
    func clear() { point.withLock { $0 = nil } }
    func check(_ value: String) throws {
        if point.withLock({ $0 == value }) { throw ModelLibraryError.storage("Injected " + value) }
    }
}
private actor FixtureTransfer: ModelRangeTransport {
    let contents: [String: Data]
    var gated: Bool
    var transient: Bool
    let retryAfter: Date?
    var requests = 0
    var requestedRepositories: [String] = []
    var active = 0
    var maximumActive = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ contents: [String: Data], gated: Bool = false, transient: Bool = false, retryAfter: Date? = nil) {
        self.contents = contents; self.gated = gated; self.transient = transient; self.retryAfter = retryAfter
    }
    func download(_ range: ModelByteRange, to descriptor: Int32) async throws {
        requestedRepositories.append(range.url.path.components(separatedBy: "/resolve/")[0])
        requests += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if gated { await withCheckedContinuation { waiters.append($0) } } // deliberately returns late after cancellation
        if transient { throw ModelTransientDownloadError(status: 503, retryAfter: retryAfter) }
        guard let value = contents.first(where: { range.url.path.hasSuffix($0.key) })?.value else { throw ModelLibraryError.download("Fixture file missing") }
        try ModelDirectory.write(value.subdata(in: Int(range.start)..<Int(range.end + 1)), to: descriptor)
        guard fsync(descriptor) == 0 else { throw ModelDirectory.failure("Fixture fsync") }
    }
    func clearFailure() { transient = false }
    func openGate() { gated = false; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}
private final class FixtureClock: Sendable {
    private struct State {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var waits: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
        var cancelled: Set<UUID> = []
    }
    private let state = Mutex(State())
    var now: Date { state.withLock { $0.now } }
    func advance(to date: Date) {
        let ready = state.withLock { value in
            value.now = date
            let ids = value.waits.filter { $0.value.0 <= date }.map(\.key)
            return ids.compactMap { value.waits.removeValue(forKey: $0)?.1 }
        }
        for waiter in ready { waiter.resume() }
    }
    func sleep(until date: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { value -> Int in
                    if value.cancelled.remove(id) != nil { return -1 }
                    if date <= value.now { return 1 }
                    value.waits[id] = (date, continuation); return 0
                }
                if result == -1 { continuation.resume(throwing: CancellationError()) }
                if result == 1 { continuation.resume() }
            }
        } onCancel: {
            let waiter = self.state.withLock { value -> CheckedContinuation<Void, any Error>? in
                if let waiter = value.waits.removeValue(forKey: id)?.1 { return waiter }
                value.cancelled.insert(id); return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

extension DownloadManagementTests {
    @Test(arguments: [408, 429, 500, 502, 503, 504, 404, 401, 403])
    func realHTTPClassification(status: Int) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let server = try await LoopbackServer(f, mode: "http-\(status)")
        let output = f.root.appendingPathComponent("http-output")
        let fd = Darwin.open(output.path, O_RDWR | O_CREAT | O_EXCL, 0o600); defer { Darwin.close(fd) }
        do {
            try await URLSessionModelRangeTransport(allowsLocalHTTP: true).download(.init(url: server.url.appendingPathComponent("weights/payload.bin"), start: 0, end: 4095, total: 4096), to: fd)
            Issue.record("Expected classified rejection")
        } catch {
            if [408, 429, 500, 502, 503, 504].contains(status) {
                let temporary = try #require(error as? ModelTransientDownloadError)
                #expect(temporary.status == status)
                #expect(try #require(temporary.retryAfter).timeIntervalSinceNow > 110)
            } else { #expect(error is ModelLibraryError) }
        }
        #expect(try Data(contentsOf: output).isEmpty)
    }
    @Test(arguments: [false, true])
    func actualEngineAdmissionPinsThroughCancelAndAuthoritativeOutcome(unconfirmed: Bool) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let library = try await f.library()
        let id = try await library.registerExisting(at: f.source, catalogID: f.entry.id)
        let reference = try await library.resolve(id), base = FixtureInferenceEngine()
        let engine = ModelLibraryInferenceEngine(base: base, library: library)
        let request = InferenceRequest(model: reference, input: .image(.init(prompt: "fixture", width: 512, height: 512, steps: 4, guidanceScale: 1, seed: 1)))
        let run = try await engine.submit(request, backendID: "fixture")
        await #expect(throws: ModelLibraryError.self) { try await library.unregister(id) }
        await run.cancel()
        await #expect(throws: ModelLibraryError.self) { try await library.unregister(id) }
        let expected: RunOutcome = unconfirmed ? .failed(.resourceCleanupUnconfirmed("fixture")) : .cancelled
        await base.finish(expected)
        #expect(await run.outcome() == expected)
        if unconfirmed {
            #expect(await library.snapshot().records[0].activeLeaseCount == 1)
            await #expect(throws: ModelLibraryError.self) { try await library.unregister(id) }
        } else {
            #expect(await library.snapshot().records[0].activeLeaseCount == 0)
            try await library.unregister(id)
            await #expect(throws: ModelLibraryError.self) { try await engine.submit(request, backendID: "fixture") }
            #expect(await base.submissions == 1)
            try await library.shutdown()
        }
    }
}
private actor FixtureInferenceEngine: InferenceEngine {
    var submissions = 0
    var outcome: RunOutcome?
    var waiters: [CheckedContinuation<RunOutcome, Never>] = []
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        submissions += 1
        return .init(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { await self.result() })
    }
    func result() async -> RunOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func finish(_ result: RunOutcome) { outcome = result; let waiting = waiters; waiters = []; for waiter in waiting { waiter.resume(returning: result) } }
}

extension DownloadManagementTests {
    @Test(arguments: ["migration.backup", "state.beforeWrite", "state.afterRename", "unknown", "corrupt"])
    func failedMigrationNeverCreatesAnEmptyReplacement(point: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        var owner: ModelLibrary? = try await f.library()
        _ = try await owner!.registerExisting(at: f.source, catalogID: f.entry.id)
        try await owner!.shutdown(); owner = nil
        let index = f.state.appendingPathComponent("index.json")
        var original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        original["schemaVersion"] = point == "unknown" ? 99 : 1
        original.removeValue(forKey: "downloads"); original.removeValue(forKey: "queueState")
        let bytes = point == "corrupt" ? Data("not JSON".utf8) : try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        try bytes.write(to: index)
        let fault = FixtureFault(); fault.arm(point)
        await #expect(throws: (any Error).self) { try await self.library(f, transport: FixtureTransfer(f.contents), fault: fault) }
        if point != "state.afterRename" { #expect(try Data(contentsOf: index) == bytes) }
        else {
            #expect(try Data(contentsOf: f.state.appendingPathComponent("index.v1.backup.json")) == bytes)
            fault.clear()
            let recovered = try await self.library(f, transport: FixtureTransfer(f.contents))
            #expect(await recovered.snapshot().resources.count == 1)
            try await recovered.shutdown()
        }
    }
    @Test func invalidRetryCounterIsRejectedWithoutChangingIndex() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transfer = FixtureTransfer(f.contents)
        var owner: ModelLibrary? = try await self.library(f, transport: transfer)
        try await owner!.configureRoot(at: f.destination)
        _ = try await owner!.enqueueDownloads([f.entry.id])
        _ = try await wait(owner!) { $0.downloads[0].state == .completed }
        try await owner!.shutdown(); owner = nil
        let index = f.state.appendingPathComponent("index.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var tasks = try #require(object["downloads"] as? [[String: Any]])
        tasks[0]["automaticRetries"] = -1; object["downloads"] = tasks
        let bytes = try JSONSerialization.data(withJSONObject: object); try bytes.write(to: index)
        await #expect(throws: (any Error).self) { try await self.library(f, transport: transfer) }
        #expect(try Data(contentsOf: index) == bytes)
    }
    @Test func networkAndSaveDiagnosticsAreBothRetainedAndBlockDispatch() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fault = FixtureFault(), clock = FixtureClock(), transfer = FixtureTransfer(f.contents, gated: true, transient: true)
        let library = try await self.library(f, transport: transfer, catalog: [entry(f, id: "a", single: true), entry(f, id: "b", single: true)], fault: fault, clock: clock)
        try await library.configureRoot(at: f.destination)
        _ = try await library.enqueueDownloads(["a", "b"])
        fault.arm("completion.beforeWrite"); await transfer.openGate()
        let failed = try await wait(library) { $0.queueError != nil }
        #expect(failed.downloads[0].firstError?.contains("503") == true)
        #expect(failed.queueError?.contains("Injected") == true)
        #expect(failed.downloads[1].attempts == 0)
        clock.advance(to: clock.now.addingTimeInterval(300))
        try await Task.sleep(for: .milliseconds(40)); #expect(await transfer.requests == 1)
        fault.clear(); try await library.shutdown()
    }
    @Test @MainActor func preparedCopyHasIndependentIdentityAndReadinessPaths() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let raw = ModelCatalogEntry(id: "minimax-h3-fl2va-bf16", title: "H3 fixture", repository: "fixture/model",
            revision: "42ed227ee7df40d41602854ae760620d6eb651fe", files: f.entry.files,
            workflowProfileID: "d.video.minimax-h3-fl2va-bf16-full-v1", preparation: .required)
        var owner: ModelLibrary? = try await ModelLibrary(stateDirectory: f.state, catalog: [raw])
        let parent = try await owner!.registerExisting(at: f.source, catalogID: raw.id)
        let output = try await owner!.prepareVideo(parent, in: f.destination)
        let inventory = await owner!.snapshot()
        let prepared = try #require(inventory.resources.first { $0.control.role == .execution })
        #expect(prepared.control.parentResourceID?.modelID == parent)
        #expect(prepared.record.registrationState == .unregistered)
        #expect(prepared.control.requiredPaths?.contains("model/weights/payload.bin") == true)
        await #expect(throws: ModelLibraryError.self) { try await owner!.registerResource(prepared.id) }
        let revision = "minimax-h3-fl2va-bf16-full-v1@" + raw.revision
        try await owner!.registerPreparedResource(prepared.id) { url in
            let directory = try ModelDirectory(url)
            #expect(try directory.read("model/config.json") == f.contents["config.json"])
            return .init(directory: url, revision: revision)
        }
        let registered = await owner!.snapshot()
        let record = try #require(registered.records.first { $0.id == prepared.record.id })
        #expect(try WorkflowModelReadiness.stamps(for: record, in: registered).count == 3)
        let lease = try await owner!.acquire(record.id)
        #expect(lease.reference.revision == revision && lease.reference.directory.path == output.path)
        await owner!.release(lease)
        let moved = output.deletingLastPathComponent().appendingPathComponent("moved-prepared")
        try FileManager.default.moveItem(at: output, to: moved)
        try await owner!.rebind(record.id, to: moved) { url in .init(directory: url, revision: revision) }
        #expect(try await owner!.resolve(record.id).directory.path == moved.path)
        #expect(try ModelDirectory(try await owner!.resolve(record.id).directory).identity.sameNode(ModelDirectory(moved).identity))
        await #expect(throws: ModelLibraryError.self) { try await owner!.acquireForBackup(record.id) }
        try await owner!.unregister(record.id)
        try await owner!.reverifyResource(prepared.id) { url in .init(directory: url, revision: revision) }
        #expect(await owner!.snapshot().records.first { $0.id == record.id }?.registrationState == .unregistered)
        try await owner!.registerPreparedResource(prepared.id) { url in .init(directory: url, revision: revision) }
        try await owner!.shutdown(); owner = nil
        let cold = try await ModelLibrary(stateDirectory: f.state, catalog: [raw])
        #expect(try await cold.resolve(record.id).revision == revision)
        #expect(await cold.snapshot().resources.count == 2)
        try await cold.shutdown()
    }
    @Test func hundredResourcesSnapshotDoesNotChangeIndexOrRegistration() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let library = try await f.library()
        for index in 0..<100 {
            let source = f.root.appendingPathComponent("copy-\(index)")
            try f.writeModel(at: source)
            let id = try await library.registerExisting(at: source, catalogID: f.entry.id)
            if index % 2 == 0 { try await library.unregister(id) }
        }
        let path = f.state.appendingPathComponent("index.json"), before = try Data(contentsOf: path)
        let start = Date()
        for _ in 0..<20 { #expect(await library.snapshot().resources.count == 100) }
        print("DOWNLOAD-MANAGEMENT snapshot 100 resources x20 seconds=\(Date().timeIntervalSince(start))")
        #expect(try Data(contentsOf: path) == before)
        #expect(await library.snapshot().records.filter { $0.registrationState == .registered }.count == 50)
        try await library.shutdown()
    }
}


extension DownloadManagementTests {
    @Test func completedManagedLegacyMigrationRetainsRegistrationAndExactBytes() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transfer = FixtureTransfer(f.contents)
        var owner: ModelLibrary? = try await self.library(f, transport: transfer)
        try await owner!.configureRoot(at: f.destination)
        _ = try await owner!.enqueueDownloads([f.entry.id], postAction: .register)
        let completed = try await wait(owner!) { $0.downloads[0].state == .completed }
        let record = completed.records[0]
        try await owner!.shutdown(); owner = nil
        let index = f.state.appendingPathComponent("index.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        object["schemaVersion"] = 1; object.removeValue(forKey: "downloads"); object.removeValue(forKey: "queueState")
        var rows = try #require(object["records"] as? [[String: Any]])
        rows[0].removeValue(forKey: "control")
        var row = try #require(rows[0]["record"] as? [String: Any]); row.removeValue(forKey: "registrationState"); rows[0]["record"] = row
        object["records"] = rows
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); try original.write(to: index)
        let before = await transfer.requests
        let cold = try await self.library(f, transport: transfer)
        #expect(try Data(contentsOf: f.state.appendingPathComponent("index.v1.backup.json")) == original)
        let reference = try await cold.resolve(record.id)
        #expect(reference.revision == record.revision && reference.directory == record.directory)
        for (path, bytes) in f.contents { #expect(try Data(contentsOf: reference.directory.appendingPathComponent(path)) == bytes) }
        #expect(await cold.snapshot().downloads.isEmpty)
        #expect(await transfer.requests == before)
        try await cold.shutdown()
    }
    @Test(arguments: [false, true])
    func retryTimerCannotWakePausedOrCancelledTask(cancel: Bool) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let clock = FixtureClock(), transfer = FixtureTransfer(f.contents, transient: true)
        let library = try await self.library(f, transport: transfer, catalog: [entry(f, id: "retry", single: true)], clock: clock)
        try await library.configureRoot(at: f.destination)
        let task = try await library.enqueueDownloads(["retry"])[0]
        _ = try await wait(library) { $0.downloads[0].state == .waitingRetry }
        if cancel { try await library.cancelDownload(task.id) } else { try await library.pauseDownload(task.id) }
        let count = await transfer.requests
        clock.advance(to: clock.now.addingTimeInterval(60))
        try await Task.sleep(for: .milliseconds(40))
        #expect(await transfer.requests == count)
        #expect(await library.snapshot().downloads[0].state == (cancel ? .cancelled : .paused))
        try await library.shutdown()
    }
}


extension DownloadManagementTests {
    @Test(arguments: [false, true]) func retiredLocationCannotEscapeRevocationAfterRebindAndColdOpen(replaceAtSamePath: Bool) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let replacement = f.root.appendingPathComponent("other-copy")
        try f.writeModel(at: replacement)
        var owner: ModelLibrary? = try await f.library()
        let id = try await owner!.registerExisting(at: f.source, catalogID: f.entry.id)
        let old = try await owner!.resolve(id)
        try await owner!.unregister(id)
        var retired = old
        var current = replacement
        if replaceAtSamePath {
            let moved = f.root.appendingPathComponent("old-physical-copy")
            try FileManager.default.moveItem(at: f.source, to: moved)
            try FileManager.default.moveItem(at: replacement, to: f.source)
            retired = .init(directory: moved, revision: old.revision)
            current = f.source
        }
        try await owner!.rebind(id, to: current)
        await #expect(throws: ModelLibraryError.self) { try await owner!.acquireKnownResource(retired) }
        try await owner!.registerResource(.init(rawValue: id.rawValue))
        await #expect(throws: ModelLibraryError.self) { try await owner!.acquireKnownResource(retired) }
        try await owner!.shutdown(); owner = nil
        let cold = try await f.library()
        await #expect(throws: ModelLibraryError.self) { try await cold.acquireKnownResource(retired) }
        #expect(try await cold.resolve(id).directory.path == current.path)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("weights/payload.bin")) == f.contents["weights/payload.bin"])
        try await cold.shutdown()
    }
}

// DDM finite independent review regression — append in this existing test file
// so its private fixtures are reused. These are macOS service tests, not GUI tests.
extension DownloadManagementTests {
    @Test(arguments: [false, true])
    func independentReviewRebindingDrainsThenSchedulesQueuedDownload(validatorFails: Bool) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let raw = ModelCatalogEntry(id: "minimax-h3-fl2va-bf16", title: "H3 fixture",
            repository: "fixture/model", revision: "42ed227ee7df40d41602854ae760620d6eb651fe",
            files: f.entry.files, workflowProfileID: "d.video.minimax-h3-fl2va-bf16-full-v1",
            preparation: .required)
        let transfer = FixtureTransfer(f.contents)
        let library = try await self.library(f, transport: transfer,
            catalog: [raw, entry(f, id: "queued-after-rebind")])
        try await library.configureRoot(at: f.destination)
        let parent = try await library.registerExisting(at: f.source, catalogID: raw.id)
        let output = try await library.prepareVideo(parent, in: f.destination)
        let initial = await library.snapshot()
        let prepared = try #require(initial.resources.first { $0.control.role == .execution })
        let gate = IndependentReviewValidationGate()
        let relocating = Task {
            try await library.rebind(prepared.record.id, to: output) { url in
                await gate.enter()
                if validatorFails { throw ModelLibraryError.integrity("Independent review validator rejection") }
                return ModelReference(directory: url,
                    revision: "minimax-h3-fl2va-bf16-full-v1@" + raw.revision)
            }
        }
        do {
            try await gate.waitUntilEntered()
            let queued = try await library.enqueueDownloads(["queued-after-rebind"])[0]
            let during = await library.snapshot()
            #expect(during.queueState == .running)
            #expect(during.downloads.first { $0.id == queued.id }?.attempts == 0)
            #expect(await transfer.requests == 0)
            await gate.open()
            if validatorFails {
                await #expect(throws: ModelLibraryError.self) { try await relocating.value }
            } else {
                try await relocating.value
            }
            // No extra enqueue/resume/refresh-side-effect may be needed to wake it.
            let done = try await wait(library) { snapshot in
                snapshot.downloads.first { $0.id == queued.id }?.state == .completed
            }
            #expect(done.downloads.first { $0.id == queued.id }?.attempts == 1)
            #expect(done.resources.first { $0.id == queued.resourceID }?.record.registrationState == .unregistered)
            #expect(await transfer.maximumActive <= 2)
            try await library.shutdown()
        } catch {
            await gate.open()
            relocating.cancel()
            _ = try? await relocating.value
            try? await library.shutdown()
            throw error
        }
    }

    @Test(arguments: [ModelDownloadPostAction.filesOnly, .register], [false, true])
    func independentReviewRestartPreservesIntentWithoutHistoryResurrection(
        intent: ModelDownloadPostAction, clearHistory: Bool
    ) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let server = try await LoopbackServer(f, mode: "corrupt")
        let library = try await f.library(server: server)
        try await library.configureRoot(at: f.destination)
        let task = try await library.enqueueDownloads([f.entry.id], postAction: intent)[0]
        _ = try await wait(library) { $0.downloads.first?.state == .failed }
        if clearHistory { try await library.clearDownloadHistory([task.id]) }
        try server.setMode("valid")
        try await library.restart(task.resourceID.modelID)
        let done = try await wait(library) { $0.downloads.last?.state == .completed }
        let expectedIntent: ModelDownloadPostAction = clearHistory ? .filesOnly : intent
        #expect(done.downloads.last?.postAction == expectedIntent)
        #expect(done.resources.first { $0.id == task.resourceID }?.record.registrationState ==
            (expectedIntent == .register ? .registered : .unregistered))
        #expect(done.resources.first { $0.id == task.resourceID }?.control.fileState == .verified)
        if clearHistory { #expect(!done.downloads.contains { $0.id == task.id }) }
        try await library.shutdown()
    }

    @Test func independentReviewFailedRegistrationRollsBackSuccessEvent() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fault = FixtureFault(), transfer = FixtureTransfer(f.contents)
        let library = try await self.library(f, transport: transfer, fault: fault)
        try await library.configureRoot(at: f.destination)
        _ = try await library.enqueueDownloads([f.entry.id], postAction: .filesOnly)
        let complete = try await wait(library) { $0.downloads.first?.state == .completed }
        let before = try #require(complete.resources.first)
        fault.arm("registration.beforeWrite")
        await #expect(throws: (any Error).self) { try await library.registerResource(before.id) }
        let after = try #require(await library.snapshot().resources.first)
        #expect(after.record.registrationState == .unregistered)
        #expect(after.control.events == before.control.events)
        fault.clear()
        // An unrelated successful write must not persist the failed command's event.
        try await library.resumeQueue()
        let index = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: f.state.appendingPathComponent("index.json"))) as? [String: Any])
        let rows = try #require(index["records"] as? [[String: Any]])
        let control = try #require(rows.first?["control"] as? [String: Any])
        let events = try #require(control["events"] as? [[String: Any]])
        #expect(events.count == before.control.events.count)
        #expect(!events.contains { $0["action"] as? String == "registered" })
        try await library.shutdown()
    }
}

private actor IndependentReviewValidationGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilEntered() async throws {
        for _ in 0..<500 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ModelLibraryError.storage("Independent review validation gate timed out")
    }
    func open() {
        released = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

extension DownloadManagementTests {
    @Test(arguments: ["paused", "shutdown", "saveError"])
    func finiteReviewRebindRespectsNewerQueueGates(decision: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let raw = ModelCatalogEntry(id: "minimax-h3-fl2va-bf16", title: "H3 fixture",
            repository: "fixture/model", revision: "42ed227ee7df40d41602854ae760620d6eb651fe",
            files: f.entry.files, workflowProfileID: "d.video.minimax-h3-fl2va-bf16-full-v1", preparation: .required)
        let transfer = FixtureTransfer(f.contents), fault = FixtureFault()
        var owner: ModelLibrary? = try await self.library(f, transport: transfer,
            catalog: [raw, entry(f, id: "waiting")], fault: fault)
        do {
            let library = try #require(owner)
            try await library.configureRoot(at: f.destination)
            let parent = try await library.registerExisting(at: f.source, catalogID: raw.id)
            let output = try await library.prepareVideo(parent, in: f.destination)
            let prepared = try #require(await library.snapshot().resources.first { $0.control.role == .execution })
            let gate = IndependentReviewValidationGate()
            let relocating = Task {
                try await library.rebind(prepared.record.id, to: output) { url in
                    await gate.enter()
                    return ModelReference(directory: url, revision: "minimax-h3-fl2va-bf16-full-v1@" + raw.revision)
                }
            }
            var closing: Task<Void, any Error>?
            do {
                try await gate.waitUntilEntered()
                let task = try await library.enqueueDownloads(["waiting"])[0]
                if decision == "paused" { try await library.pauseQueue() }
                if decision == "shutdown" {
                    closing = Task { try await library.shutdown() }
                    _ = try await wait(library) { $0.queueState == .waitingForResume }
                }
                if decision == "saveError" {
                    fault.arm("state.beforeWrite")
                    await #expect(throws: (any Error).self) { try await library.resumeQueue() }
                    fault.clear()
                }
                await gate.open()
                if decision == "shutdown" { await #expect(throws: ModelLibraryError.self) { try await relocating.value } }
                else { try await relocating.value }
                try await closing?.value
                let done = await library.snapshot()
                #expect(done.downloads.first { $0.id == task.id }?.attempts == 0)
                #expect(await transfer.requests == 0)
                #expect(done.queueState == (decision == "paused" ? .paused : decision == "shutdown" ? .waitingForResume : .running))
                if decision == "saveError" { #expect(done.queueError != nil) }
                if decision != "shutdown" {
                    try await library.resumeQueue()
                    _ = try await wait(library) { $0.downloads.first?.state == .completed }
                    try await library.shutdown()
                }
            } catch {
                fault.clear(); await gate.open(); relocating.cancel()
                _ = try? await relocating.value; _ = try? await closing?.value
                try? await library.shutdown(); throw error
            }
        }
        owner = nil
        if decision == "shutdown" {
            let cold = try await self.library(f, transport: transfer, catalog: [raw, entry(f, id: "waiting")])
            #expect(await cold.snapshot().queueState == .waitingForResume)
            #expect(await transfer.requests == 0)
            try await cold.shutdown()
        }
    }

    @Test func finiteReviewPublishedRegistrationIsRetainedAfterSyncFailure() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fault = FixtureFault(), transfer = FixtureTransfer(f.contents)
        var owner: ModelLibrary? = try await self.library(f, transport: transfer, fault: fault)
        do {
            let library = try #require(owner)
            try await library.configureRoot(at: f.destination)
            _ = try await library.enqueueDownloads([f.entry.id])
            let before = try await wait(library) { $0.downloads.first?.state == .completed }
            let resource = try #require(before.resources.first)
            fault.arm("registration.afterRename")
            await #expect(throws: ModelAtomicWriteError.self) { try await library.registerResource(resource.id) }
            let after = await library.snapshot()
            #expect(after.resources.first?.record.registrationState == .registered)
            #expect(after.resources.first?.control.events.last?.action == "registered")
            #expect(after.queueError != nil)
            #expect(after.resources.first?.control.events.count == resource.control.events.count + 1)
            fault.clear()
            let index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.state.appendingPathComponent("index.json"))) as? [String: Any])
            let rows = try #require(index["records"] as? [[String: Any]])
            #expect((rows.first?["record"] as? [String: Any])?["registrationState"] as? String == "registered")
            let control = try #require(rows.first?["control"] as? [String: Any])
            #expect((control["events"] as? [[String: Any]])?.last?["action"] as? String == "registered")
            let directory = try #require(resource.record.directory)
            for (path, bytes) in f.contents { #expect(try Data(contentsOf: directory.appendingPathComponent(path)) == bytes) }
            // Cold-read the published index; do not let shutdown rewrite it first.
        }
        owner = nil
        let cold = try await self.library(f, transport: transfer, fault: fault)
        #expect(await cold.snapshot().resources.first?.record.registrationState == .registered)
        #expect(await cold.snapshot().resources.first?.control.events.last?.action == "registered")
        try await cold.shutdown()
    }
}

// Approved download-manager commands: exact attempt, queue scope, durable intent.
extension DownloadManagementTests {
    @Test func managerSingleResumePreservesPausedQueueAndRegistrationAcrossAttempts() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transfer = FixtureTransfer(f.contents)
        let library = try await self.library(f, transport: transfer, catalog: [entry(f, id: "a"), entry(f, id: "b"), entry(f, id: "c")])
        try await library.configureRoot(at: f.destination)
        try await library.pauseQueue()
        let tasks = try await library.enqueueDownloads(["a", "b", "c"], postAction: .register, startIfIdle: false)
        try await library.pauseDownload(tasks[0].id)
        try await library.pauseDownload(tasks[1].id)
        try await library.cancelDownload(tasks[2].id)
        let resumed = try await library.continueDownload(tasks[0].id, expectedGeneration: tasks[0].generation)
        #expect(resumed.id == tasks[0].id && resumed.postAction == .register)
        #expect(await library.snapshot().queueState == .paused)
        #expect(await library.snapshot().downloads[1].state == .paused)
        #expect(await transfer.requests == 0)
        try await library.resumeQueue(includePaused: true)
        let done = try await wait(library) { $0.downloads.prefix(2).allSatisfy { $0.state == .completed } }
        #expect(done.downloads[2].state == .cancelled && done.downloads[2].attempts == 0)
        #expect(done.resources.prefix(2).allSatisfy { $0.record.registrationState == .registered })
        try await library.pauseQueue()
        let restarted = try await library.continueDownload(tasks[2].id, expectedGeneration: tasks[2].generation)
        #expect(restarted.id != tasks[2].id && restarted.resourceID == tasks[2].resourceID && restarted.postAction == .register)
        #expect(await library.snapshot().queueState == .paused)
        #expect(await library.snapshot().downloads.first { $0.id == tasks[2].id }?.state == .cancelled)
        try await library.shutdown()
    }

    @Test func managerStaleAttemptCannotRestartOrEraseNewerPartial() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transfer = FixtureTransfer(f.contents), library = try await self.library(f, transport: transfer)
        try await library.configureRoot(at: f.destination); try await library.pauseQueue()
        let old = try await library.enqueueDownloads([f.entry.id], postAction: .register, startIfIdle: false)[0]
        try await library.cancelDownload(old.id)
        let next = try await library.continueDownload(old.id, expectedGeneration: old.generation)
        try await library.cancelDownload(next.id)
        await #expect(throws: ModelLibraryError.self) { try await library.restartDownload(old.id, expectedGeneration: old.generation) }
        await #expect(throws: ModelLibraryError.self) { try await library.deleteDownload(old.id, expectedGeneration: old.generation, cleanupPartial: true) }
        #expect(await library.snapshot().downloads.count == 2)
        #expect(await library.snapshot().resources[0].control.fileState == .partial)
        try await library.deleteDownload(old.id, expectedGeneration: old.generation)
        #expect(await library.snapshot().downloads.map(\.id) == [next.id])
        #expect(await library.snapshot().resources[0].control.fileState == .partial)
        try await library.deleteDownload(next.id, expectedGeneration: next.generation, cleanupPartial: true)
        #expect(await library.snapshot().downloads.isEmpty)
        #expect(await library.snapshot().resources[0].control.fileState == .deleted)
        #expect(await transfer.requests == 0)
        try await library.shutdown()
    }

    @Test func managerCompletedFileSurvivesStaleCleanupAndRecordDeletion() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let library = try await self.library(f, transport: FixtureTransfer(f.contents))
        try await library.configureRoot(at: f.destination)
        let requested = try await library.enqueueDownloads([f.entry.id])[0]
        let done = try await wait(library) { $0.downloads.first?.state == .completed }
        let completed = try #require(done.downloads.first), resource = try #require(done.resources.first)
        await #expect(throws: ModelLibraryError.self) { try await library.deleteDownload(requested.id, expectedGeneration: requested.generation, cleanupPartial: true) }
        await #expect(throws: ModelLibraryError.self) { try await library.deleteDownload(completed.id, expectedGeneration: completed.generation, cleanupPartial: true) }
        try await library.deleteDownload(completed.id, expectedGeneration: completed.generation)
        #expect(await library.snapshot().downloads.isEmpty)
        #expect(await library.snapshot().resources[0].control.fileState == .verified)
        #expect(try ModelDirectory(try #require(resource.record.directory)).verify(f.entry.files).count == f.entry.files.count)
        try await library.shutdown()
    }

    @Test func managerEnqueueAndSingleResumeFailuresDoNotLeakUncommittedState() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fault = FixtureFault(), library = try await self.library(f, transport: FixtureTransfer(f.contents), fault: fault)
        try await library.configureRoot(at: f.destination); try await library.pauseQueue()
        let task = try await library.enqueueDownloads([f.entry.id], postAction: .register, startIfIdle: false)[0]
        try await library.cancelDownload(task.id)
        let before = await library.snapshot()
        fault.arm("state.beforeWrite")
        await #expect(throws: (any Error).self) { try await library.continueDownload(task.id, expectedGeneration: task.generation) }
        #expect(await library.snapshot().downloads == before.downloads)
        #expect(await library.snapshot().queueState == .paused)
        fault.clear()
        let next = try await library.continueDownload(task.id, expectedGeneration: task.generation)
        #expect(next.postAction == .register && next.resourceID == task.resourceID)
        try await library.shutdown()
    }

    @Test func managerRegistrationRetryClearsSecondaryFailureWithoutDownload() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fault = FixtureFault(), transfer = FixtureTransfer(f.contents, gated: true)
        let library = try await self.library(f, transport: transfer, fault: fault)
        try await library.configureRoot(at: f.destination)
        _ = try await library.enqueueDownloads([f.entry.id], postAction: .register)
        _ = try await wait(library) { $0.downloads.first?.attempts == 1 }
        fault.arm("registration.beforeWrite"); await transfer.openGate()
        let failed = try await wait(library) { $0.downloads.first?.postActionError != nil }
        let task = try #require(failed.downloads.first), count = await transfer.requests
        fault.arm("registration.beforeWrite")
        await #expect(throws: (any Error).self) { try await library.retryDownloadRegistration(task.id, expectedGeneration: task.generation) }
        #expect(await library.snapshot().downloads[0].postActionError != nil)
        #expect(await library.snapshot().resources[0].record.registrationState != .registered)
        fault.clear()
        try await library.retryDownloadRegistration(task.id, expectedGeneration: task.generation)
        #expect(await library.snapshot().downloads[0].postActionError == nil)
        #expect(await library.snapshot().resources[0].record.registrationState == .registered)
        #expect(await transfer.requests == count)
        try await library.shutdown()
    }
}

extension DownloadManagementTests {
    @Test func managerSingleResumeCannotClearGlobalSavingErrorGate() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transfer = FixtureTransfer(f.contents, gated: true), fault = FixtureFault()
        let library = try await self.library(f, transport: transfer, catalog: [entry(f, id: "a"), entry(f, id: "b"), entry(f, id: "c")], fault: fault)
        try await library.configureRoot(at: f.destination)
        let tasks = try await library.enqueueDownloads(["a", "b", "c"])
        _ = try await wait(library) { $0.downloads[0].attempts == 1 }
        try await library.pauseDownload(tasks[2].id)
        fault.arm("state.beforeWrite")
        await #expect(throws: (any Error).self) { try await library.moveWaitingDownload(tasks[1].id, before: nil) }
        fault.clear()
        _ = try await library.continueDownload(tasks[2].id, expectedGeneration: tasks[2].generation)
        #expect(await library.snapshot().queueError != nil)
        await transfer.openGate()
        _ = try await wait(library) { $0.downloads.first { $0.id == tasks[0].id }?.state == .completed }
        #expect(await transfer.requestedRepositories.allSatisfy { $0 == "/fixture/a" })
        #expect(await library.snapshot().downloads.filter { $0.id != tasks[0].id }.allSatisfy { $0.attempts == 0 })
        try await library.resumeQueue(includePaused: true)
        _ = try await wait(library) { $0.downloads.allSatisfy { $0.state == .completed } }
        try await library.shutdown()
    }

    @Test(arguments: ["deleteIntent.afterRename", "deleteResult.beforeWrite", "state.beforeWrite"])
    func managerPartialDeleteCanRecoverWithoutTouchingCompleteFiles(point: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fault = FixtureFault(), library = try await self.library(f, transport: FixtureTransfer(f.contents), fault: fault)
        try await library.configureRoot(at: f.destination); try await library.pauseQueue()
        let task = try await library.enqueueDownloads([f.entry.id], startIfIdle: false)[0]
        try await library.cancelDownload(task.id)
        fault.arm(point)
        await #expect(throws: (any Error).self) { try await library.deleteDownload(task.id, expectedGeneration: task.generation, cleanupPartial: true) }
        #expect(await library.snapshot().downloads.contains { $0.id == task.id })
        fault.clear()
        try await library.deleteDownload(task.id, expectedGeneration: task.generation, cleanupPartial: true)
        #expect(await library.snapshot().downloads.isEmpty)
        #expect(await library.snapshot().resources[0].control.fileState == .deleted)
        try await library.shutdown()
    }

    @Test func managerPausedRequestKeepsPolicyAfterColdOpen() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transfer = FixtureTransfer(f.contents)
        var library: ModelLibrary? = try await self.library(f, transport: transfer)
        try await library!.configureRoot(at: f.destination); try await library!.pauseQueue()
        let task = try await library!.enqueueDownloads([f.entry.id], postAction: .register, startIfIdle: false)[0]
        try await library!.cancelDownload(task.id)
        let next = try await library!.continueDownload(task.id, expectedGeneration: task.generation)
        try await library!.shutdown(); library = nil
        let reopened = try await self.library(f, transport: transfer)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.queueState != .running && snapshot.downloads.last?.id == next.id)
        #expect(snapshot.downloads.last?.resourceID == next.resourceID && snapshot.downloads.last?.postAction == .register)
        #expect(await transfer.requests == 0)
        try await reopened.resumeQueue(includePaused: true)
        let complete = try await wait(reopened) { $0.downloads.last?.state == .completed }
        #expect(complete.resources[0].record.registrationState == .registered)
        try await reopened.shutdown()
    }
}


extension DownloadManagementTests {
    @Test func deletingNewerFailedHistoryCannotReviveOlderRegistrationIntentAfterColdOpen() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let server = try await LoopbackServer(f, mode: "http-403")
        var owner: ModelLibrary? = try await f.library(server: server)
        let stopped: ModelDownloadTask
        let newer: ModelDownloadTask
        do {
            let library = try #require(owner)
            try await library.configureRoot(at: f.destination)
            try await library.pauseQueue()
            let first = try await library.enqueueDownloads([f.entry.id], postAction: .register)[0]
            try await library.cancelDownload(first.id)
            stopped = try #require((await library.snapshot()).downloads.first)
            _ = try await library.enqueueDownloads([f.entry.id], postAction: .filesOnly)
            try await library.resumeQueue()
            let failed = try await wait(library) { $0.downloads.last?.state == .failed }
            newer = try #require(failed.downloads.last)
            #expect(newer.id != stopped.id && newer.postAction == .filesOnly)
            #expect(failed.resources.first?.control.downloadOwner?.matches(newer) == true)
            try await library.deleteDownload(newer.id, expectedGeneration: newer.generation)
            #expect((await library.snapshot()).resources.first?.control.downloadOwner?.taskID == newer.id)
            try await library.shutdown()
        }
        owner = nil
        let reopened = try await f.library(server: server)
        let before = await reopened.snapshot()
        #expect(before.downloads.map(\.id) == [stopped.id])
        #expect(before.resources.first?.control.downloadOwner?.taskID == newer.id)
        await #expect(throws: ModelLibraryError.self) { _ = try await reopened.continueDownload(stopped.id, expectedGeneration: stopped.generation) }
        await #expect(throws: ModelLibraryError.self) { try await reopened.deleteDownload(stopped.id, expectedGeneration: stopped.generation, cleanupPartial: true) }
        #expect((await reopened.snapshot()).downloads == before.downloads)
        try server.setMode("valid")
        let explicit = try await reopened.enqueueDownloads([f.entry.id], postAction: .filesOnly)[0]
        try await reopened.resumeQueue()
        let done = try await wait(reopened) { $0.downloads.last?.state == .completed }
        #expect(explicit.id != stopped.id && explicit.postAction == .filesOnly)
        #expect(done.resources.first?.record.registrationState == .unregistered)
        #expect(done.resources.first?.control.fileState == .verified)
        try await reopened.shutdown()
    }
}


extension DownloadManagementTests {
    @Test(arguments: ["dispatch.beforeWrite", "dispatch.afterRename"])
    func dispatchSaveFailureRetainsRecoverableQueueAndFileOwner(point: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let fault = FixtureFault(), transfer = FixtureTransfer(f.contents)
        let library = try await self.library(f, transport: transfer, fault: fault)
        try await library.configureRoot(at: f.destination)
        try await library.pauseQueue()
        let initial = try await library.enqueueDownloads([f.entry.id])[0]
        let owner = try #require((await library.snapshot()).resources.first?.control.downloadOwner)
        fault.arm(point)
        try await library.resumeQueue()
        let blocked = await library.snapshot()
        #expect(blocked.queueError != nil && blocked.downloads.first?.state == .queued)
        #expect(await transfer.requests == 0)
        if point == "dispatch.beforeWrite" {
            #expect(blocked.resources.first?.control.downloadOwner == owner)
            #expect(blocked.downloads.first?.attemptID == initial.attemptID)
        } else {
            #expect(blocked.resources.first?.control.downloadOwner?.matches(try #require(blocked.downloads.first)) == true)
        }
        fault.clear()
        try await library.resumeQueue()
        let done = try await wait(library) { $0.downloads.first?.state == .completed }
        #expect(done.resources.first?.control.downloadOwner?.matches(try #require(done.downloads.first)) == true)
        #expect(done.resources.first?.control.fileState == .verified)
        try await library.shutdown()
    }
}


extension DownloadManagementTests {
    @Test(arguments: ["queued", "deleted", "noHistory", "completed", "execution"])
    func wanTokenizerUpgradePreservesExistingIdentityWithoutDownloading(state: String) async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let current = try #require(ModelCatalog.entries().first { $0.id == "wan21-t2v-1.3b-bf16" })
        let old = ModelCatalogEntry(id: current.id, title: current.title, repository: current.repository,
            revision: current.revision, files: Array(current.files.prefix(3)), workflowProfileID: current.workflowProfileID,
            workflowIdentity: current.workflowIdentity, preparation: current.preparation)
        let transfer = FixtureTransfer([:])
        var owner: ModelLibrary? = try await ModelLibrary(stateDirectory: f.state, catalog: [old], transport: transfer, availableBytesOverride: UInt64.max)
        try await owner!.configureRoot(at: f.destination)
        let task = try await owner!.enqueueDownloads([old.id], postAction: .register, startIfIdle: false)[0]
        if state == "deleted" || state == "noHistory" {
            try await owner!.cancelDownload(task.id, keepPartial: true)
            if state == "deleted" { try await owner!.deleteOwnedCopy(task.resourceID) }
            else { try await owner!.clearDownloadHistory([task.id]) }
        }
        try await owner!.shutdown(); owner = nil
        let index = f.state.appendingPathComponent("index.json")
        if state == "completed" || state == "execution" {
            // Historical-state fixture only; it does not claim any model bytes were verified.
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
            var tasks = try #require(json["downloads"] as? [[String: Any]])
            tasks[0]["state"] = "completed"; json["downloads"] = tasks
            if state == "execution" {
                var records = try #require(json["records"] as? [[String: Any]])
                var control = try #require(records[0]["control"] as? [String: Any])
                control["role"] = "execution"; control["requiredPaths"] = ["D-VIDEO-PREPARED.json"]
                records[0]["control"] = control
                var record = try #require(records[0]["record"] as? [String: Any]); record["totalBytes"] = 42
                records[0]["record"] = record; json["records"] = records
            }
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: index)
        }
        let before = try Data(contentsOf: index)
        owner = try await ModelLibrary(stateDirectory: f.state, catalog: [current], transport: transfer, availableBytesOverride: UInt64.max)
        let snapshot = await owner!.snapshot(), resource = try #require(snapshot.resources.first)
        #expect(resource.id == task.resourceID)
        #expect(await transfer.requests == 0)
        #expect(try Data(contentsOf: f.state.appendingPathComponent("index.wan-tokenizer-v1.backup.json")) == before)
        if state == "deleted" {
            #expect(resource.control.fileState == .deleted)
            await #expect(throws: (any Error).self) { _ = try await owner!.continueWanTokenizerUpgrade(resource.id) }
        } else if state == "execution" {
            #expect(resource.record.totalBytes == 42 && resource.control.role == .execution)
            #expect(resource.control.requiredPaths == ["D-VIDEO-PREPARED.json"])
            await #expect(throws: (any Error).self) { _ = try await owner!.continueWanTokenizerUpgrade(resource.id) }
            await #expect(throws: (any Error).self) { _ = try await owner!.acquire(resource.record.id) }
        } else {
            #expect(resource.control.requiresTokenizerUpgrade == true && resource.control.fileState == .partial)
            #expect(resource.record.directory?.path.contains("/Staging/" + resource.record.id.description + "/Content") == true)
            let resumed = try await owner!.continueWanTokenizerUpgrade(resource.id)
            #expect(resumed.resourceID == task.resourceID && resumed.state == .queued)
            #expect(resumed.postAction == (state == "noHistory" ? .filesOnly : .register))
            #expect(await owner!.snapshot().queueState != .running)
            if state == "completed" {
                #expect(resumed.id != task.id)
                #expect(await owner!.snapshot().downloads.first { $0.id == task.id }?.state == .completed)
            }
        }
        try await owner!.shutdown(); owner = nil
        let cold = try await ModelLibrary(stateDirectory: f.state, catalog: [current], transport: transfer, availableBytesOverride: UInt64.max)
        #expect(await cold.snapshot().records.first?.id == resource.record.id)
        #expect(await transfer.requests == 0)
        try await cold.shutdown()
    }
}


extension DownloadManagementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_PITCH_MODEL_DIRECTORY"] != nil))
    func fixedPitchContentRevisionPassesActualEngineAdmissionAndPinsLease() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_PITCH_MODEL_DIRECTORY"]))
        let entry = try #require(ModelCatalog.entries().first { $0.id == ModelCatalog.pitchID })
        let library = try await ModelLibrary(stateDirectory: f.state, catalog: [entry])
        let id = try await library.registerExisting(at: source, catalogID: entry.id)
        let reference = ModelReference(directory: source, revision: PitchAnalysisRequest.modelSHA256)
        try await library.checkKnownResourceRegistration(reference)
        for revision in ["wrong", String(repeating: "0", count: 64)] {
            await #expect(throws: ModelLibraryError.self) {
                _ = try await library.acquireKnownResource(.init(directory: source, revision: revision))
            }
        }
        let base = FixtureInferenceEngine(), engine = ModelLibraryInferenceEngine(base: base, library: library)
        // Controlled executor tests wrapper admission only, not a Pitch inference result.
        let run = try await engine.submit(.init(model: reference, input: .text(.init(prompt: "fixture"))), backendID: "fixture")
        #expect(await base.submissions == 1)
        await #expect(throws: ModelLibraryError.self) { try await library.unregister(id) }
        await run.cancel()
        #expect(await library.snapshot().records[0].activeLeaseCount == 1)
        await base.finish(.cancelled); #expect(await run.outcome() == .cancelled)
        #expect(await library.snapshot().records[0].activeLeaseCount == 0)
        try await library.unregister(id)
        await #expect(throws: ModelLibraryError.self) { _ = try await library.acquireKnownResource(reference) }
        try await library.shutdown()
    }
}


extension DownloadManagementTests {
    @Test func newLeafSaveFailureRollsBackOnlyItsEmptyFileAndColdRetryWorks() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transfer = FixtureTransfer(f.contents), fault = FixtureFault()
        var owner: ModelLibrary? = try await library(f, transport: transfer, fault: fault)
        try await owner!.configureRoot(at: f.destination)
        fault.arm("download.createdLeaf")
        let task = try await owner!.enqueueDownloads([f.entry.id], postAction: .register)[0]
        _ = try await wait(owner!) { $0.downloads.first?.state == .failed }
        #expect(await transfer.requests == 0)
        let index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.state.appendingPathComponent("index.json"))) as? [String: Any])
        let rows = try #require(index["records"] as? [[String: Any]])
        #expect((rows[0]["files"] as? [String: Any])?.isEmpty == true)
        try await owner!.shutdown(); owner = nil; fault.clear()
        let cold = try await library(f, transport: transfer, fault: fault)
        let old = try #require(await cold.snapshot().downloads.first { $0.id == task.id })
        _ = try await cold.continueDownload(old.id, expectedGeneration: old.generation)
        try await cold.resumeQueue()
        let done = try await wait(cold) { $0.downloads.last?.state == .completed }
        #expect(done.records.first?.id == task.resourceID.modelID)
        #expect(done.resources.first?.control.fileState == .verified)
        try await cold.shutdown()
    }
}


extension DownloadManagementTests {
    @Test func publishedResourceNeedingSupplementKeepsItsKnownLocationAfterColdOpen() async throws {
        let f = try LibraryFixture(); defer { f.clean() }
        let transfer = FixtureTransfer(f.contents)
        var owner: ModelLibrary? = try await library(f, transport: transfer)
        try await owner!.configureRoot(at: f.destination)
        _ = try await owner!.enqueueDownloads([f.entry.id])
        let complete = try await wait(owner!) { $0.downloads.first?.state == .completed }
        let location = try #require(complete.resources.first?.record.directory)
        try await owner!.shutdown(); owner = nil
        let path = f.state.appendingPathComponent("index.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var records = try #require(json["records"] as? [[String: Any]])
        var control = try #require(records[0]["control"] as? [String: Any]); control["fileState"] = "partial"
        records[0]["control"] = control; json["records"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        let cold = try await library(f, transport: transfer)
        #expect(await cold.snapshot().resources.first?.record.directory == location)
        #expect(location.path.contains("/Installations/"))
        try await cold.shutdown()
    }
}
