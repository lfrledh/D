@preconcurrency import AVFoundation
import AudioToolbox
import Darwin
import Foundation
import Observation

public enum AudioTransportState: Sendable, Equatable {
    case idle, requestingPermission, recording, recorded, playing, paused, failed
}

struct AudioRecordingResult: Sendable, Equatable {
    let url: URL?
    let error: String?
}

@MainActor protocol AudioPlaybackDevice: AnyObject {
    var currentFrame: Int64 { get }
    func playSegment(
        startFrame: Int64,
        frameCount: Int64,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) throws -> Bool
    func pause() -> Int64
    func stop()
}

@MainActor protocol AudioRecordingDevice: AnyObject {
    var url: URL { get }
    var currentSeconds: Double { get }
    func start(
        completion: @escaping @MainActor @Sendable (AudioRecordingResult) -> Void
    ) throws -> Bool
    func stop(error: String?) -> AudioRecordingResult
}

@MainActor protocol AudioTransportDeviceFactory: AnyObject {
    func requestRecordPermission() async -> Bool
    func makePlayback(url: URL, expected: AudioFormatInfo) throws -> any AudioPlaybackDevice
    func makeRecording(url: URL) throws -> any AudioRecordingDevice
}

@MainActor @Observable
public final class AudioTransport: NSObject {
    public private(set) var state: AudioTransportState = .idle
    public private(set) var positionFrame: Int64 = 0
    public private(set) var recordingSeconds: Double = 0
    public private(set) var errorMessage: String?
    public private(set) var recordedURL: URL?
    public var recordingDidFinish: (@MainActor @Sendable (URL, String?) -> Void)?

    private enum ProgressMode {
        case playback(epoch: UInt64, lower: Int64, upper: Int64)
        case recording(epoch: UInt64)
    }

    private let recordingEnabled: Bool
    private let deviceFactory: any AudioTransportDeviceFactory
    private var playback: (any AudioPlaybackDevice)?
    private var recording: (any AudioRecordingDevice)?
    private var playbackFormat: AudioFormatInfo?
    private var playbackRange: AudioFrameRange?
    private var playbackEpoch: UInt64 = 0
    private var recordingEpoch: UInt64 = 0
    private var progressMode: ProgressMode?
    private var progressTimer: Timer?
    private var recordingResultReported = false

    public init(recordingEnabled: Bool = false) {
        self.recordingEnabled = recordingEnabled
        self.deviceFactory = AVFoundationAudioDeviceFactory()
        super.init()
    }

    init(recordingEnabled: Bool = false, deviceFactory: any AudioTransportDeviceFactory) {
        self.recordingEnabled = recordingEnabled
        self.deviceFactory = deviceFactory
        super.init()
    }

    public func preparePlayback(
        url: URL,
        format: AudioFormatInfo,
        range: AudioFrameRange? = nil
    ) throws {
        guard recording == nil, state != .requestingPermission else {
            throw AudioMediaError.unavailable("录音正在进行")
        }
        try validatePlayback(url: url, format: format, range: range)

        // Construct and validate the replacement before disturbing the current usable source.
        let candidate = try deviceFactory.makePlayback(url: url, expected: format)
        let candidateRange = range ?? AudioFrameRange(startFrame: 0, endFrame: format.frameCount)

        playbackEpoch &+= 1
        stopProgressTimer()
        playback?.stop()
        playback = candidate
        playbackFormat = format
        playbackRange = candidateRange
        positionFrame = candidateRange.startFrame
        errorMessage = nil
        state = .recorded
    }

    public func play() throws {
        guard recording == nil, state != .requestingPermission,
              let playback, let range = playbackRange else {
            throw AudioMediaError.unavailable("尚未准备音频")
        }
        if positionFrame >= range.endFrame {
            positionFrame = range.startFrame
        }
        let startFrame = positionFrame
        let frameCount = range.endFrame - startFrame
        guard frameCount > 0 else { throw AudioMediaError.invalidRange }

        stopProgressTimer()
        playbackEpoch &+= 1
        let epoch = playbackEpoch
        let playbackID = ObjectIdentifier(playback)
        let priorState = state
        state = .playing
        errorMessage = nil
        do {
            let started = try playback.playSegment(
                startFrame: startFrame,
                frameCount: frameCount
            ) { [weak self] error in
                guard let self, let current = self.playback,
                      self.playbackEpoch == epoch,
                      ObjectIdentifier(current) == playbackID else { return }
                self.finishPlayback(epoch: epoch, endFrame: range.endFrame, error: error)
            }
            guard started else {
                if playbackEpoch == epoch,
                   let current = self.playback,
                   ObjectIdentifier(current) == playbackID {
                    state = priorState == .playing || priorState == .failed ? .paused : priorState
                }
                throw AudioMediaError.unavailable("播放设备未能启动")
            }
            if playbackEpoch == epoch,
               let current = self.playback,
               ObjectIdentifier(current) == playbackID,
               state == .playing {
                startProgressTimer(.playback(
                    epoch: epoch,
                    lower: range.startFrame,
                    upper: range.endFrame
                ))
            }
        } catch {
            if playbackEpoch == epoch,
               let current = self.playback,
               ObjectIdentifier(current) == playbackID,
               state == .playing {
                state = priorState == .playing || priorState == .failed ? .paused : priorState
            }
            throw error
        }
    }

