import AudioToolbox
import Foundation

private let captureSampleRate: Double = 48_000
private let captureBytesPerFrame: UInt32 = 4
private let captureMaximumFrames = Int64(captureSampleRate * AudioLimits.maximumSeconds)

struct AudioQueueLifecycleOperations: @unchecked Sendable {
    let stop: (AudioQueueRef, Bool) -> OSStatus
    let dispose: (AudioQueueRef, Bool) -> OSStatus
    let closeFile: (AudioFileID) -> OSStatus

    static let live = AudioQueueLifecycleOperations(
        stop: { AudioQueueStop($0, $1) },
        dispose: { AudioQueueDispose($0, $1) },
        closeFile: { AudioFileClose($0) }
    )
}

final class AudioRecordingAdmissionGate: @unchecked Sendable {
    static let shared = AudioRecordingAdmissionGate()

    private enum State { case available, active(UUID), terminationUnknown(UUID) }
    private let lock = NSLock()
    private var state: State = .available

    func acquire() throws -> UUID {
        try lock.withLock {
            switch state {
            case .available:
                let token = UUID()
                state = .active(token)
                return token
            case .active:
                throw AudioMediaError.unavailable("另一原生录音仍持有进程级输入所有权")
            case .terminationUnknown:
                throw AudioMediaError.unavailable(
                    "先前录音回调是否终止仍未知；已保留录音文件，请重启应用后再录音"
                )
            }
        }
    }

    func markTerminationUnknown(_ token: UUID) {
        lock.withLock {
            if case .active(let active) = state, active == token {
                state = .terminationUnknown(token)
            }
        }
    }

    func releaseAfterKnownTermination(_ token: UUID) {
        lock.withLock {
            switch state {
            case .active(let active) where active == token:
                state = .available
            case .terminationUnknown(let retained) where retained == token:
                state = .available
            default: break
            }
        }
    }
}

/// AudioQueue invokes this object on its private callback thread. The lock owns all packet,
/// terminal, and re-enqueue decisions; the main-actor device performs the actual shutdown.
private final class AudioQueueCaptureContext: @unchecked Sendable {
    private let lock = NSLock()
    private let capture: AudioCaptureFile
    private let audioFile: AudioFileID
    private var acceptsWrites = true
    private var reenqueues = true
    private var nextPacket: Int64 = 0
    private var firstError: String?
    private var terminalReported = false
    private var terminal: (@Sendable (String?) -> Void)?

    init(capture: AudioCaptureFile, audioFile: AudioFileID) {
        self.capture = capture
        self.audioFile = audioFile
    }

    var recordedFrames: Int64 { lock.withLock { nextPacket } }

    func setTerminal(_ terminal: @escaping @Sendable (String?) -> Void) {
        lock.withLock { self.terminal = terminal }
    }

    /// Synchronous AudioQueueStop can deliver filled buffers before returning. Stop future
    /// enqueue/notification work first, while deliberately leaving those writes enabled.
    func beginDrain() {
        lock.withLock {
            reenqueues = false
            terminal = nil
        }
    }

    func callbacksDidTerminate() -> String? {
        lock.withLock {
            acceptsWrites = false
            reenqueues = false
            terminal = nil
            return firstError
        }
    }

    func consume(queue: AudioQueueRef, buffer: AudioQueueBufferRef, packetCount: UInt32) {
        var report: (@Sendable (String?) -> Void)?
        var reportError: String?
        lock.lock()
        if acceptsWrites {
            let available = Int64(buffer.pointee.mAudioDataByteSize / captureBytesPerFrame)
            let supplied = packetCount == 0 ? available : min(available, Int64(packetCount))
            let frames = max(0, min(supplied, captureMaximumFrames - nextPacket))
            if frames > 0 {
                let data = buffer.pointee.mAudioData
                var packets = UInt32(frames)
                let status = AudioFileWritePackets(audioFile, false,
                                                   UInt32(frames) * captureBytesPerFrame,
                                                   nil, nextPacket, &packets, data)
                if status == noErr, packets == UInt32(frames) {
                    nextPacket += frames
                } else {
                    firstError = "录音写入失败（\(status)）"
                    acceptsWrites = false
                }
            }
            if acceptsWrites, reenqueues, nextPacket < captureMaximumFrames {
                let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
                if status != noErr {
                    firstError = "录音缓冲区回收失败（\(status)）"
                    acceptsWrites = false
                }
            } else if nextPacket >= captureMaximumFrames {
                acceptsWrites = false
            }
            if !acceptsWrites, !terminalReported {
                terminalReported = true
                report = terminal
                reportError = firstError
            }
        }
        lock.unlock()
        report?(reportError)
    }

    func consumeStopBufferForTesting(_ samples: [Float]) -> OSStatus {
        lock.withLock {
            guard acceptsWrites, nextPacket + Int64(samples.count) <= captureMaximumFrames else {
                return kAudioFileUnspecifiedError
            }
            var copy = samples
            var packets = UInt32(copy.count)
            let status = copy.withUnsafeMutableBytes {
                AudioFileWritePackets(audioFile, false, UInt32($0.count), nil,
                                      nextPacket, &packets, $0.baseAddress!)
            }
            if status == noErr, packets == UInt32(copy.count) {
                nextPacket += Int64(copy.count)
            } else if firstError == nil {
                firstError = "录音写入失败（\(status)）"
            }
            return status
        }
    }
}

