import Darwin
import Foundation
import Testing
@testable import DMLXBackend

@Suite("External video owned process group", .serialized)
struct ExternalVideoProcessTests {
    @Test("Both streams drain with bounded tails; cwd, Unicode argv and explicit environment survive")
    func successfulOutput() async throws {
        let root = try fixtureRoot()
        let value = "影片 with spaces 雪"
        let script = #"""
        import os,sys
        print(os.getcwd(), sys.argv[1], os.environ['D_TEST_VALUE'], sep='|', flush=True)
        sys.stdout.write('o'*90000 + '\nstdout-end\n');sys.stdout.flush()
        sys.stderr.write('e'*90000 + '\nstderr-end\n');sys.stderr.flush()
        """#
        let result = try await process(root: root, script: script, arguments: [value],
                                       extraEnvironment: ["D_TEST_VALUE": value]).run()
        #expect(result.reason == .exited)
        #expect(result.exitCode == 0)
        #expect(result.processID != nil)
        #expect(result.fullyDrained)
        #expect(result.stdoutTail.utf8.count <= 65_536)
        #expect(result.stderrTail.utf8.count <= 65_536)
        #expect(result.stdoutTail.hasSuffix("stdout-end\n"))
        #expect(result.stderrTail.hasSuffix("stderr-end\n"))
        // The leading metadata can be truncated by the bounded tail, so a second
        // short run checks its exact transport separately.
        let short = try await process(root: root,
            script: "import os,sys;print(os.getcwd(),sys.argv[1],os.environ['D_TEST_VALUE'],sep='|')",
            arguments: [value], extraEnvironment: ["D_TEST_VALUE": value]).run()
        #expect(short.stdoutTail == "\(root.path)|\(value)|\(value)\n")
        #expect(short.fullyDrained)
    }

    @Test("A nonzero exit is still a fully drained exit with the real code")
    func nonzeroExit() async throws {
        let root = try fixtureRoot()
        let result = try await process(root: root,
            script: "import sys;print('failure detail',file=sys.stderr);sys.exit(7)").run()
        #expect(result.reason == .exited)
        #expect(result.exitCode == 7)
        #expect(result.fullyDrained)
        #expect(result.stderrTail.contains("failure detail"))
    }

    @Test("Cancellation already set on the calling task never launches")
    func preCancelled() async throws {
        let root = try fixtureRoot()
        let marker = root.appendingPathComponent("must-not-launch")
        let job = process(root: root,
            script: "import pathlib,sys;pathlib.Path(sys.argv[1]).write_text('launched')",
            arguments: [marker.path])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await job.run()
        }
        let result = try await task.value
        #expect(result.reason == .cancelled)
        #expect(result.processID == nil)
        #expect(result.fullyDrained)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Cancellation escalates from TERM to KILL for an owned resistant descendant")
    func cancelledDescendant() async throws {
        let root = try fixtureRoot()
        let job = process(root: root, script: Self.groupFixture(exitRoot: false),
                          arguments: [root.path], timeout: 8, grace: 0.15)
        let task = Task { try await job.run() }
        do { try await waitFor(root.appendingPathComponent("root-ready")) }
        catch { task.cancel(); _ = try? await task.value; throw error }
        task.cancel()
        let result = try await task.value
        #expect(result.reason == .cancelled)
        #expect(result.fullyDrained)
        #expect(result.exitCode == -SIGTERM || result.exitCode == -SIGKILL)
        try assertOwnedGroupGone(result)
    }

    @Test("Timeout terminates and drains the owned process group")
    func timeout() async throws {
        let root = try fixtureRoot()
        let result = try await process(root: root,
            script: "import time;time.sleep(30)", timeout: 0.2, grace: 0.1).run()
        #expect(result.reason == .timedOut)
        #expect(result.fullyDrained)
        try assertOwnedGroupGone(result)
    }

    @Test("Root exit while descendant holds pipes cannot be reported as success")
    func earlyRootExit() async throws {
        let root = try fixtureRoot()
        let result = try await process(root: root, script: Self.groupFixture(exitRoot: true),
                                       arguments: [root.path], timeout: 8, grace: 0.15).run()
        #expect(result.reason == .cleanupUnconfirmed)
        #expect(result.exitCode == 0)
        #expect(result.stderrTail.contains("root exited while its owned process group remained"))
        #expect(result.fullyDrained)
        try assertOwnedGroupGone(result)
    }

    @Test("Launch validation and missing executable fail without fd growth")
    func preSpawnFailures() async throws {
        let root = try fixtureRoot()
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<5 {
            let missing = ExternalVideoProcess(executable: root.appendingPathComponent("missing-tool"),
                arguments: [], environment: [:], currentDirectory: root,
                timeoutSeconds: 1, cancellationGraceSeconds: 0.1)
            await #expect(throws: (any Error).self) { try await missing.run() }
        }
        let invalid = process(root: root, script: "pass", arguments: ["bad\0argument"])
        await #expect(throws: (any Error).self) { try await invalid.run() }
        let invalidTime = ExternalVideoProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [], environment: [:], currentDirectory: root,
            timeoutSeconds: .infinity, cancellationGraceSeconds: 0.1)
        await #expect(throws: (any Error).self) { try await invalidTime.run() }
        let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        #expect(after <= before + 2)
    }

    private func fixtureRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["D_TEST_EXTERNAL_VIDEO_ROOT"], !path.isEmpty else {
            throw NSError(domain: "ExternalVideoProcessTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "D_TEST_EXTERNAL_VIDEO_ROOT is required"])
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("外部 video \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func process(root: URL, script: String, arguments: [String] = [],
                         extraEnvironment: [String: String] = [:],
                         timeout: Double = 5, grace: Double = 0.1) -> ExternalVideoProcess {
        ExternalVideoProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-B", "-c", script] + arguments,
            environment: ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1",
                          "TMPDIR": root.path].merging(extraEnvironment) { _, new in new },
            currentDirectory: root, timeoutSeconds: timeout, cancellationGraceSeconds: grace)
    }

    private static func groupFixture(exitRoot: Bool) -> String {
        // subprocess inherits the new process group and both redirected pipes.
        // The child confirms that SIGTERM is ignored before the parent publishes
        // root-ready. The test never interpolates a filesystem path into Python.
        """
        import pathlib,subprocess,sys,time
        root=pathlib.Path(sys.argv[1])
        child="import pathlib,signal,sys,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);pathlib.Path(sys.argv[1]).write_text('ready');time.sleep(30)"
        descendant=subprocess.Popen([sys.executable,'-B','-c',child,str(root/'child-ready')],stdin=subprocess.DEVNULL)
        for _ in range(400):
            if (root/'child-ready').exists():break
            time.sleep(0.005)
        assert (root/'child-ready').exists()
        (root/'root-ready').write_text(str(descendant.pid))
        \(exitRoot ? "sys.exit(0)" : "time.sleep(30)")
        """
    }

    private func waitFor(_ marker: URL) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: marker.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ExternalVideoProcessTests", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Fixture did not publish \(marker.lastPathComponent)"])
    }

    private func assertOwnedGroupGone(_ result: ExternalVideoProcessResult) throws {
        let pid = try #require(result.processID)
        let probe = Darwin.kill(-pid, 0)
        let code = errno
        #expect(probe == -1)
        #expect(code == ESRCH)
    }
}