    public func pause() {
        guard state == .playing, let playback, let range = playbackRange else { return }
        playbackEpoch &+= 1
        positionFrame = bounded(playback.pause(), to: range)
        stopProgressTimer()
        state = .paused
    }

    public func seek(toFrame frame: Int64) throws {
        guard let playback, let range = playbackRange else {
            throw AudioMediaError.unavailable("尚未准备音频")
        }
        guard frame >= range.startFrame, frame < range.endFrame else {
            throw AudioMediaError.invalidRange
        }
        let resume = state == .playing
        if resume { _ = playback.pause() }
        playbackEpoch &+= 1
        stopProgressTimer()
        positionFrame = frame
        state = .paused
        if resume { try play() }
    }

    public func stopPlayback() {
        playbackEpoch &+= 1
        stopProgressTimer()
        playback?.stop()
        playback = nil
        playbackFormat = nil
        playbackRange = nil
        if recording == nil, state != .requestingPermission {
            state = recordedURL == nil ? .idle : .recorded
        }
    }

    public func requestAndStartRecording(to url: URL) async throws {
        guard recordingEnabled else {
            throw AudioMediaError.unavailable("录音功能尚未启用")
        }
        guard recording == nil, state != .requestingPermission, playback == nil else {
            throw AudioMediaError.unavailable("播放或录音正在进行")
        }
        try validateRecordingDestination(url)

        recordingEpoch &+= 1
        let epoch = recordingEpoch
        state = .requestingPermission
        errorMessage = nil

        let permitted: Bool
        do {
            permitted = await deviceFactory.requestRecordPermission()
            try Task.checkCancellation()
        } catch {
            if recordingEpoch == epoch, state == .requestingPermission {
                recordingEpoch &+= 1
                state = recordedURL == nil ? .idle : .recorded
                errorMessage = error.localizedDescription
            }
            throw error
        }

        guard recordingEpoch == epoch, state == .requestingPermission else { return }
        guard permitted else {
            let message = "没有麦克风使用许可"
            state = .failed
            errorMessage = message
            throw AudioMediaError.unavailable(message)
        }

        do {
            try validateRecordingDestination(url)
            let candidate = try deviceFactory.makeRecording(url: url)
            guard recordingEpoch == epoch, state == .requestingPermission else {
                _ = candidate.stop(error: "录音请求已取消")
                return
            }

            recording = candidate
            let recordingID = ObjectIdentifier(candidate)
            recordingResultReported = false
            recordedURL = nil
            recordingSeconds = 0
            state = .recording

            let started = try candidate.start { [weak self] result in
                guard let self, let current = self.recording,
                      self.recordingEpoch == epoch,
                      ObjectIdentifier(current) == recordingID else { return }
                self.completeRecording(current, epoch: epoch, result: result)
            }
            guard started else {
                let result = candidate.stop(error: "录音设备未能以 48 kHz 单声道 float32 PCM 启动")
                completeRecording(candidate, epoch: epoch, result: result)
                throw AudioMediaError.unavailable(result.error ?? "录音设备未能启动")
            }

            // A deterministic device is allowed to finish synchronously from start().
            if recordingEpoch == epoch,
               let current = recording,
               ObjectIdentifier(current) == recordingID,
               state == .recording {
                startProgressTimer(.recording(epoch: epoch))
            }
        } catch {
            if recordingEpoch == epoch, state == .requestingPermission {
                state = .failed
                errorMessage = error.localizedDescription
            } else if recordingEpoch == epoch, let active = recording {
                let result = active.stop(error: error.localizedDescription)
                completeRecording(active, epoch: epoch, result: result)
            }
            throw error
        }
    }

