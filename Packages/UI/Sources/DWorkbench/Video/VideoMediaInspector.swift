@preconcurrency import AVFoundation
import CryptoKit
import DInference
import Darwin
import Foundation
import VideoToolbox

public enum VideoMediaInspector {
    public static func inspect(at url: URL, expected: VideoRequest,
                               timeoutSeconds: Double = 60) async throws -> VideoAssetMetadata {
        try VideoExecutionCapability.wan21.validate(expected)
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw VideoInspectionError.invalid("检查期限必须是正有限秒数")
        }
        let maximumBytes = try readBudget(for: expected)
        let controller = VideoInspectionCancellation(
            deadline: ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        )

        return try await withTaskCancellationHandler {
            let deadline = Task<Void, Never> {
                do { try await Task.sleep(for: .seconds(timeoutSeconds)) }
                catch { return }
                controller.stop(.timedOut)
            }
            do {
                let metadata = try await inspectFile(at: url, expected: expected,
                                                     maximumBytes: maximumBytes,
                                                     controller: controller)
                try controller.finishSuccessfully()
                deadline.cancel()
                _ = await deadline.result
                return metadata
            } catch {
                deadline.cancel()
                _ = await deadline.result
                let terminalError = controller.terminalError
                controller.finishAfterFailure()
                if let terminalError { throw terminalError }
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            controller.stop(.cancelled)
        }
    }

    public static func contentSHA256(at url: URL, maximumBytes: UInt64) throws -> String {
        let opened = try VideoSafeFile.open(url, maximumBytes: maximumBytes)
        defer { Darwin.close(opened.descriptor) }
        let digest = try VideoSafeFile.sha256(descriptor: opened.descriptor,
                                              byteCount: opened.identity.size,
                                              checkpoint: .contentHashChunk,
                                              hook: VideoInspectionTestHooks.checkpoint)
        try VideoSafeFile.verifyUnchanged(url, descriptor: opened.descriptor,
                                          initialIdentity: opened.identity,
                                          maximumBytes: maximumBytes)
        return digest
    }

