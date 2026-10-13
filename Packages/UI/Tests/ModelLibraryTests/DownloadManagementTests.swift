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