    public func finishRecording() throws -> URL? {
        if state == .requestingPermission {
            recordingEpoch &+= 1
            state = recordedURL == nil ? .idle : .recorded
            return recordedURL
        }
        guard let recording else { return recordedURL }
        let epoch = recordingEpoch
        let result = recording.stop(error: nil)
        completeRecording(recording, epoch: epoch, result: result)
        if let error = result.error ?? (result.url == nil ? "录音设备关闭时未返回保留文件" : nil) {
            throw AudioMediaError.io(error)
        }
        return result.url
    }

    public func shutdown() {
        playbackEpoch &+= 1
        stopProgressTimer()
        playback?.stop()
        playback = nil
        playbackFormat = nil
        playbackRange = nil

        if state == .requestingPermission {
            recordingEpoch &+= 1
            state = recordedURL == nil ? .idle : .recorded
            return
        }
        guard let recording else {
            if state != .failed { state = recordedURL == nil ? .idle : .recorded }
            return
        }
        let epoch = recordingEpoch
        let result = recording.stop(error: nil)
        completeRecording(recording, epoch: epoch, result: result)
        // completeRecording performs the user callback last; no old-operation state follows it.
    }

    /// Surfaces a rejected operation while preserving any active playback or recording ownership.
    public func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func finishPlayback(
        epoch: UInt64,
        endFrame: Int64,
        error: String?
    ) {
        guard playbackEpoch == epoch else { return }
        stopProgressTimer()
        positionFrame = endFrame
        if let error {
            errorMessage = error
            state = .failed
        } else if state == .playing {
            state = .paused
        }
    }

    private func completeRecording(
        _ completed: any AudioRecordingDevice,
        epoch: UInt64,
        result: AudioRecordingResult
    ) {
        guard recordingEpoch == epoch,
              let current = recording,
              ObjectIdentifier(current) == ObjectIdentifier(completed),
              !recordingResultReported else { return }
        recordingResultReported = true
        stopProgressTimer()
        recording = nil
        recordingSeconds = min(recordingSeconds, AudioLimits.maximumSeconds)
        recordedURL = result.url

        let finalError = result.error ?? (result.url == nil ? "录音设备关闭时未返回保留文件" : nil)
        errorMessage = finalError
        state = finalError == nil ? .recorded : .failed

        // Final state and ownership are settled before allowing adapter reentrancy.
        if let url = result.url {
            recordingDidFinish?(url, finalError)
        }
    }

    private func startProgressTimer(_ mode: ProgressMode) {
        stopProgressTimer()
        progressMode = mode
        progressTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 30.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollProgress()
            }
        }
    }

    private func pollProgress() {
        switch progressMode {
        case .playback(let epoch, let lower, let upper):
            guard playbackEpoch == epoch, state == .playing, let playback else { return }
            positionFrame = max(lower, min(playback.currentFrame, upper))
        case .recording(let epoch):
            guard recordingEpoch == epoch, state == .recording, let recording else { return }
            recordingSeconds = max(0, min(recording.currentSeconds, AudioLimits.maximumSeconds))
        case nil:
            break
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        progressMode = nil
    }

    private func bounded(_ frame: Int64, to range: AudioFrameRange) -> Int64 {
        max(range.startFrame, min(frame, range.endFrame))
    }

    private func validatePlayback(
        url: URL,
        format: AudioFormatInfo,
        range: AudioFrameRange?
    ) throws {
        guard url.isFileURL, !url.hasDirectoryPath,
              let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0, size <= AudioLimits.maximumBytes else {
            throw AudioMediaError.invalidMedia("需要一个不经符号链接的普通文件")
        }
        guard (8_000...96_000).contains(format.sampleRate),
              format.sampleRate.isFinite,
              (1...2).contains(format.channelCount),
              format.frameCount > 0,
              ((format.floatingPoint && format.bitDepth == 32)
                || (!format.floatingPoint && [16, 24, 32].contains(format.bitDepth))),
              Double(format.frameCount) / format.sampleRate <= AudioLimits.maximumSeconds else {
            throw AudioMediaError.unsupportedFormat
        }
        if let range,
           (range.startFrame < 0
            || range.startFrame >= range.endFrame
            || range.endFrame > format.frameCount) {
            throw AudioMediaError.invalidRange
        }
    }

    private func validateRecordingDestination(_ url: URL) throws {
        guard url.isFileURL, !url.hasDirectoryPath, url.pathExtension.lowercased() == "caf" else {
            throw AudioMediaError.io("录音目标必须是尚不存在的本地 CAF 文件")
        }
        var leafInfo = stat()
        guard lstat(url.path, &leafInfo) != 0, errno == ENOENT else {
            throw AudioMediaError.io("录音目标已存在或是符号链接")
        }

        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard let values = try? parent.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            throw AudioMediaError.io("录音目标目录不可用")
        }
        var cursor = parent
        while true {
            var info = stat()
            let status = lstat(cursor.path, &info)
            let savedErrno = errno
            guard status == 0 else {
                throw AudioMediaError.io("录音路径检查失败：\(cursor.path)，errno \(savedErrno)")
            }
            guard (info.st_mode & S_IFMT) != S_IFLNK else {
                throw AudioMediaError.io("录音目标目录不可经符号链接：\(cursor.path)")
            }
            let next = cursor.deletingLastPathComponent()
            if next.path == cursor.path { break }
            cursor = next
        }
    }
}