    private static func inspectFile(at url: URL, expected: VideoRequest, maximumBytes: UInt64,
                                    controller: VideoInspectionCancellation) async throws -> VideoAssetMetadata {
        let opened = try VideoSafeFile.open(url, maximumBytes: maximumBytes)
        defer { Darwin.close(opened.descriptor) }
        VideoInspectionTestHooks.reach(.descriptorOpened)
        try VideoSafeFile.validateMP4(descriptor: opened.descriptor, byteCount: opened.identity.size)
        let initialHash = try VideoSafeFile.sha256(descriptor: opened.descriptor,
                                                   byteCount: opened.identity.size,
                                                   controller: controller,
                                                   checkpoint: .initialHashChunk,
                                                   hook: VideoInspectionTestHooks.checkpoint)
        try controller.check()

        let loader = VideoDescriptorResourceLoader(
            descriptor: opened.descriptor, byteCount: opened.identity.size,
            checkpoint: VideoInspectionTestHooks.checkpoint
        )
        let assetURL = URL(string: "dverified-video://verified/asset.mp4")!
        let asset = AVURLAsset(url: assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        controller.install(loader: loader)
        controller.install(asset: asset)
        defer {
            loader.requestStop()
            asset.cancelLoading()
            asset.resourceLoader.setDelegate(nil, queue: nil)
            loader.stopAndDrain()
        }
        try controller.check()

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard videoTracks.count == 1 else {
            throw VideoInspectionError.invalid("MP4 必须且只能包含一条视频轨")
        }
        guard audioTracks.isEmpty else {
            throw VideoInspectionError.invalid("MP4 不得包含音轨")
        }
        let track = videoTracks[0]
        let transform = try await track.load(.preferredTransform)
        guard transform == .identity else {
            throw VideoInspectionError.invalid("视频轨方向变换必须为恒等变换")
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard !descriptions.isEmpty,
              descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
            throw VideoInspectionError.invalid("视频轨必须只使用 H264 编码")
        }
        guard descriptions.allSatisfy({ description in
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            return Int(dimensions.width) == expected.width && Int(dimensions.height) == expected.height
        }) else {
            throw VideoInspectionError.invalid("编码尺寸与固定生成请求不一致")
        }

        let expectedDuration = CMTime(value: Int64(expected.frameCount) * Int64(expected.frameRate.denominator),
                                      timescale: expected.frameRate.numerator)
        let assetDuration = try await asset.load(.duration)
        let timeRange = try await track.load(.timeRange)
        guard timeRange.start == .zero,
              exactTime(assetDuration, equals: expectedDuration),
              exactTime(timeRange.duration, equals: expectedDuration) else {
            throw VideoInspectionError.invalid("视频起点或有理数时长与固定生成请求不一致")
        }
        try controller.check()

        try verifyCompressedTiming(asset: asset, track: track, expected: expected,
                                   controller: controller)

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            AVVideoDecompressionPropertiesKey: [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: false
            ]
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VideoInspectionError.invalid("无法建立独立的软件视频解码输出")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoInspectionError.invalid("无法开始完整视频解码：\(reader.error?.localizedDescription ?? "未知原因")")
        }

        do {
            try decodeEveryFrame(from: output, reader: reader, expected: expected,
                                 controller: controller)
        } catch {
            // AVAssetReader requires start/copy/cancel to remain on this single owner.
            cancelAndDrain(reader, output: output)
            throw error
        }
        guard reader.status == .completed else {
            reader.cancelReading()
            throw VideoInspectionError.invalid("视频未完整解码：\(reader.error?.localizedDescription ?? "读取被中断")")
        }
        try controller.check()
        VideoInspectionTestHooks.reach(.afterFullDecode)
        try controller.check()

        let finalHash = try VideoSafeFile.sha256(descriptor: opened.descriptor,
                                                 byteCount: opened.identity.size,
                                                 controller: controller,
                                                 checkpoint: .finalHashChunk,
                                                 hook: VideoInspectionTestHooks.checkpoint)
        guard finalHash == initialHash else {
            throw VideoInspectionError.changed("视频内容在检查期间发生改变")
        }
        try VideoSafeFile.verifyUnchanged(url, descriptor: opened.descriptor,
                                          initialIdentity: opened.identity,
                                          maximumBytes: maximumBytes)

        let metadata = VideoAssetMetadata(
            width: expected.width, height: expected.height, frameCount: expected.frameCount,
            frameRate: expected.frameRate,
            durationNumerator: Int64(expected.frameCount) * Int64(expected.frameRate.denominator),
            durationDenominator: expected.frameRate.numerator, codec: "h264", hasAudio: false,
            byteCount: opened.identity.size, contentSHA256: initialHash
        )
        try metadata.validate(matching: expected)
        VideoInspectionTestHooks.reach(.beforeSuccessfulFinish)
        try controller.check()
        return metadata
    }

    private static func decodeEveryFrame(from output: AVAssetReaderTrackOutput,
                                         reader: AVAssetReader, expected: VideoRequest,
                                         controller: VideoInspectionCancellation) throws {
        let frameDuration = CMTime(value: Int64(expected.frameRate.denominator),
                                   timescale: expected.frameRate.numerator)
        var frameIndex = 0
        while true {
            try controller.check()
            VideoInspectionTestHooks.reach(.decodedSampleRead)
            try controller.check()
            guard let sample = output.copyNextSampleBuffer() else { break }
            try controller.check()
            guard frameIndex < expected.frameCount else {
                throw VideoInspectionError.invalid("解码帧数超过固定生成请求")
            }
            guard CMSampleBufferDataIsReady(sample) else {
                throw VideoInspectionError.invalid("视频包含未就绪的解码帧")
            }
            let expectedPTS = CMTime(value: Int64(frameIndex) * Int64(expected.frameRate.denominator),
                                     timescale: expected.frameRate.numerator)
            let actualPTS = CMSampleBufferGetPresentationTimeStamp(sample)
            let actualDuration = CMSampleBufferGetDuration(sample)
            guard exactTime(actualPTS, equals: expectedPTS) else {
                throw VideoInspectionError.invalid("第 \(frameIndex) 帧的解码 PTS 不连续")
            }
            if actualDuration.isNumeric,
               (actualDuration <= .zero || !exactTime(actualDuration, equals: frameDuration)) {
                throw VideoInspectionError.invalid("第 \(frameIndex) 帧的解码时长与采样表矛盾")
            }
            guard let image = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetWidth(image) == expected.width,
                  CVPixelBufferGetHeight(image) == expected.height else {
                throw VideoInspectionError.invalid("第 \(frameIndex) 帧未完整解码为预期尺寸")
            }
            frameIndex += 1
        }
        guard reader.status == .completed, frameIndex == expected.frameCount else {
            throw VideoInspectionError.invalid(
                "视频完整解码得到 \(frameIndex) 帧，预期 \(expected.frameCount) 帧；\(reader.error?.localizedDescription ?? "读取未完成")"
            )
        }
    }

