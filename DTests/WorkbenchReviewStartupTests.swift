import Foundation
import Testing
@testable import D

@MainActor
struct WorkbenchReviewStartupTests {
    private let session = "E895CA0A-6B49-4F81-83BA-4123FEA0CD24"
    private var environment: [String: String] {
        ["D_UI_TEST_SESSION": session, "D_DOWNLOAD_REVIEW_ROOT": "/Volumes/Review/" + session,
         "D_DOWNLOAD_REVIEW_SOURCE": "http://127.0.0.1:49152"]
    }

    @Test(arguments: ["all", "D_UI_TEST_SESSION", "D_DOWNLOAD_REVIEW_ROOT", "D_DOWNLOAD_REVIEW_SOURCE"])
    func lostEnvironmentNeverFallsBack(missing: String) throws {
        var env = environment
        if missing == "all" { env = [:] } else { env[missing] = nil }
        #expect(throws: WorkbenchLaunchContext.Rejected.self) {
            try WorkbenchLaunchContext.parse(marker: WorkbenchLaunchContext.markerValue, environment: env, required: true)
        }
    }

    @Test(arguments: ["absent", "empty", "unknown", "boolean", "unsupported"])
    func persistentMarkerIsStrict(kind: String) throws {
        let marker: Any? = switch kind {
        case "absent": nil
        case "empty": ""
        case "unknown": "future-review"
        case "boolean": true
        default: WorkbenchLaunchContext.markerValue
        }
        #expect(throws: WorkbenchLaunchContext.Rejected.self) {
            try WorkbenchLaunchContext.parse(marker: marker, environment: environment, required: true, supported: kind != "unsupported")
        }
    }

    @Test(arguments: ["uuid", "root", "parent", "remote", "credentials", "query", "port", "deployment"])
    func conflictingContextIsRejected(kind: String) throws {
        var env = environment
        switch kind {
        case "uuid": env["D_UI_TEST_SESSION"] = "bad"
        case "root": env["D_DOWNLOAD_REVIEW_ROOT"] = "/Volumes/Review/" + UUID().uuidString
        case "parent": env["D_DOWNLOAD_REVIEW_ROOT"] = "/Volumes/Review/../" + session
        case "remote": env["D_DOWNLOAD_REVIEW_SOURCE"] = "https://example.invalid/"
        case "credentials": env["D_DOWNLOAD_REVIEW_SOURCE"] = "http://user@127.0.0.1:49152"
        case "query": env["D_DOWNLOAD_REVIEW_SOURCE"] = "http://127.0.0.1:49152/?token=x"
        case "port": env["D_DOWNLOAD_REVIEW_SOURCE"] = "http://127.0.0.1:0"
        default: env["D_AUDIO_DEPLOYMENT_CHECK"] = "1"
        }
        #expect(throws: WorkbenchLaunchContext.Rejected.self) {
            try WorkbenchLaunchContext.parse(marker: WorkbenchLaunchContext.markerValue, environment: env, required: true)
        }
    }

    @Test func ordinaryAndLegacyTestPoliciesRemainDistinct() throws {
        guard case .ordinary = try WorkbenchLaunchContext.parse(marker: nil, environment: [:], required: false) else {
            Issue.record("Ordinary startup changed"); return
        }
        let test = try WorkbenchLaunchContext.parse(marker: nil, environment: ["D_UI_TEST_SESSION": session], required: false)
        guard case .uiTest(let id) = test else { Issue.record("Legacy test isolation lost"); return }
        #expect(id.uuidString == session && test.permitsDeploymentProbe)
        let review = try WorkbenchLaunchContext.parse(marker: WorkbenchLaunchContext.markerValue, environment: environment, required: true)
        #expect(!review.permitsDeploymentProbe)
        #expect(throws: WorkbenchLaunchContext.Rejected.self) {
            try WorkbenchLaunchContext.parse(marker: nil, environment: environment, required: false)
        }
    }

    @Test(arguments: ["denied", "wrong-folder", "missing-marker", "wrong-session", "wrong-task", "symlink-marker", "symlink-library", "symlink-appearance", "symlink-appearance-seed"])
    func admissionFailureNeverReachesWriters(kind: String) async throws {
        let fixture = try ReviewAdmissionFixture()
        defer { fixture.remove() }
        let before = try fixture.protectedBytes()
        if kind == "missing-marker" { try FileManager.default.removeItem(at: fixture.marker) }
        if kind == "wrong-session" { try fixture.writeMarker(session: UUID().uuidString) }
        if kind == "wrong-task" { try fixture.writeMarker(task: "other") }
        if kind == "symlink-marker" {
            let original = fixture.root.appendingPathComponent("original-marker")
            try FileManager.default.moveItem(at: fixture.marker, to: original)
            try FileManager.default.createSymbolicLink(at: fixture.marker, withDestinationURL: original)
        }
        if kind == "symlink-library" {
            try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("ModelLibrary"),
                withDestinationURL: fixture.parent)
        }
        if kind == "symlink-appearance" {
            try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("Appearance"),
                withDestinationURL: fixture.parent)
        }
        if kind == "symlink-appearance-seed" {
            let appearance = fixture.root.appendingPathComponent("Appearance")
            try FileManager.default.createDirectory(at: appearance, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: appearance.appendingPathComponent("initial-preferences.json"),
                withDestinationURL: fixture.marker)
        }
        var writerStarts = 0
        await #expect(throws: (any Error).self) {
            let lease = try await WorkbenchReviewAdmission.admit(fixture.review) { root in
                if kind == "denied" { throw CocoaError(.userCancelled) }
                return kind == "wrong-folder" ? root.deletingLastPathComponent() : root
            }
            withExtendedLifetime(lease) { writerStarts += 1 }
        }
        #expect(writerStarts == 0)
        #expect(try fixture.protectedBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".d-review-session.lock").path))
    }

    @Test func validAdmissionOwnsLeaseUntilReleasedAndAllowsCleanReopen() async throws {
        let fixture = try ReviewAdmissionFixture()
        defer { fixture.remove() }
        var first: WorkbenchReviewLease? = try await WorkbenchReviewAdmission.admit(fixture.review) { $0 }
        #expect(first != nil)
        await #expect(throws: WorkbenchLaunchContext.Rejected.self) {
            _ = try await WorkbenchReviewAdmission.admit(fixture.review) { $0 }
        }
        first = nil
        let reopened = try await WorkbenchReviewAdmission.admit(fixture.review) { $0 }
        withExtendedLifetime(reopened) { #expect(FileManager.default.fileExists(atPath: fixture.marker.path)) }
    }

    #if canImport(DWorkbench)
    @Test func retryAfterLibraryFailureRechecksPathsWithoutReauthorizing() async throws {
        let fixture = try ReviewAdmissionFixture()
        defer { fixture.remove() }
        let library = fixture.root.appendingPathComponent("ModelLibrary")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        try Data("broken index".utf8).write(to: library.appendingPathComponent("index.json"))
        var authorizations = 0
        let bootstrap = WorkbenchBootstrap(launchContext: .success(.review(fixture.review)), reviewAuthorizer: { root in
            authorizations += 1; return root
        })
        await bootstrap.start()
        #expect(authorizations == 1 && bootstrap.model == nil && bootstrap.startupError != nil)
        try FileManager.default.removeItem(at: library)
        try FileManager.default.createSymbolicLink(at: library, withDestinationURL: fixture.parent)
        await bootstrap.start()
        #expect(authorizations == 1 && bootstrap.model == nil && bootstrap.libraryModel == nil)
        #expect(bootstrap.startupError?.contains("Review service path contains a symbolic link") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent("index.json").path))
    }

    @Test func actualBootstrapSerializesAuthorizationAndRetriesAfterDenial() async throws {
        let fixture = try ReviewAdmissionFixture()
        defer { fixture.remove() }
        var requests = 0
        var answer: CheckedContinuation<URL, Error>?
        let bootstrap = WorkbenchBootstrap(launchContext: .success(.review(fixture.review)), reviewAuthorizer: { _ in
            requests += 1
            if requests > 1 { throw CocoaError(.userCancelled) }
            return try await withCheckedThrowingContinuation { answer = $0 }
        })
        let first = Task { await bootstrap.start() }
        while answer == nil { await Task.yield() }
        await bootstrap.start()
        #expect(requests == 1)
        answer?.resume(throwing: CocoaError(.userCancelled))
        await first.value
        #expect(bootstrap.model == nil && bootstrap.libraryModel == nil && bootstrap.sharedLibrary == nil)
        await bootstrap.start()
        #expect(requests == 2)
        #expect(bootstrap.model == nil && bootstrap.quick == nil && bootstrap.nodeTags == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".d-review-session.lock").path))
    }

    @Test(arguments: ["all", "malformed", "probe"])
    func actualBootstrapRejectsBeforeConstructingServices(kind: String) async throws {
        var env = kind == "all" ? [:] : environment
        if kind == "malformed" { env["D_UI_TEST_SESSION"] = "invalid" }
        if kind == "probe" { env["D_AUDIO_DEPLOYMENT_CHECK"] = "1" }
        let context = Result { try WorkbenchLaunchContext.parse(marker: WorkbenchLaunchContext.markerValue, environment: env, required: true) }
        let bootstrap = WorkbenchBootstrap(launchContext: context)
        await bootstrap.start()
        await bootstrap.start()
        #expect(bootstrap.startupError?.contains("Review startup refused") == true)
        #expect(bootstrap.model == nil && bootstrap.quickModel == nil && bootstrap.quick == nil)
        #expect(bootstrap.libraryModel == nil && bootstrap.sharedLibrary == nil && bootstrap.nodeTags == nil)
    }
    #endif
}

