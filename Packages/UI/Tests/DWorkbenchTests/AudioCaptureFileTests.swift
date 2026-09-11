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

private final class LifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var disposeResults: [OSStatus]
    private var closeCountValue = 0
    init(disposeResults: [OSStatus]) { self.disposeResults = disposeResults }
    func stop(_ queue: AudioQueueRef, _ immediate: Bool) -> OSStatus { noErr }
    func dispose(_ queue: AudioQueueRef, _ immediate: Bool) -> OSStatus {
        lock.withLock { disposeResults.isEmpty ? noErr : disposeResults.removeFirst() }
    }
    func close(_ file: AudioFileID) -> OSStatus {
        lock.withLock { closeCountValue += 1 }
        return AudioFileClose(file)
    }
    var closeCount: Int { lock.withLock { closeCountValue } }
}

private final class WeakCaptureBox {
    weak var value: AudioCaptureFile?
    init(_ value: AudioCaptureFile?) { self.value = value }
}

@Suite("Descriptor-backed audio capture file")
struct AudioCaptureFileTests {
    @Test(arguments: [false, true])
    func nativeCAFFlagsAreNotASBDByteOrderFlags(bigEndian: Bool) throws {
        let root = try captureFileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try makeCaptureFile(in: root)
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (bigEndian ? kAudioFormatFlagIsBigEndian : 0),
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let file = try capture.initializeAudioFile(format: &format)
        var words = [Float(0.25), Float(-0.5)].map {
            bigEndian ? $0.bitPattern.bigEndian : $0.bitPattern.littleEndian
        }
        var packets: UInt32 = 2
        let status = words.withUnsafeMutableBytes {
            AudioFileWritePackets(file, false, UInt32($0.count), nil, 0, &packets, $0.baseAddress!)
        }
        #expect(status == noErr && packets == 2)
        #expect(AudioFileClose(file) == noErr)
        _ = try capture.sealAndFingerprint()
        let bytes = try captureBytes(capture)
        let flags = bytes[32..<36].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(flags == (bigEndian ? 1 : 3))
        let descriptor = try capture.duplicateDescriptor()
        defer { Darwin.close(descriptor) }
        if bigEndian {
            #expect(throws: AudioMediaError.self) { try AudioMediaInspector.inspectCapture(descriptor: descriptor) }
        } else {
            let checked = try AudioMediaInspector.inspectCapture(descriptor: descriptor)
            #expect(checked.inspection.format.frameCount == 2)
            #expect(checked.inspection.waveform.map(\.minimum) == [0.25, -0.5])
            #expect(checked.inspection.waveform.map(\.maximum) == [0.25, -0.5])
        }
    }