    private static func verifyCompressedTiming(asset: AVAsset, track: AVAssetTrack,
                                               expected: VideoRequest,
                                               controller: VideoInspectionCancellation) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VideoInspectionError.invalid("无法建立 H264 采样表检查器")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoInspectionError.invalid("无法读取 H264 采样表：\(reader.error?.localizedDescription ?? "未知原因")")
        }
        let frameDuration = CMTime(value: Int64(expected.frameRate.denominator),
                                   timescale: expected.frameRate.numerator)
        let expectedEnd = CMTime(value: Int64(expected.frameCount) * Int64(expected.frameRate.denominator),
                                 timescale: expected.frameRate.numerator)
        var frameIndex = 0
        var actualEnd = CMTime.invalid
        do {
            while true {
                try controller.check()
                VideoInspectionTestHooks.reach(.compressedSampleRead)
                try controller.check()
                guard let sample = output.copyNextSampleBuffer() else { break }
                try controller.check()
                let sampleCount = CMSampleBufferGetNumSamples(sample)
                if sampleCount == 0 { continue }
                guard sampleCount == 1, frameIndex < expected.frameCount else {
                    throw VideoInspectionError.invalid("H264 采样表不是每帧一个样本")
                }
                let expectedPTS = CMTime(value: Int64(frameIndex) * Int64(expected.frameRate.denominator),
                                         timescale: expected.frameRate.numerator)
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let duration = CMSampleBufferGetDuration(sample)
                guard exactTime(pts, equals: expectedPTS), duration > .zero,
                      exactTime(duration, equals: frameDuration) else {
                    throw VideoInspectionError.invalid("第 \(frameIndex) 个 H264 样本的 PTS 或时长不连续")
                }
                let decodeTime = CMSampleBufferGetDecodeTimeStamp(sample)
                if decodeTime.isNumeric, !exactTime(decodeTime, equals: pts) {
                    throw VideoInspectionError.invalid("H264 视频包含重排帧")
                }
                actualEnd = CMTimeAdd(pts, duration)
                frameIndex += 1
            }
            try controller.check()
        } catch {
            cancelAndDrain(reader, output: output)
            throw error
        }
        guard reader.status == .completed, frameIndex == expected.frameCount,
              exactTime(actualEnd, equals: expectedEnd) else {
            throw VideoInspectionError.invalid("H264 采样表未证明完整帧数与有理数终点")
        }
    }

    private static func cancelAndDrain(_ reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        if reader.status == .reading || reader.status == .unknown { reader.cancelReading() }
        while reader.status == .reading { _ = output.copyNextSampleBuffer() }
    }

    private static func exactTime(_ value: CMTime, equals expected: CMTime) -> Bool {
        value.isValid && value.isNumeric && !value.isIndefinite &&
            expected.isValid && expected.isNumeric && CMTimeCompare(value, expected) == 0
    }

    private static func readBudget(for expected: VideoRequest) throws -> UInt64 {
        let (pixels, pixelOverflow) = UInt64(expected.width).multipliedReportingOverflow(by: UInt64(expected.height))
        let (frameBytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 3)
        let (rawBytes, frameOverflow) = frameBytes.multipliedReportingOverflow(by: UInt64(expected.frameCount))
        let (budget, budgetOverflow) = rawBytes.addingReportingOverflow(1_048_576)
        guard !pixelOverflow, !byteOverflow, !frameOverflow, !budgetOverflow else {
            throw VideoInspectionError.limit("视频读取预算发生整数溢出")
        }
        return budget
    }
}

