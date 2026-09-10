import AudioToolbox
import Darwin
import Foundation
import Testing
@testable import DWorkbench

private final class SynchronizeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values = (file: 0, directory: 0)
    func file(_ descriptor: Int32) -> Int32 {
        lock.withLock { values.file += 1 }
        return -1
    }
    func directory(_ descriptor: Int32) -> Int32 {
        lock.withLock { values.directory += 1 }
        return 0
    }
    var counts: (Int, Int) { lock.withLock { (values.file, values.directory) } }
}

@Suite("Descriptor-backed audio capture file")
struct AudioCaptureFileTests {
    @Test func callbackFailureStillAttemptsFileAndDirectoryDurability() throws {
        let root = try captureFileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(directory >= 0)
        defer { Darwin.close(directory) }
        let descriptor = openat(directory, "capture.caf",
                                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(descriptor >= 0)
        let parent = dup(directory)
        try #require(parent >= 0)
        var directoryInfo = stat(), fileInfo = stat()
        try #require(fstat(directory, &directoryInfo) == 0)
        try #require(fstat(descriptor, &fileInfo) == 0)
        let probe = SynchronizeProbe()
        let capture = AudioCaptureFile(
            id: UUID(), url: root.appendingPathComponent("capture.caf"),
            fileDescriptor: descriptor, directoryDescriptor: parent,
            rootIdentity: AudioCaptureIdentity(directoryInfo),
            directoryIdentity: AudioCaptureIdentity(directoryInfo),
            fileIdentity: AudioCaptureIdentity(fileInfo),
            synchronizeFile: probe.file, synchronizeDirectory: probe.directory
        )
        capture.injectCallbackErrorForTesting("controlled callback failure")
        let failure = try #require(capture.synchronize())
        #expect(failure.contains("controlled callback failure"))
        #expect(failure.contains("录音文件同步失败"))
        #expect(probe.counts.0 == 1)
        #expect(probe.counts.1 == 1)
    }


    @MainActor
    @Test func synchronousStopDeliveredPCMIsWrittenBeforeAudioFileClose() throws {
        let root = try captureFileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try makeCaptureFile(in: root)
        var device: AudioQueueRecordingDevice?
        let queue = try #require(OpaquePointer(bitPattern: 1))
        let lifecycle = AudioQueueLifecycleOperations(
            stop: { _, _ in
                #expect(device?.deliverStopBufferForTesting([0.25, -0.25, 0.5]) == noErr)
                return noErr
            },
            dispose: { _, _ in noErr },
            closeFile: { AudioFileClose($0) }
        )
        device = try AudioQueueRecordingDevice(testing: capture, queue: queue,
                                               lifecycle: lifecycle)
        let result = try #require(device).stop(error: nil)
        #expect(result.error == nil)
        let descriptor = try capture.duplicateDescriptor()
        defer { Darwin.close(descriptor) }
        #expect(try AudioMediaInspector.inspectCapture(descriptor: descriptor)
            .inspection.format.frameCount == 3)
        device = nil
    }

    @MainActor
    @Test func failedQueueDisposeRetainsCallbackCaptureAndDoesNotCloseAudioFile() throws {
        let root = try captureFileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var capture: AudioCaptureFile? = try makeCaptureFile(in: root)
        weak var retainedCapture = capture
        let closeProbe = SynchronizeProbe()
        let lifecycle = AudioQueueLifecycleOperations(
            stop: { _, _ in noErr },
            dispose: { _, _ in -1 },
            closeFile: { _ in _ = closeProbe.file(0); return noErr }
        )
        var device: AudioQueueRecordingDevice? = try AudioQueueRecordingDevice(
            testing: try #require(capture), queue: try #require(OpaquePointer(bitPattern: 2)),
            lifecycle: lifecycle
        )
        capture = nil
        let result = try #require(device).stop(error: nil)
        #expect(result.error?.contains("所有权已保留") == true)
        #expect(closeProbe.counts.0 == 0)
        device = nil
        #expect(retainedCapture != nil)
        #expect(closeProbe.counts.0 == 0)
    }
}

private func makeCaptureFile(in root: URL) throws -> AudioCaptureFile {
    let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try #require(directory >= 0)
    defer { Darwin.close(directory) }
    let name = "capture-\(UUID().uuidString).caf"
    let descriptor = openat(directory, name,
                            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    try #require(descriptor >= 0)
    let parent = dup(directory)
    try #require(parent >= 0)
    var directoryInfo = stat(), fileInfo = stat()
    try #require(fstat(directory, &directoryInfo) == 0)
    try #require(fstat(descriptor, &fileInfo) == 0)
    return AudioCaptureFile(id: UUID(), url: root.appendingPathComponent(name),
                            fileDescriptor: descriptor, directoryDescriptor: parent,
                            rootIdentity: AudioCaptureIdentity(directoryInfo),
                            directoryIdentity: AudioCaptureIdentity(directoryInfo),
                            fileIdentity: AudioCaptureIdentity(fileInfo))
}

private func captureFileTestDirectory() throws -> URL {
    let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
        ?? FileManager.default.temporaryDirectory.path
    let result = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent("capture-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    return result
}