    @MainActor @Test
    func fileCloseFailureDoesNotReleaseNativeAdmission() throws {
        let root = try captureFileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try makeCaptureFile(in: root)
        let gate = AudioRecordingAdmissionGate()
        let lifecycle = AudioQueueLifecycleOperations(stop: { _, _ in noErr },
            dispose: { _, _ in noErr }, closeFile: { file in
                // The fixture closes its real AudioFile, then simulates an uncertain report.
                // Production cannot assume a close succeeded just because this fixture did.
                #expect(AudioFileClose(file) == noErr)
                return -1
            })
        var device: AudioQueueRecordingDevice? = try AudioQueueRecordingDevice(
            testing: capture, queue: try #require(OpaquePointer(bitPattern: 17)),
            lifecycle: lifecycle, admissionGate: gate)
        #expect(try #require(device).stop(error: nil).error != nil)
        do {
            let unexpected = try gate.acquire()
            gate.releaseAfterKnownTermination(unexpected)
            Issue.record("Uncertain AudioFileClose incorrectly released native admission")
        } catch { #expect(error.localizedDescription.contains("重启")) }
        // Unknown-close quarantine may retain one callback context until this CPU test
        // process exits. No real AudioQueue or live AudioFile remains in this fixture.
        device = nil
    }

    @MainActor @Test(arguments: [false, true])
    func queueCreationFailureUsesDurabilityAndCloseUncertaintyPolicy(closeFails: Bool) throws {
        let root = try captureFileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = SynchronizeProbe()
        let capture = try makeCaptureFile(in: root, synchronizeFile: sync.file,
                                         synchronizeDirectory: sync.directory)
        let gate = AudioRecordingAdmissionGate()
        var closeCount = 0
        let lifecycle = AudioQueueLifecycleOperations(stop: { _, _ in
            Issue.record("Nil queue must not be stopped"); return noErr
        }, dispose: { _, _ in
            Issue.record("Nil queue must not be disposed"); return noErr
        }, closeFile: { file in
            closeCount += 1
            #expect(AudioFileClose(file) == noErr)
            return closeFails ? -1 : noErr
        })
        var message: String?
        do {
            _ = try AudioQueueRecordingDevice(capture: capture, lifecycle: lifecycle,
                admissionGate: gate, createQueue: { _, _ in (-7, nil) })
            Issue.record("Controlled queue-creation failure was accepted")
        } catch { message = error.localizedDescription }
        #expect(message?.contains("-7") == true)
        #expect(message?.contains("同步失败") == true)
        #expect(closeCount == 1)
        #expect(sync.counts.0 >= 1 && sync.counts.1 >= 1)
        #expect(!(try captureBytes(capture)).isEmpty)
        if closeFails {
            #expect(message?.contains("关闭失败") == true)
            #expect(throws: AudioMediaError.self) { try gate.acquire() }
        } else {
            let token = try gate.acquire()
            gate.releaseAfterKnownTermination(token)
        }
    }

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

    @Test func sealedCaptureRejectsRealAudioFilePacketCallbackWithoutMutation() throws {
        let root = try captureFileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try makeCaptureFile(in: root)
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        let audioFile = try capture.initializeAudioFile(format: &format)
        var first: Float = 0.25
        var firstPackets: UInt32 = 1
        let firstStatus = withUnsafeMutableBytes(of: &first) {
            AudioFileWritePackets(audioFile, false, UInt32($0.count), nil,
                                  0, &firstPackets, $0.baseAddress!)
        }
        #expect(firstStatus == noErr)
        #expect(firstPackets == 1)

        let sealed = try capture.sealAndFingerprint()
        let sealedBytes = try captureBytes(capture)
        var second: Float = -0.5
        var secondPackets: UInt32 = 1
        let rejected = withUnsafeMutableBytes(of: &second) {
            AudioFileWritePackets(audioFile, false, UInt32($0.count), nil,
                                  1, &secondPackets, $0.baseAddress!)
        }
        #expect(rejected != noErr)
        #expect(try capture.fingerprint() == sealed)
        #expect(try captureBytes(capture) == sealedBytes)
        _ = AudioFileClose(audioFile)
        #expect(try capture.fingerprint() == sealed)
        #expect(try captureBytes(capture) == sealedBytes)
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
    @Test func failedQueueDisposeBlocksSecondAdmissionUntilKnownRelease() throws {
        let root = try captureFileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AudioRecordingAdmissionGate()
        let probe = LifecycleProbe(disposeResults: [-1, noErr, noErr])
        let lifecycle = AudioQueueLifecycleOperations(stop: probe.stop,
                                                      dispose: probe.dispose,
                                                      closeFile: probe.close)
        var capture: AudioCaptureFile? = try makeCaptureFile(in: root)
        let retainedCapture = WeakCaptureBox(capture)
        var device: AudioQueueRecordingDevice? = try AudioQueueRecordingDevice(
            testing: try #require(capture), queue: try #require(OpaquePointer(bitPattern: 2)),
            lifecycle: lifecycle, admissionGate: gate
        )
        capture = nil
        let result = try #require(device).stop(error: nil)
        #expect(result.error?.contains("所有权已保留") == true)
        #expect(probe.closeCount == 0)

        let refusedCapture = try makeCaptureFile(in: root)
        var refusal: String?
        do {
            _ = try AudioQueueRecordingDevice(
                testing: refusedCapture, queue: try #require(OpaquePointer(bitPattern: 3)),
                lifecycle: lifecycle, admissionGate: gate
            )
            Issue.record("termination-unknown gate admitted a second native recording")
        } catch {
            refusal = error.localizedDescription
        }
        #expect(refusal?.contains("重启应用后再录音") == true)
        #expect(try captureBytes(refusedCapture).isEmpty)
        #expect(probe.closeCount == 0)

        // Resource deinit retries the same native operation. The controlled second dispose
        // succeeds, so AudioFile closes and the process admission gate becomes available.
        device = nil
        #expect(retainedCapture.value == nil)
        #expect(probe.closeCount == 1)

        let recoveredCapture = try makeCaptureFile(in: root)
        var recovered: AudioQueueRecordingDevice? = try AudioQueueRecordingDevice(
            testing: recoveredCapture, queue: try #require(OpaquePointer(bitPattern: 4)),
            lifecycle: lifecycle, admissionGate: gate
        )
        let recoveredDevice = try #require(recovered)
        #expect(recoveredDevice.stop(error: nil).error == nil)
        recovered = nil
        #expect(probe.closeCount == 2)
    }
}

private func makeCaptureFile(in root: URL,
                             synchronizeFile: @escaping (Int32) -> Int32 = { fsync($0) },
                             synchronizeDirectory: @escaping (Int32) -> Int32 = { fsync($0) }) throws -> AudioCaptureFile {
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
                            fileIdentity: AudioCaptureIdentity(fileInfo),
                            synchronizeFile: synchronizeFile, synchronizeDirectory: synchronizeDirectory)
}

private func captureBytes(_ capture: AudioCaptureFile) throws -> Data {
    let descriptor = try capture.duplicateDescriptor()
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_size >= 0,
          info.st_size <= AudioLimits.maximumBytes else {
        throw AudioMediaError.io("fixture stat")
    }
    var data = Data(count: Int(info.st_size))
    let byteCount = data.count
    var offset = 0
    while offset < byteCount {
        let count = data.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress!.advanced(by: offset), byteCount - offset, off_t(offset))
        }
        guard count > 0 else { throw AudioMediaError.io("fixture read") }
        offset += count
    }
    return data
}

private func captureFileTestDirectory() throws -> URL {
    let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
        ?? FileManager.default.temporaryDirectory.path
    let result = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent("capture-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    return result
}
