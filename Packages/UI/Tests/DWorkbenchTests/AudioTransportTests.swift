import AudioToolbox
import Darwin
import Foundation
import Testing
@testable import DWorkbench

@MainActor
private final class AudioTestLog {
    var entries: [String] = []
}

@MainActor
private final class FakePlaybackDevice: AudioPlaybackDevice {
    let name: String
    let log: AudioTestLog
    var prepared = true
    var currentFrame: Int64 = 0
    private(set) var segments: [(Int64, Int64)] = []
    private(set) var callbacks: [@MainActor @Sendable (String?) -> Void] = []
    var startResult = true
    var throwOnPlay = false

    init(name: String, log: AudioTestLog) {
        self.name = name
        self.log = log
    }

    func playSegment(
        startFrame: Int64,
        frameCount: Int64,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) throws -> Bool {
        log.entries.append("play:\(name):\(startFrame)+\(frameCount)")
        if throwOnPlay { throw AudioMediaError.unavailable("injected replay error") }
        guard prepared else { return false }
        currentFrame = startFrame
        segments.append((startFrame, frameCount))
        callbacks.append(completion)
        return startResult
    }

    func pause() -> Int64 {
        log.entries.append("pause:\(name)")
        return currentFrame
    }

    func stop() {
        log.entries.append("stop:\(name)")
        prepared = false
    }

    func fire(_ index: Int, error: String? = nil) {
        callbacks[index](error)
    }
}

@MainActor
private final class FakeRecordingDevice: AudioRecordingDevice {
    let name: String
    let url: URL
    let log: AudioTestLog
    var currentSeconds = 0.0
    var returnedURL: URL?
    var stopError: String?
    var startResult = true
    var synchronousResult: AudioRecordingResult?
    private(set) var closed = false
    private(set) var callbacks: [@MainActor @Sendable (AudioRecordingResult) -> Void] = []

    init(name: String, url: URL, log: AudioTestLog) {
        self.name = name
        self.url = url
        self.returnedURL = url
        self.log = log
    }

    func start(
        completion: @escaping @MainActor @Sendable (AudioRecordingResult) -> Void
    ) throws -> Bool {
        log.entries.append("start-recording:\(name)")
        callbacks.append(completion)
        if let synchronousResult {
            closed = true
            log.entries.append("close:\(name)")
            completion(synchronousResult)
        }
        return startResult
    }

    func stop(error: String?) -> AudioRecordingResult {
        guard !closed else {
            return AudioRecordingResult(
                url: returnedURL,
                error: error ?? stopError ?? "already closed"
            )
        }
        closed = true
        log.entries.append("close:\(name)")
        return AudioRecordingResult(url: returnedURL, error: error ?? stopError)
    }

    func finishFromDevice(error: String? = nil, callback index: Int = 0) {
        if !closed {
            closed = true
            log.entries.append("close:\(name)")
        }
        callbacks[index](AudioRecordingResult(url: returnedURL, error: error))
    }
}

@MainActor
private final class FakeAudioFactory: AudioTransportDeviceFactory {
    let log = AudioTestLog()
    var permissionResult = true
    var suspendPermission = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var failNextPlayback = false
    var configureRecording: ((FakeRecordingDevice) -> Void)?
    private(set) var permissionRequests = 0
    private(set) var playbacks: [FakePlaybackDevice] = []
    private(set) var recordings: [FakeRecordingDevice] = []

    func requestRecordPermission() async -> Bool {
        permissionRequests += 1
        log.entries.append("permission")
        if suspendPermission {
            return await withCheckedContinuation { permissionContinuation = $0 }
        }
        return permissionResult
    }

    func resolvePermission(_ result: Bool) {
        permissionContinuation?.resume(returning: result)
        permissionContinuation = nil
    }

    func makePlayback(
        url: URL,
        expected: DWorkbench.AudioFormatInfo
    ) throws -> any AudioPlaybackDevice {
        log.entries.append("prepare-playback")
        if failNextPlayback {
            failNextPlayback = false
            throw AudioMediaError.invalidMedia("fixture replacement failed")
        }
        let device = FakePlaybackDevice(name: "p\(playbacks.count)", log: log)
        playbacks.append(device)
        return device
    }