private enum VideoInspectionError: Error, LocalizedError, Sendable {
    case invalid(String)
    case limit(String)
    case changed(String)
    case unavailable(String)
    case io(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): "视频验证失败：\(reason)"
        case .limit(let reason): "视频超出安全读取范围：\(reason)"
        case .changed(let reason): "视频身份验证失败：\(reason)"
        case .unavailable(let reason): "视频文件不可用：\(reason)"
        case .io(let reason): "视频文件操作失败：\(reason)"
        case .timedOut: "视频检查超过期限，读取和解码已停止。"
        }
    }
}

private struct VideoFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw VideoInspectionError.invalid("目标必须是本地普通文件")
        }
        device = info.st_dev
        inode = info.st_ino
        size = UInt64(info.st_size)
        modificationSeconds = Int64(info.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changeSeconds = Int64(info.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

private enum VideoSafeFile {
    struct Opened {
        let descriptor: Int32
        let identity: VideoFileIdentity
    }

    static func open(_ url: URL, maximumBytes: UInt64) throws -> Opened {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty,
              url.standardizedFileURL.path == url.path else {
            throw VideoInspectionError.unavailable("文件路径不安全")
        }
        let components = url.path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw VideoInspectionError.unavailable("文件路径不安全")
        }

        var directory = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ioError() }
        for component in components.dropLast() {
            let next = openat(directory, component, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            Darwin.close(directory)
            guard next >= 0 else {
                if failure == ELOOP || failure == ENOTDIR {
                    throw VideoInspectionError.unavailable("路径祖先包含符号链接或不是目录")
                }
                throw ioError(failure)
            }
            directory = next
        }
        let descriptor = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let failure = errno
        Darwin.close(directory)
        guard descriptor >= 0 else {
            if failure == ELOOP { throw VideoInspectionError.unavailable("目标文件是符号链接") }
            throw ioError(failure)
        }
        do {
            let identity = try identity(descriptor: descriptor)
            guard identity.size > 0 else { throw VideoInspectionError.invalid("视频文件为空") }
            guard identity.size <= maximumBytes else {
                throw VideoInspectionError.limit("文件为 \(identity.size) 字节，读取预算为 \(maximumBytes) 字节")
            }
            return Opened(descriptor: descriptor, identity: identity)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func verifyUnchanged(_ url: URL, descriptor: Int32, initialIdentity: VideoFileIdentity,
                                maximumBytes: UInt64) throws {
        let descriptorIdentity = try identity(descriptor: descriptor)
        guard descriptorIdentity == initialIdentity else {
            throw VideoInspectionError.changed("已打开文件在读取期间发生改变")
        }
        let reopened = try open(url, maximumBytes: maximumBytes)
        defer { Darwin.close(reopened.descriptor) }
        guard reopened.identity == initialIdentity else {
            throw VideoInspectionError.changed("路径在读取期间指向了不同文件")
        }
    }

    static func validateMP4(descriptor: Int32, byteCount: UInt64) throws {
        guard byteCount >= 16 else { throw VideoInspectionError.invalid("MP4 文件头被截断") }
        let prefix = try readExact(descriptor: descriptor, offset: 0, count: 16)
        guard String(bytes: prefix[4..<8], encoding: .ascii) == "ftyp" else {
            throw VideoInspectionError.invalid("文件不是 MP4 容器")
        }
        let boxSize = UInt64(big32(prefix, 0))
        guard boxSize >= 16, boxSize <= byteCount, boxSize <= 1_048_576 else {
            throw VideoInspectionError.invalid("MP4 ftyp 数据块长度无效")
        }
        let box = try readExact(descriptor: descriptor, offset: 0, count: Int(boxSize))
        var brands = [String(bytes: box[8..<12], encoding: .ascii) ?? ""]
        if box.count > 16 {
            for offset in stride(from: 16, to: box.count - 3, by: 4) {
                brands.append(String(bytes: box[offset..<(offset + 4)], encoding: .ascii) ?? "")
            }
        }
        let mp4Brands: Set<String> = ["isom", "iso2", "iso5", "iso6", "mp41", "mp42", "avc1", "M4V "]
        guard !mp4Brands.isDisjoint(with: brands) else {
            throw VideoInspectionError.invalid("ISO 基础媒体文件未声明 MP4 兼容品牌")
        }
    }

    static func sha256(descriptor: Int32, byteCount: UInt64,
                       controller: VideoInspectionCancellation? = nil,
                       checkpoint: VideoInspectionTestCheckpoint,
                       hook: (@Sendable (VideoInspectionTestCheckpoint) -> Void)? = nil) throws -> String {
        var hasher = SHA256()
        var offset: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < byteCount {
            try controller?.check()
            try Task.checkCancellation()
            hook?(checkpoint)
            try controller?.check()
            try Task.checkCancellation()
            let requested = Int(min(UInt64(buffer.count), byteCount - offset))
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.pread(descriptor, raw.baseAddress, requested, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw VideoInspectionError.invalid("读取原始字节时提前结束") }
            hasher.update(data: Data(buffer[..<count]))
            offset += UInt64(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readExact(descriptor: Int32, offset: UInt64, count: Int) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        var completed = 0
        while completed < count {
            let readCount = result.withUnsafeMutableBytes { raw in
                Darwin.pread(descriptor, raw.baseAddress!.advanced(by: completed), count - completed,
                             off_t(offset + UInt64(completed)))
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { throw VideoInspectionError.invalid("MP4 结构被截断") }
            completed += readCount
        }
        return result
    }

    private static func identity(descriptor: Int32) throws -> VideoFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ioError() }
        return try VideoFileIdentity(info)
    }

    private static func big32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func ioError(_ code: Int32 = errno) -> VideoInspectionError {
        .io(String(cString: strerror(code)))
    }
}

enum VideoInspectionTestCheckpoint: Sendable, Equatable {
    case descriptorOpened
    case resourceRead
    case contentHashChunk
    case initialHashChunk
    case compressedSampleRead
    case decodedSampleRead
    case afterFullDecode
    case finalHashChunk
    case beforeSuccessfulFinish
}

enum VideoInspectionTestHooks {
    @TaskLocal static var checkpoint: (@Sendable (VideoInspectionTestCheckpoint) -> Void)?

    static func reach(_ value: VideoInspectionTestCheckpoint) {
        checkpoint?(value)
    }
}

private enum VideoInspectionStop: Sendable { case cancelled, timedOut }

/// AVFoundation's cancellation entry points are documented as callable across queues.
/// The lock makes the non-Sendable handles visible only long enough to stop them.
private final class VideoInspectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant
    private var stopReason: VideoInspectionStop?
    private var finished = false
    private var asset: AVAsset?
    private var loader: VideoDescriptorResourceLoader?

    init(deadline: ContinuousClock.Instant) {
        self.deadline = deadline
    }

    func install(asset: AVAsset) {
        lock.lock()
        let shouldStop = stopReason != nil || finished
        if !shouldStop { self.asset = asset }
        lock.unlock()
        if shouldStop { asset.cancelLoading() }
    }

    func install(loader: VideoDescriptorResourceLoader) {
        lock.lock()
        let shouldStop = stopReason != nil || finished
        if !shouldStop { self.loader = loader }
        lock.unlock()
        if shouldStop { loader.requestStop() }
    }

    func stop(_ reason: VideoInspectionStop) {
        lock.lock()
        if stopReason == nil, !finished { stopReason = reason }
        let asset = self.asset
        let loader = self.loader
        lock.unlock()
        asset?.cancelLoading()
        loader?.requestStop()
    }

    func check() throws {
        if ContinuousClock.now >= deadline { stop(.timedOut) }
        lock.lock()
        let reason = stopReason
        lock.unlock()
        switch reason {
        case .cancelled?: throw CancellationError()
        case .timedOut?: throw VideoInspectionError.timedOut
        case nil: try Task.checkCancellation()
        }
    }

    var terminalError: (any Error)? {
        lock.lock()
        let reason = stopReason
        lock.unlock()
        return switch reason {
        case .cancelled?: CancellationError()
        case .timedOut?: VideoInspectionError.timedOut
        case nil: nil
        }
    }

    func finishSuccessfully() throws {
        if ContinuousClock.now >= deadline { stop(.timedOut) }
        try Task.checkCancellation()
        lock.lock()
        let reason = stopReason
        if reason == nil { finished = true }
        asset = nil
        loader = nil
        lock.unlock()
        switch reason {
        case .cancelled?: throw CancellationError()
        case .timedOut?: throw VideoInspectionError.timedOut
        case nil: return
        }
    }

    func finishAfterFailure() {
        lock.lock()
        finished = true
        asset = nil
        loader = nil
        lock.unlock()
    }
}

private final class VideoDescriptorResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "DWorkbench.VideoMediaInspector.ResourceLoader")

    private let descriptor: Int32
    private let byteCount: UInt64
    private let checkpoint: (@Sendable (VideoInspectionTestCheckpoint) -> Void)?
    private let lock = NSLock()
    private var stopping = false

    init(descriptor: Int32, byteCount: UInt64,
         checkpoint: (@Sendable (VideoInspectionTestCheckpoint) -> Void)?) {
        self.descriptor = descriptor
        self.byteCount = byteCount
        self.checkpoint = checkpoint
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        do {
            try checkActive()
            if let information = loadingRequest.contentInformationRequest {
                information.contentType = AVFileType.mp4.rawValue
                information.contentLength = Int64(byteCount)
                information.isByteRangeAccessSupported = true
            }
            if let dataRequest = loadingRequest.dataRequest {
                try respond(to: dataRequest)
            }
            try checkActive()
            if !loadingRequest.isCancelled && !loadingRequest.isFinished { loadingRequest.finishLoading() }
        } catch {
            if !loadingRequest.isCancelled && !loadingRequest.isFinished { loadingRequest.finishLoading(with: error) }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // Requests execute serially. A queued cancellation is drained before descriptor close.
    }

    func stopAndDrain() {
        requestStop()
        queue.sync {}
    }

    func requestStop() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    private func respond(to request: AVAssetResourceLoadingDataRequest) throws {
        let requestedOffset = request.currentOffset != 0 ? request.currentOffset : request.requestedOffset
        guard requestedOffset >= 0, request.requestedLength >= 0 else {
            throw VideoInspectionError.invalid("AVFoundation 请求了无效字节范围")
        }
        let start = UInt64(requestedOffset)
        guard start <= byteCount else {
            throw VideoInspectionError.invalid("AVFoundation 请求超出已验证文件")
        }
        let requestedEnd: UInt64
        if request.requestsAllDataToEndOfResource {
            requestedEnd = byteCount
        } else {
            let (end, overflow) = start.addingReportingOverflow(UInt64(request.requestedLength))
            guard !overflow else { throw VideoInspectionError.invalid("AVFoundation 字节范围溢出") }
            requestedEnd = min(end, byteCount)
        }
        var offset = start
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < requestedEnd {
            try checkActive()
            checkpoint?(.resourceRead)
            try checkActive()
            let requested = Int(min(UInt64(buffer.count), requestedEnd - offset))
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.pread(descriptor, raw.baseAddress, requested, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw VideoInspectionError.invalid("AVFoundation 读取已验证文件时提前结束") }
            request.respond(with: Data(buffer[..<count]))
            offset += UInt64(count)
        }
    }

    private func checkActive() throws {
        lock.lock()
        let isStopping = stopping
        lock.unlock()
        if isStopping { throw CancellationError() }
    }
}