private let captureInputCallback: AudioQueueInputCallback = {
    userData, queue, buffer, _, packetCount, _ in
    guard let userData else { return }
    let context = Unmanaged<AudioQueueCaptureContext>.fromOpaque(userData).takeUnretainedValue()
    context.consume(queue: queue, buffer: buffer, packetCount: packetCount)
}

/// Owns the queue, AudioFileID, retained callback context, and capture as one release unit.
/// A failed dispose keeps all four alive; deinit retries once, then the retained callback
/// context safely quarantines that single failed native operation if disposal still fails.
private final class AudioQueueOwnedResources: @unchecked Sendable {
    let context: AudioQueueCaptureContext
    private let capture: AudioCaptureFile
    private let lifecycle: AudioQueueLifecycleOperations
    private let lock = NSLock()
    private var queue: AudioQueueRef?
    private var audioFile: AudioFileID?
    private var callbackOwner: UnsafeMutableRawPointer?
    private let admissionGate: AudioRecordingAdmissionGate
    private let admissionToken: UUID

    init(capture: AudioCaptureFile, context: AudioQueueCaptureContext,
         queue: AudioQueueRef, audioFile: AudioFileID,
         callbackOwner: UnsafeMutableRawPointer,
         lifecycle: AudioQueueLifecycleOperations,
         admissionGate: AudioRecordingAdmissionGate,
         admissionToken: UUID) {
        self.capture = capture
        self.context = context
        self.queue = queue
        self.audioFile = audioFile
        self.callbackOwner = callbackOwner
        self.lifecycle = lifecycle
        self.admissionGate = admissionGate
        self.admissionToken = admissionToken
    }

    var activeQueue: AudioQueueRef? { lock.withLock { queue } }

    func shutdown() -> [String] {
        lock.lock()
        var failures: [String] = []
        context.beginDrain()
        if let queue {
            let stopStatus = lifecycle.stop(queue, true)
            if stopStatus != noErr { failures.append("录音停止失败（\(stopStatus)）") }
            if let callbackError = context.callbacksDidTerminate() { failures.append(callbackError) }
            let disposeStatus = lifecycle.dispose(queue, true)
            if disposeStatus == noErr {
                self.queue = nil
                closeFileAndReleaseOwner(failures: &failures)
                admissionGate.releaseAfterKnownTermination(admissionToken)
            } else {
                admissionGate.markTerminationUnknown(admissionToken)
                failures.append("录音资源释放失败（\(disposeStatus)）；回调与文件所有权已保留")
            }
        } else {
            _ = context.callbacksDidTerminate()
            closeFileAndReleaseOwner(failures: &failures)
            admissionGate.releaseAfterKnownTermination(admissionToken)
        }
        if let synchronizationError = capture.synchronize() { failures.append(synchronizationError) }
        lock.unlock()
        return failures
    }

    private func closeFileAndReleaseOwner(failures: inout [String]) {
        if let audioFile {
            let closeStatus = lifecycle.closeFile(audioFile)
            if closeStatus != noErr { failures.append("CAF 刷新失败（\(closeStatus)）") }
            self.audioFile = nil
        }
        if let callbackOwner {
            Unmanaged<AudioQueueCaptureContext>.fromOpaque(callbackOwner).release()
            self.callbackOwner = nil
        }
    }

    deinit { _ = shutdown() }
}

@MainActor
final class AudioQueueRecordingDevice: AudioRecordingDevice {
    let url: URL
    private let capture: AudioCaptureFile
    private let context: AudioQueueCaptureContext
    private let resources: AudioQueueOwnedResources
    private var completion: (@MainActor @Sendable (AudioRecordingResult) -> Void)?
    private var settledResult: AudioRecordingResult?