    func makeRecording(capture: AudioCaptureFile) throws -> any AudioRecordingDevice {
        log.entries.append("prepare-recording")
        let descriptor = try capture.duplicateDescriptor()
        defer { Darwin.close(descriptor) }
        let marker = Data([0x43, 0x41, 0x46, 0x21])
        try marker.withUnsafeBytes { try AudioSafeTestWrite.all($0, descriptor: descriptor) }
        let device = FakeRecordingDevice(name: "r\(recordings.count)", url: capture.url, log: log)
        configureRecording?(device)
        recordings.append(device)
        return device
    }
}


// Existing device tests supply a fixture-only leaf validator. Production callers must
// provide ProjectStore's descriptor-anchored validator; there is no production default.
@MainActor
private extension AudioTransport {
    func requestAndStartRecording(to url: URL) async throws {
        try await requestAndStartRecording(to: url, revalidate: {
            var info = stat()
            guard lstat(url.path, &info) != 0, errno == ENOENT else {
                throw AudioMediaError.io("fixture destination already exists")
            }
        }, createCapture: { try fixtureCapture(at: url) })
    }

    func requestAndStartRecording(
        to url: URL,
        revalidate: @MainActor @Sendable () async throws -> Void
    ) async throws {
        try await requestAndStartRecording(to: url, revalidate: revalidate,
                                           createCapture: { try fixtureCapture(at: url) })
    }
}

private enum AudioSafeTestWrite {
    static func all(_ bytes: UnsafeRawBufferPointer, descriptor: Int32) throws {
        guard ftruncate(descriptor, 0) == 0 else { throw AudioMediaError.io("fixture truncate") }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.pwrite(descriptor, bytes.baseAddress!.advanced(by: offset),
                                      bytes.count - offset, off_t(offset))
            guard count > 0 else { throw AudioMediaError.io("fixture write") }
            offset += count
        }
    }
}

private func fixtureCapture(at url: URL) throws -> AudioCaptureFile {
    let directory = Darwin.open(url.deletingLastPathComponent().path,
                                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw AudioMediaError.io("fixture directory") }
    defer { Darwin.close(directory) }
    let descriptor = openat(directory, url.lastPathComponent,
                            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw AudioMediaError.io("fixture capture") }
    var fileTransferred = false
    defer { if !fileTransferred { Darwin.close(descriptor) } }
    let parent = dup(directory)
    guard parent >= 0 else { throw AudioMediaError.io("fixture duplicate") }
    var rootInfo = stat(), fileInfo = stat()
    guard fstat(directory, &rootInfo) == 0, fstat(descriptor, &fileInfo) == 0 else {
        Darwin.close(parent)
        throw AudioMediaError.io("fixture identity")
    }
    let capture = AudioCaptureFile(id: UUID(), url: url, fileDescriptor: descriptor,
                                   directoryDescriptor: parent,
                                   rootIdentity: AudioCaptureIdentity(rootInfo),
                                   directoryIdentity: AudioCaptureIdentity(rootInfo),
                                   fileIdentity: AudioCaptureIdentity(fileInfo))
    fileTransferred = true
    return capture
}

@Suite("Audio transport", .serialized)
@MainActor
struct AudioTransportTests {
    private let format = DWorkbench.AudioFormatInfo(
        container: .wav,
        sampleRate: 48_000,
        channelCount: 1,
        frameCount: 480,
        bitDepth: 16,
        floatingPoint: false
    )