struct NativeAudioFileDescription {
    let container: AudioContainer
    let streamDescription: AudioStreamBasicDescription

    init(url: URL) throws {
        var fileID: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
        guard openStatus == noErr, let fileID else {
            throw AudioMediaError.invalidMedia("系统无法读取音频文件类型（\(openStatus)）")
        }
        defer { AudioFileClose(fileID) }

        var fileType: AudioFileTypeID = 0
        var fileTypeSize = UInt32(MemoryLayout.size(ofValue: fileType))
        let typeStatus = AudioFileGetProperty(
            fileID,
            kAudioFilePropertyFileFormat,
            &fileTypeSize,
            &fileType
        )
        guard typeStatus == noErr else {
            throw AudioMediaError.invalidMedia("系统无法读取音频容器（\(typeStatus)）")
        }
        switch fileType {
        case kAudioFileWAVEType:
            container = .wav
        case kAudioFileCAFType:
            container = .caf
        default:
            throw AudioMediaError.unsupportedFormat
        }

        var stream = AudioStreamBasicDescription()
        var streamSize = UInt32(MemoryLayout.size(ofValue: stream))
        let streamStatus = AudioFileGetProperty(
            fileID,
            kAudioFilePropertyDataFormat,
            &streamSize,
            &stream
        )
        guard streamStatus == noErr else {
            throw AudioMediaError.invalidMedia("系统无法读取 PCM 流格式（\(streamStatus)）")
        }
        streamDescription = stream
    }
}

enum NativePCMFileValidator {
    static func validate(
        container: AudioContainer,
        streamDescription actual: AudioStreamBasicDescription,
        frameCount: Int64,
        expected: AudioFormatInfo
    ) throws {
        let isFloat = actual.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = actual.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        guard container == expected.container,
              actual.mFormatID == kAudioFormatLinearPCM,
              actual.mSampleRate == expected.sampleRate,
              Int(actual.mChannelsPerFrame) == expected.channelCount,
              frameCount == expected.frameCount,
              Int(actual.mBitsPerChannel) == expected.bitDepth,
              isFloat == expected.floatingPoint,
              expected.floatingPoint || isSignedInteger else {
            throw AudioMediaError.invalidMedia("文件内容与已检查的 PCM 格式不一致")
        }
    }
}

@MainActor
private final class AVFoundationAudioDeviceFactory: AudioTransportDeviceFactory {
    func requestRecordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func makePlayback(
        url: URL,
        expected: AudioFormatInfo
    ) throws -> any AudioPlaybackDevice {
        try AVFoundationPlaybackDevice(url: url, expected: expected)
    }

    func makeRecording(url: URL) throws -> any AudioRecordingDevice {
        try AVFoundationRecordingDevice(url: url)
    }
}

@MainActor
private final class AVFoundationPlaybackDevice: AudioPlaybackDevice {
    private let file: AVAudioFile
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var operationID: UUID?
    private var segmentStart: Int64 = 0
    private var segmentEnd: Int64 = 0
    private var pausedFrame: Int64 = 0

    init(url: URL, expected: AudioFormatInfo) throws {
        let native = try NativeAudioFileDescription(url: url)
        let file = try AVAudioFile(forReading: url)
        try NativePCMFileValidator.validate(
            container: native.container,
            streamDescription: native.streamDescription,
            frameCount: file.length,
            expected: expected
        )
        self.file = file
    }