    init(capture: AudioCaptureFile,
         lifecycle: AudioQueueLifecycleOperations = .live,
         admissionGate: AudioRecordingAdmissionGate = .shared) throws {
        self.capture = capture
        self.url = capture.url
        let admissionToken = try admissionGate.acquire()
        var format = AudioStreamBasicDescription(
            mSampleRate: captureSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: captureBytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: captureBytesPerFrame,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let file: AudioFileID
        do { file = try capture.initializeAudioFile(format: &format) }
        catch {
            admissionGate.releaseAfterKnownTermination(admissionToken)
            throw error
        }
        let context = AudioQueueCaptureContext(capture: capture, audioFile: file)
        let callbackOwner = Unmanaged.passRetained(context).toOpaque()
        var candidate: AudioQueueRef?
        let status = AudioQueueNewInput(&format, captureInputCallback,
                                        callbackOwner,
                                        nil, nil, 0, &candidate)
        if status != noErr, let candidate {
            self.context = context
            self.resources = AudioQueueOwnedResources(
                capture: capture, context: context, queue: candidate, audioFile: file,
                callbackOwner: callbackOwner, lifecycle: lifecycle,
                admissionGate: admissionGate, admissionToken: admissionToken
            )
            let failures = resources.shutdown()
            throw AudioMediaError.unavailable(
                "无法创建 48 kHz 单声道输入队列（\(status)）"
                    + (failures.isEmpty ? "" : "；\(failures.joined(separator: "；"))")
            )
        }
        guard status == noErr, let candidate else {
            _ = lifecycle.closeFile(file)
            Unmanaged<AudioQueueCaptureContext>.fromOpaque(callbackOwner).release()
            admissionGate.releaseAfterKnownTermination(admissionToken)
            throw AudioMediaError.unavailable("无法创建 48 kHz 单声道输入队列（\(status)）")
        }
        self.context = context
        self.resources = AudioQueueOwnedResources(
            capture: capture, context: context, queue: candidate, audioFile: file,
            callbackOwner: callbackOwner, lifecycle: lifecycle,
            admissionGate: admissionGate, admissionToken: admissionToken
        )
        do {
            var actual = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let formatStatus = AudioQueueGetProperty(candidate,
                                                     kAudioQueueProperty_StreamDescription,
                                                     &actual, &size)
            guard formatStatus == noErr, actual.mSampleRate == captureSampleRate,
                  actual.mFormatID == kAudioFormatLinearPCM,
                  actual.mChannelsPerFrame == 1, actual.mBitsPerChannel == 32,
                  actual.mBytesPerFrame == captureBytesPerFrame,
                  actual.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw AudioMediaError.unavailable("输入队列不能提供要求的 48 kHz 单声道 float32 PCM")
            }
            for _ in 0..<3 {
                var buffer: AudioQueueBufferRef?
                let allocation = AudioQueueAllocateBuffer(candidate, 32 * 1_024, &buffer)
                guard allocation == noErr, let buffer else {
                    throw AudioMediaError.unavailable("无法分配录音缓冲区（\(allocation)）")
                }
                let enqueue = AudioQueueEnqueueBuffer(candidate, buffer, 0, nil)
                guard enqueue == noErr else {
                    throw AudioMediaError.unavailable("无法准备录音缓冲区（\(enqueue)）")
                }
            }
        } catch {
            let failures = resources.shutdown()
            if !failures.isEmpty {
                throw AudioMediaError.unavailable(
                    "\(error.localizedDescription)；\(failures.joined(separator: "；"))"
                )
            }
            throw error
        }
    }

    /// CPU-only lifecycle fixture: the injected operations must not dereference `queue`.
    init(testing capture: AudioCaptureFile, queue: AudioQueueRef,
         lifecycle: AudioQueueLifecycleOperations,
         admissionGate: AudioRecordingAdmissionGate = AudioRecordingAdmissionGate()) throws {
        self.capture = capture
        self.url = capture.url
        let admissionToken = try admissionGate.acquire()
        var format = AudioStreamBasicDescription(
            mSampleRate: captureSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: captureBytesPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: captureBytesPerFrame, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0
        )
        let file: AudioFileID
        do { file = try capture.initializeAudioFile(format: &format) }
        catch {
            admissionGate.releaseAfterKnownTermination(admissionToken)
            throw error
        }
        let context = AudioQueueCaptureContext(capture: capture, audioFile: file)
        let callbackOwner = Unmanaged.passRetained(context).toOpaque()
        self.context = context
        self.resources = AudioQueueOwnedResources(
            capture: capture, context: context, queue: queue, audioFile: file,
            callbackOwner: callbackOwner, lifecycle: lifecycle,
            admissionGate: admissionGate, admissionToken: admissionToken
        )
    }

    var currentSeconds: Double { Double(context.recordedFrames) / captureSampleRate }

    func start(completion: @escaping @MainActor @Sendable (AudioRecordingResult) -> Void) throws -> Bool {
        guard let queue = resources.activeQueue,
              settledResult == nil, self.completion == nil else { return false }
        self.completion = completion
        context.setTerminal { [weak self] error in
            Task { @MainActor [weak self] in self?.finishFromDevice(error: error) }
        }
        let status = AudioQueueStart(queue, nil)
        guard status == noErr else {
            self.completion = nil
            context.beginDrain()
            throw AudioMediaError.unavailable("录音设备未能启动（\(status)）")
        }
        return true
    }

    func stop(error requestedError: String?) -> AudioRecordingResult {
        if let settledResult { return settledResult }
        completion = nil
        var failures: [String] = []
        if let requestedError { failures.append(requestedError) }
        failures.append(contentsOf: resources.shutdown())
        let result = AudioRecordingResult(url: url,
                                          error: failures.isEmpty ? nil : failures.joined(separator: "；"))
        settledResult = result
        return result
    }

    private func finishFromDevice(error: String?) {
        guard let callback = completion else { return }
        let result = stop(error: error)
        callback(result)
    }

    func deliverStopBufferForTesting(_ samples: [Float]) -> OSStatus {
        context.consumeStopBufferForTesting(samples)
    }

}