private struct ReviewAdmissionFixture {
    let parent: URL
    let root: URL
    let session = UUID()
    var marker: URL { root.appendingPathComponent("download-review-fixture.json") }
    var review: WorkbenchLaunchContext.Review {
        .init(session: session, root: root, source: URL(string: "http://127.0.0.1:49152")!)
    }
    init() throws {
        // App-host tests use its dedicated sandbox temp directory; parser tests still
        // exercise the production /Volumes restriction without weakening it.
        let base: String
        if Bundle.main.bundleIdentifier == "first-test.D.review.D" { base = NSTemporaryDirectory() }
        else if let external = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"], external.hasPrefix("/Volumes/") { base = external }
        else { throw CocoaError(.fileNoSuchFile) }
        parent = URL(fileURLWithPath: base).resolvingSymlinksInPath().appendingPathComponent("ReviewAdmission-" + UUID().uuidString)
        root = parent.appendingPathComponent(session.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("protected ordinary settings/index/Quick sentinel".utf8).write(to: parent.appendingPathComponent("protected"))
        try writeMarker()
    }
    func writeMarker(session: String? = nil, task: String = "D-DOWNLOAD-MANAGEMENT-01") throws {
        try JSONSerialization.data(withJSONObject: ["task": task, "session": session ?? self.session.uuidString,
            "fixtures": "A/B/C 18 MiB each; no inference route"]).write(to: marker)
    }
    func protectedBytes() throws -> Data { try Data(contentsOf: parent.appendingPathComponent("protected")) }
    func remove() { try? FileManager.default.removeItem(at: parent) }
}