    var currentFrame: Int64 {
        guard let node, node.isPlaying,
              let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime) else {
            return pausedFrame
        }
        let advanced = max(Int64(0), Int64(playerTime.sampleTime))
        return min(segmentEnd, segmentStart + advanced)
    }

    func playSegment(
        startFrame: Int64,
        frameCount: Int64,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) throws -> Bool {
        stopOperation()
        let engine: AVAudioEngine
        let node: AVAudioPlayerNode
        if let existingEngine = self.engine, let existingNode = self.node {
            engine = existingEngine
            node = existingNode
        } else {
            let newEngine = AVAudioEngine()
            let newNode = AVAudioPlayerNode()
            newEngine.attach(newNode)
            newEngine.connect(
                newNode,
                to: newEngine.mainMixerNode,
                format: file.processingFormat
            )
            self.engine = newEngine
            self.node = newNode
            engine = newEngine
            node = newNode
        }
        if !engine.isRunning { try engine.start() }

        let operationID = UUID()
        self.operationID = operationID
        segmentStart = startFrame
        segmentEnd = startFrame + frameCount
        pausedFrame = startFrame
        let callback = completion
        node.scheduleSegment(
            file,
            startingFrame: AVAudioFramePosition(startFrame),
            frameCount: AVAudioFrameCount(frameCount),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == operationID else { return }
                self.operationID = nil
                self.pausedFrame = self.segmentEnd
                callback(nil)
            }
        }
        node.play()
        guard node.isPlaying else {
            stopOperation()
            return false
        }
        return true
    }

    func pause() -> Int64 {
        let frame = currentFrame
        operationID = nil
        node?.pause()
        pausedFrame = frame
        return frame
    }

    func stop() {
        stopOperation()
        engine?.stop()
        engine = nil
        node = nil
    }

    private func stopOperation() {
        operationID = nil
        node?.stop()
    }
}

@MainActor
private final class AVFoundationRecordingDevice: NSObject, AudioRecordingDevice, AVAudioRecorderDelegate {
    let url: URL
    private var recorder: AVAudioRecorder?
    private var recorderID: ObjectIdentifier?
    private var operationID: UUID?
    private var completion: (@MainActor @Sendable (AudioRecordingResult) -> Void)?

    init(url: URL) throws {
        self.url = url
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw AudioMediaError.io("无法独占创建录音目标：\(String(cString: strerror(errno)))")
        }
        close(descriptor)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.format.sampleRate == 48_000,
              recorder.format.channelCount == 1,
              recorder.format.commonFormat == .pcmFormatFloat32 else {
            recorder.stop()
            throw AudioMediaError.unavailable(
                "录音设备不能提供要求的 48 kHz 单声道 float32 PCM"
            )
        }
        self.recorder = recorder
        self.recorderID = ObjectIdentifier(recorder)
        super.init()
        recorder.delegate = self
        guard recorder.prepareToRecord() else {
            self.recorder = nil
            self.recorderID = nil
            recorder.stop()
            throw AudioMediaError.unavailable("录音设备未能准备")
        }
    }

    var currentSeconds: Double { recorder?.currentTime ?? 0 }

    func start(
        completion: @escaping @MainActor @Sendable (AudioRecordingResult) -> Void
    ) throws -> Bool {
        guard let recorder else { return false }
        let operationID = UUID()
        self.operationID = operationID
        self.completion = completion
        let started = recorder.record(forDuration: AudioLimits.maximumSeconds)
        if !started {
            self.operationID = nil
            self.completion = nil
        }
        return started
    }

    func stop(error: String?) -> AudioRecordingResult {
        guard let recorder else {
            return AudioRecordingResult(
                url: url,
                error: error ?? "录音设备已关闭，无法确认刷新结果"
            )
        }
        operationID = nil
        completion = nil
        recorder.stop()
        self.recorder = nil
        recorderID = nil
        return AudioRecordingResult(url: url, error: error)
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        let identity = ObjectIdentifier(recorder)
        let message = flag ? nil : "录音设备提前停止"
        Task { @MainActor [weak self] in
            self?.finishFromDevice(recorderID: identity, error: message)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: Error?
    ) {
        let identity = ObjectIdentifier(recorder)
        let message = error?.localizedDescription ?? "录音设备编码失败"
        Task { @MainActor [weak self] in
            self?.finishFromDevice(recorderID: identity, error: message)
        }
    }

    private func finishFromDevice(recorderID: ObjectIdentifier, error: String?) {
        guard self.recorderID == recorderID,
              operationID != nil,
              let recorder,
              let callback = completion else { return }
        operationID = nil
        completion = nil
        recorder.stop()
        self.recorder = nil
        self.recorderID = nil
        callback(AudioRecordingResult(url: url, error: error))
    }
}