    private func uniqueDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] else {
            throw AudioMediaError.unavailable("D_TEST_TEMP_DIR is required")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func syntheticWAV(in directory: URL, name: String = UUID().uuidString) throws -> URL {
        let url = directory.appendingPathComponent(name).appendingPathExtension("wav")
        let sampleCount: UInt32 = 480
        let dataBytes = sampleCount * 2
        var bytes = Data()
        func ascii(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        ascii("RIFF"); u32(36 + dataBytes); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(48_000); u32(96_000); u16(2); u16(16)
        ascii("data"); u32(dataBytes)
        bytes.append(Data(repeating: 0, count: Int(dataBytes)))
        try bytes.write(to: url, options: .withoutOverwriting)
        return url
    }

    private func syntheticCAF(in directory: URL, name: String = UUID().uuidString) throws -> URL {
        let url = directory.appendingPathComponent(name).appendingPathExtension("caf")
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var fileID: AudioFileID?
        let createStatus = AudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &description,
            .eraseFile,
            &fileID
        )
        guard createStatus == noErr, let fileID else {
            throw AudioMediaError.io("Unable to create native CAF fixture: \(createStatus)")
        }
        defer { AudioFileClose(fileID) }

        let samples = [Int16](repeating: 0, count: 480)
        var byteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        let writeStatus = samples.withUnsafeBytes { buffer in
            AudioFileWriteBytes(fileID, false, 0, &byteCount, buffer.baseAddress!)
        }
        guard writeStatus == noErr else {
            throw AudioMediaError.io("Unable to write native CAF fixture: \(writeStatus)")
        }
        return url
    }

    private func waitForPermissionRequest(_ subject: AudioTransport, factory: FakeAudioFactory) async throws {
        for _ in 0..<1000 where factory.permissionContinuation == nil {
            await Task.yield()
        }
        #expect(subject.state == .requestingPermission)
        #expect(factory.permissionContinuation != nil)
    }

    @Test
    func disabledRecordingPerformsNoPermissionOrDeviceWork() async throws {
        let factory = FakeAudioFactory()
        let subject = AudioTransport(deviceFactory: factory)
        let target = try uniqueDirectory().appendingPathComponent("capture.caf")

        await #expect(throws: AudioMediaError.self) {
            try await subject.requestAndStartRecording(to: target)
        }

        #expect(factory.permissionRequests == 0)
        #expect(factory.recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(factory.log.entries.isEmpty)
    }

    @Test
    func boundedPlaybackAndReplacementKeepCorrectResourceOwnership() throws {
        let root = try uniqueDirectory()
        let firstURL = try syntheticWAV(in: root, name: "first")
        let secondURL = try syntheticWAV(in: root, name: "second")
        let factory = FakeAudioFactory()
        let subject = AudioTransport(deviceFactory: factory)

        try subject.preparePlayback(
            url: firstURL,
            format: format,
            range: .init(startFrame: 100, endFrame: 220)
        )
        try subject.play()
        let first = try #require(factory.playbacks.first)
        #expect(first.prepared)
        #expect(first.segments.first?.0 == 100)
        #expect(first.segments.first?.1 == 120)

        factory.failNextPlayback = true
        #expect(throws: AudioMediaError.self) {
            try subject.preparePlayback(url: secondURL, format: format)
        }
        #expect(first.prepared)
        subject.pause()
        try subject.play()

        let oldCallback = first.callbacks.count - 1
        try subject.preparePlayback(url: secondURL, format: format)
        let second = try #require(factory.playbacks.last)
        #expect(!first.prepared)
        #expect(second.prepared)
        try subject.play()
        first.fire(oldCallback, error: "late old failure")
        #expect(subject.state == .playing)
        #expect(subject.errorMessage == nil)
        #expect(second.segments.first?.1 == format.frameCount)
    }

    @Test
    func invalidRangesNeverReachPlaybackFactory() throws {
        let root = try uniqueDirectory()
        let url = try syntheticWAV(in: root)
        let factory = FakeAudioFactory()
        let subject = AudioTransport(deviceFactory: factory)

        for range in [
            AudioFrameRange(startFrame: 0, endFrame: 0),
            AudioFrameRange(startFrame: -1, endFrame: 2),
            AudioFrameRange(startFrame: 20, endFrame: 481)
        ] {
            #expect(throws: AudioMediaError.self) {
                try subject.preparePlayback(url: url, format: format, range: range)
            }
        }
        #expect(factory.playbacks.isEmpty)
    }

    @Test
    func generatedPlaybackPolicyExpandsOnlyToExplicitBound() throws {
        let root = try uniqueDirectory()
        let url = root.appendingPathComponent("bounded-generated.wav")
        try Data([0]).write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AudioLimits.maximumBytes + 1))
        try handle.close()
        let generated = DWorkbench.AudioFormatInfo(
            container: .wav, sampleRate: 44_100, channelCount: 2,
            frameCount: 121 * 44_100, bitDepth: 32, floatingPoint: true)

        let originalFactory = FakeAudioFactory()
        let original = AudioTransport(deviceFactory: originalFactory)
        #expect(throws: AudioMediaError.self) {
            try original.preparePlayback(url: url, format: generated)
        }
        #expect(originalFactory.playbacks.isEmpty)

        let generatedFactory = FakeAudioFactory()
        let bounded = AudioTransport(deviceFactory: generatedFactory)
        try bounded.preparePlayback(url: url, format: generated, policy: .generated)
        #expect(generatedFactory.playbacks.count == 1)

        let tooLong = DWorkbench.AudioFormatInfo(
            container: .wav, sampleRate: 44_100, channelCount: 2,
            frameCount: 381 * 44_100, bitDepth: 32, floatingPoint: true)
        #expect(throws: AudioMediaError.self) {
            try AudioTransport(deviceFactory: FakeAudioFactory())
                .preparePlayback(url: url, format: tooLong, policy: .generated)
        }
    }

    @Test
    func realReaderRejectsMetadataMismatchWithoutStartingOutput() throws {
        let url = try syntheticWAV(in: uniqueDirectory())
        let wrong = DWorkbench.AudioFormatInfo(
            container: .wav,
            sampleRate: 44_100,
            channelCount: 1,
            frameCount: 480,
            bitDepth: 16,
            floatingPoint: false
        )
        let subject = AudioTransport()
        #expect(throws: AudioMediaError.self) {
            try subject.preparePlayback(url: url, format: wrong)
        }
        #expect(subject.state == .idle)
    }

    @Test
    func nativeReaderUsesRenamedWAVAndCAFContentAndAcceptsSignedPCM() throws {
        let root = try uniqueDirectory()
        let wav = try syntheticWAV(in: root, name: "native-wave")
        let renamedWAV = root.appendingPathComponent("native-wave.caf")
        try FileManager.default.moveItem(at: wav, to: renamedWAV)

        let wavSubject = AudioTransport()
        try wavSubject.preparePlayback(url: renamedWAV, format: format)
        #expect(wavSubject.state == .recorded)

        let conflictingCAF = DWorkbench.AudioFormatInfo(
            container: .caf,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            frameCount: format.frameCount,
            bitDepth: format.bitDepth,
            floatingPoint: format.floatingPoint
        )
        let wavConflict = AudioTransport()
        #expect(throws: AudioMediaError.self) {
            try wavConflict.preparePlayback(url: renamedWAV, format: conflictingCAF)
        }

        let caf = try syntheticCAF(in: root, name: "native-caf")
        let renamedCAF = root.appendingPathComponent("native-caf.wav")
        try FileManager.default.moveItem(at: caf, to: renamedCAF)
        let cafSubject = AudioTransport()
        try cafSubject.preparePlayback(url: renamedCAF, format: conflictingCAF)
        #expect(cafSubject.state == .recorded)

        let cafConflict = AudioTransport()
        #expect(throws: AudioMediaError.self) {
            try cafConflict.preparePlayback(url: renamedCAF, format: format)
        }
    }

    @Test
    func injectedASBDRejectsUnsignedIntegerWithoutClaimingNativeUnsignedDecode() throws {
        var signedPCM = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        try NativePCMFileValidator.validate(
            container: .wav,
            streamDescription: signedPCM,
            frameCount: format.frameCount,
            expected: format
        )

        signedPCM.mFormatFlags = kAudioFormatFlagIsPacked
        #expect(throws: AudioMediaError.self) {
            try NativePCMFileValidator.validate(
                container: .wav,
                streamDescription: signedPCM,
                frameCount: format.frameCount,
                expected: format
            )
        }
    }

    @Test
    func nativeReaderRejectsFractionalSampleRateMismatchBelowHalfAHertz() throws {
        let url = try syntheticWAV(in: uniqueDirectory())
        let fractionallyWrong = DWorkbench.AudioFormatInfo(
            container: .wav,
            sampleRate: 48_000.25,
            channelCount: 1,
            frameCount: 480,
            bitDepth: 16,
            floatingPoint: false
        )
        let subject = AudioTransport()
        #expect(throws: AudioMediaError.self) {
            try subject.preparePlayback(url: url, format: fractionallyWrong)
        }
        #expect(subject.state == .idle)
    }

    @Test
    func replayStartFailureWhilePlayingLeavesTransportPaused() throws {
        let root = try uniqueDirectory()
        let url = try syntheticWAV(in: root)
        let factory = FakeAudioFactory()
        let subject = AudioTransport(deviceFactory: factory)
        try subject.preparePlayback(url: url, format: format)
        try subject.play()
        #expect(subject.state == .playing)

        let playback = try #require(factory.playbacks.first)
        playback.startResult = false
        #expect(throws: AudioMediaError.self) { try subject.play() }
        #expect(playback.segments.count == 2)
        #expect(subject.state == .paused)
        #expect(subject.errorMessage == nil)
    }

    /// Observe the actual owned timer without adding a production API or using audio hardware.
    private func ownedProgressTimer(_ transport: AudioTransport) -> Timer? {
        for child in Mirror(reflecting: transport).children
            where child.label?.hasSuffix("progressTimer") == true {
            if let timer = child.value as? Timer { return timer }
            if let timer = Mirror(reflecting: child.value).children.first?.value as? Timer { return timer }
        }
        return nil
    }

    private func verifyReplayFailureReleasesProgress(throwing: Bool) throws {
        let url = try syntheticWAV(in: uniqueDirectory())
        let factory = FakeAudioFactory()
        let subject = AudioTransport(deviceFactory: factory)
        defer { subject.shutdown() }
        try subject.preparePlayback(url: url, format: format)
        try subject.play()
        let oldTimer = try #require(ownedProgressTimer(subject))
        #expect(oldTimer.isValid)
        let device = try #require(factory.playbacks.first)
        device.startResult = false
        device.throwOnPlay = throwing
        #expect(throws: AudioMediaError.self) { try subject.play() }
        #expect(subject.state == .paused)
        #expect(!oldTimer.isValid)
        #expect(ownedProgressTimer(subject) == nil)
    }

    @Test
    func replayReturningFalseReleasesOldProgressTimer() throws {
        try verifyReplayFailureReleasesProgress(throwing: false)
    }

    @Test
    func replayThrowingReleasesOldProgressTimer() throws {
        try verifyReplayFailureReleasesProgress(throwing: true)
    }

    @Test
    func successfulReplayOwnsOneNewTimerAndPauseReleasesIt() throws {
        let url = try syntheticWAV(in: uniqueDirectory())
        let factory = FakeAudioFactory()
        let subject = AudioTransport(deviceFactory: factory)
        defer { subject.shutdown() }
        try subject.preparePlayback(url: url, format: format)
        try subject.play()
        let first = try #require(ownedProgressTimer(subject))
        try subject.play()
        let second = try #require(ownedProgressTimer(subject))
        #expect(subject.state == .playing)
        #expect(second !== first)
        #expect(!first.isValid)
        #expect(second.isValid)
        subject.pause()
        #expect(subject.state == .paused)
        #expect(!second.isValid)
        #expect(ownedProgressTimer(subject) == nil)
    }

    @Test
    func cancelledAndShutdownPermissionRequestsCannotStartLateCapture() async throws {
        let root = try uniqueDirectory()

        let cancelledFactory = FakeAudioFactory()
        cancelledFactory.suspendPermission = true
        let cancelled = AudioTransport(recordingEnabled: true, deviceFactory: cancelledFactory)
        let cancelledTask = Task {
            try await cancelled.requestAndStartRecording(
                to: root.appendingPathComponent("cancelled.caf")
            )
        }
        try await waitForPermissionRequest(cancelled, factory: cancelledFactory)
        cancelledTask.cancel()
        cancelledFactory.resolvePermission(true)
        await #expect(throws: CancellationError.self) { try await cancelledTask.value }
        #expect(cancelled.state == .idle)
        #expect(cancelledFactory.recordings.isEmpty)

        let shutdownFactory = FakeAudioFactory()
        shutdownFactory.suspendPermission = true
        let shutdown = AudioTransport(recordingEnabled: true, deviceFactory: shutdownFactory)
        let shutdownTask = Task {
            try await shutdown.requestAndStartRecording(
                to: root.appendingPathComponent("shutdown.caf")
            )
        }
        try await waitForPermissionRequest(shutdown, factory: shutdownFactory)
        shutdown.shutdown()
        shutdownFactory.resolvePermission(false)
        try await shutdownTask.value
        #expect(shutdown.state == .idle)
        #expect(shutdownFactory.recordings.isEmpty)
    }

    @Test
    func destinationAppearingDuringPermissionWaitIsPreservedAndNotOpened() async throws {
        let root = try uniqueDirectory()
        let target = root.appendingPathComponent("appeared.caf")
        let factory = FakeAudioFactory()
        factory.suspendPermission = true
        let subject = AudioTransport(recordingEnabled: true, deviceFactory: factory)
        let task = Task { try await subject.requestAndStartRecording(to: target) }
        try await waitForPermissionRequest(subject, factory: factory)
        let existing = Data("reserved elsewhere".utf8)
        try existing.write(to: target, options: .withoutOverwriting)
        factory.resolvePermission(true)
        await #expect(throws: AudioMediaError.self) { try await task.value }
        #expect(factory.recordings.isEmpty)
        #expect(try Data(contentsOf: target) == existing)
        #expect(subject.state == .failed)
    }

    @Test
    func activeShutdownClosesBeforeSingleCallbackAndLateDeviceResultIsIgnored() async throws {
        let root = try uniqueDirectory()
        let factory = FakeAudioFactory()
        let subject = AudioTransport(recordingEnabled: true, deviceFactory: factory)
        let target = root.appendingPathComponent("active.caf")
        subject.recordingDidFinish = { _, _ in factory.log.entries.append("callback") }

        try await subject.requestAndStartRecording(to: target)
        let recording = try #require(factory.recordings.first)
        subject.shutdown()
        subject.shutdown()
        recording.finishFromDevice(error: "late")

        #expect(factory.log.entries.filter { $0 == "close:r0" }.count == 1)
        #expect(factory.log.entries.filter { $0 == "callback" }.count == 1)
        let closeIndex = try #require(factory.log.entries.firstIndex(of: "close:r0"))
        let callbackIndex = try #require(factory.log.entries.firstIndex(of: "callback"))
        #expect(closeIndex < callbackIndex)
        #expect(subject.recordedURL == target)
        #expect(subject.state == .recorded)
    }

    @Test
    func deviceFailurePreservesURLAndRejectedUIErrorDoesNotLoseStopOwnership() async throws {
        let root = try uniqueDirectory()
        let factory = FakeAudioFactory()
        let subject = AudioTransport(recordingEnabled: true, deviceFactory: factory)
        let target = root.appendingPathComponent("failure.caf")
        var reports: [(URL, String?)] = []
        subject.recordingDidFinish = { reports.append(($0, $1)) }

        try await subject.requestAndStartRecording(to: target)
        subject.present(AudioMediaError.invalidRange)
        #expect(subject.state == .recording)
        _ = try subject.finishRecording()
        #expect(factory.recordings[0].closed)
        #expect(try Data(contentsOf: target) == Data([0x43, 0x41, 0x46, 0x21]))

        let secondTarget = root.appendingPathComponent("device-error.caf")
        try await subject.requestAndStartRecording(to: secondTarget)
        factory.recordings[1].finishFromDevice(error: "device lost")
        #expect(subject.state == .failed)
        #expect(subject.recordedURL == secondTarget)
        #expect(subject.errorMessage == "device lost")
        #expect(reports.count == 2)
        #expect(try Data(contentsOf: secondTarget) == Data([0x43, 0x41, 0x46, 0x21]))
    }

    @Test
    func missingStopURLAndSynchronousCompletionCannotBecomeFalseSuccess() async throws {
        let root = try uniqueDirectory()
        let missingFactory = FakeAudioFactory()
        let missing = AudioTransport(recordingEnabled: true, deviceFactory: missingFactory)
        try await missing.requestAndStartRecording(
            to: root.appendingPathComponent("missing.caf")
        )
        missingFactory.recordings[0].returnedURL = nil
        #expect(throws: AudioMediaError.self) { try missing.finishRecording() }
        #expect(missing.state == .failed)

        let synchronousFactory = FakeAudioFactory()
        let synchronous = AudioTransport(recordingEnabled: true, deviceFactory: synchronousFactory)
        let target = root.appendingPathComponent("sync.caf")
        synchronousFactory.configureRecording = { recording in
            recording.synchronousResult = AudioRecordingResult(url: target, error: nil)
        }
        try await synchronous.requestAndStartRecording(to: target)
        #expect(synchronous.state == .recorded)
    }
    @Test func ownerValidationRunsBeforePermissionAndDeviceCreation() async throws {
        let root = try uniqueDirectory()
        let target = root.appendingPathComponent("owner.caf")
        let factory = FakeAudioFactory()
        let subject = AudioTransport(recordingEnabled: true, deviceFactory: factory)
        defer { subject.shutdown() }
        try await subject.requestAndStartRecording(to: target) { factory.log.entries.append("validate") }
        #expect(Array(factory.log.entries.prefix(4)) == ["validate", "permission", "validate", "prepare-recording"])
        #expect(subject.state == .recording)
    }

    @Test func failedOwnerValidationNeverRequestsPermissionOrCreatesAudio() async throws {
        let target = try uniqueDirectory().appendingPathComponent("reject.caf")
        let factory = FakeAudioFactory()
        let subject = AudioTransport(recordingEnabled: true, deviceFactory: factory)
        await #expect(throws: AudioMediaError.self) {
            try await subject.requestAndStartRecording(to: target) { throw AudioMediaError.io("owner rejected") }
        }
        #expect(factory.permissionRequests == 0)
        #expect(factory.recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(subject.state == .idle)
    }

    @Test(arguments: [1, 2])
    func shutdownDuringOwnerValidationCannotStartLateRecording(validationToSuspend: Int) async throws {
        let target = try uniqueDirectory().appendingPathComponent("late.caf")
        let factory = FakeAudioFactory()
        let subject = AudioTransport(recordingEnabled: true, deviceFactory: factory)
        var continuation: CheckedContinuation<Void, Never>?
        var validations = 0
        let task = Task {
            try await subject.requestAndStartRecording(to: target) {
                validations += 1
                if validations == validationToSuspend {
                    await withCheckedContinuation { continuation = $0 }
                }
            }
        }
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        let gate = try #require(continuation)
        subject.shutdown()
        gate.resume()
        try await task.value
        #expect(factory.permissionRequests == validationToSuspend - 1)
        #expect(factory.recordings.isEmpty)
        #expect(subject.state == .idle)
    }

    @Test func ownerRevalidationRejectsSymlinkAppearingDuringPermission() async throws {
        let root = try uniqueDirectory()
        let project = root.appendingPathComponent("owned.dproject")
        let store = try await ProjectStore.create(at: project, name: "owned")
        let reservation = try await store.reserveAudioCapture(name: "reserved")
        let target = try await store.audioCaptureURL(id: reservation.id)
        let outside = root.appendingPathComponent("protected.caf")
        let sentinel = Data("keep-original".utf8)
        try sentinel.write(to: outside, options: .withoutOverwriting)
        let factory = FakeAudioFactory()
        factory.suspendPermission = true
        let subject = AudioTransport(recordingEnabled: true, deviceFactory: factory)
        let task = Task {
            try await subject.requestAndStartRecording(to: target) {
                let checked = try await store.audioCaptureURL(id: reservation.id)
                #expect(checked == target)
            }
        }
        try await waitForPermissionRequest(subject, factory: factory)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        factory.resolvePermission(true)
        await #expect(throws: ProjectStoreError.self) { try await task.value }
        #expect(factory.recordings.isEmpty)
        #expect(try Data(contentsOf: outside) == sentinel)
        #expect(await store.snapshot().pendingAudioCaptures == [reservation])
        try await store.close()
    }

}
