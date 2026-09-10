import AudioToolbox
import Foundation

private let captureSampleRate: Double = 48_000
private let captureBytesPerFrame: UInt32 = 4
private let captureMaximumFrames = Int64(captureSampleRate * AudioLimits.maximumSeconds)

/// AudioQueue invokes this object on its private callback thread. The lock owns all packet,
/// terminal, and re-enqueue decisions; the main-actor device performs the actual shutdown.
private final class AudioQueueCaptureContext: @unchecked Sendable {
    private let lock = NSLock()
    private let audioFile: AudioFileID
    private var accepting = true
    private var nextPacket: Int64 = 0
    private var firstError: String?
    private var terminalReported = false
    private var terminal: (@Sendable (String?) -> Void)?

    init(audioFile: AudioFileID) { self.audioFile = audioFile }

    var recordedFrames: Int64 { lock.withLock { nextPacket } }

    func setTerminal(_ terminal: @escaping @Sendable (String?) -> Void) {
        lock.withLock { self.terminal = terminal }
    }

    func clearTerminalAndStopAccepting() -> String? {
        lock.withLock {
            accepting = false
            terminal = nil
            return firstError
        }
    }

    func consume(queue: AudioQueueRef, buffer: AudioQueueBufferRef, packetCount: UInt32) {
        var report: (@Sendable (String?) -> Void)?
        var reportError: String?
        lock.lock()
        if accepting {
            let available = Int64(buffer.pointee.mAudioDataByteSize / captureBytesPerFrame)
            let supplied = packetCount == 0 ? available : min(available, Int64(packetCount))
            let frames = max(0, min(supplied, captureMaximumFrames - nextPacket))
            if frames > 0, let data = buffer.pointee.mAudioData {
                var packets = UInt32(frames)
                let status = AudioFileWritePackets(audioFile, false,
                                                   UInt32(frames) * captureBytesPerFrame,
                                                   nil, nextPacket, &packets, data)
                if status == noErr, packets == UInt32(frames) {
                    nextPacket += frames
                } else {
                    firstError = "录音写入失败（\(status)）"
                    accepting = false
                }
            }
            if accepting, nextPacket < captureMaximumFrames {
                let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
                if status != noErr {
                    firstError = "录音缓冲区回收失败（\(status)）"
                    accepting = false
                }
            } else if nextPacket >= captureMaximumFrames {
                accepting = false
            }
            if !accepting, !terminalReported {
                terminalReported = true
                report = terminal
                reportError = firstError
            }
        }
        lock.unlock()
        report?(reportError)
    }
}

private let captureInputCallback: AudioQueueInputCallback = {
    userData, queue, buffer, _, packetCount, _ in
    guard let userData else { return }
    let context = Unmanaged<AudioQueueCaptureContext>.fromOpaque(userData).takeUnretainedValue()
    context.consume(queue: queue, buffer: buffer, packetCount: packetCount)
}

@MainActor
final class AudioQueueRecordingDevice: AudioRecordingDevice {
    let url: URL
    private let capture: AudioCaptureFile
    private let context: AudioQueueCaptureContext
    private var queue: AudioQueueRef?
    private var audioFile: AudioFileID?
    private var completion: (@MainActor @Sendable (AudioRecordingResult) -> Void)?
    private var settledResult: AudioRecordingResult?

    init(capture: AudioCaptureFile) throws {
        self.capture = capture
        self.url = capture.url
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
        let file = try capture.initializeAudioFile(format: &format)
        self.audioFile = file
        self.context = AudioQueueCaptureContext(audioFile: file)
        var candidate: AudioQueueRef?
        let status = AudioQueueNewInput(&format, captureInputCallback,
                                        Unmanaged.passUnretained(context).toOpaque(),
                                        nil, nil, 0, &candidate)
        guard status == noErr, let candidate else {
            AudioFileClose(file)
            self.audioFile = nil
            throw AudioMediaError.unavailable("无法创建 48 kHz 单声道输入队列（\(status)）")
        }
        self.queue = candidate
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
            AudioQueueDispose(candidate, true)
            self.queue = nil
            AudioFileClose(file)
            self.audioFile = nil
            _ = capture.synchronize()
            throw error
        }
    }

    var currentSeconds: Double { Double(context.recordedFrames) / captureSampleRate }

    func start(completion: @escaping @MainActor @Sendable (AudioRecordingResult) -> Void) throws -> Bool {
        guard let queue, settledResult == nil, self.completion == nil else { return false }
        self.completion = completion
        context.setTerminal { [weak self] error in
            Task { @MainActor [weak self] in self?.finishFromDevice(error: error) }
        }
        let status = AudioQueueStart(queue, nil)
        guard status == noErr else {
            self.completion = nil
            _ = context.clearTerminalAndStopAccepting()
            throw AudioMediaError.unavailable("录音设备未能启动（\(status)）")
        }
        return true
    }

    func stop(error requestedError: String?) -> AudioRecordingResult {
        if let settledResult { return settledResult }
        completion = nil
        var failures: [String] = []
        if let requestedError { failures.append(requestedError) }
        if let callbackError = context.clearTerminalAndStopAccepting() { failures.append(callbackError) }
        if let queue {
            let stopStatus = AudioQueueStop(queue, true)
            if stopStatus != noErr { failures.append("录音停止失败（\(stopStatus)）") }
            let disposeStatus = AudioQueueDispose(queue, true)
            if disposeStatus != noErr { failures.append("录音资源释放失败（\(disposeStatus)）") }
            self.queue = nil
        }
        if let audioFile {
            let closeStatus = AudioFileClose(audioFile)
            if closeStatus != noErr { failures.append("CAF 刷新失败（\(closeStatus)）") }
            self.audioFile = nil
        }
        if let synchronizationError = capture.synchronize() { failures.append(synchronizationError) }
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
}
