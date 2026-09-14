import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import DInference
import Darwin
import Foundation
import Testing
import VideoToolbox
@testable import DWorkbench

@Suite("Descriptor-bound MP4 inspection", .serialized)
struct VideoMediaInspectorTests {
    @Test func validSoftwareH264PreservesFractionalRateBytesAndInput() async throws {
        try await withVideoFixtureDirectory { directory in
            let file = directory.appendingPathComponent("fractional.mp4")
            let rate = VideoFrameRate(numerator: 48_000, denominator: 2_002)
            try await VideoTestMedia.writeMP4(to: file, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate)
            let request = videoRequest(width: 64, height: 32, frameCount: 5, frameRate: rate)
            let original = try Data(contentsOf: file)
            let metadata = try await VideoMediaInspector.inspect(at: file, expected: request)

            #expect(metadata.width == 64 && metadata.height == 32)
            #expect(metadata.frameCount == 5 && metadata.frameRate == rate)
            #expect(metadata.durationNumerator == 10_010)
            #expect(metadata.durationDenominator == 48_000)
            #expect(metadata.codec == "h264" && !metadata.hasAudio)
            #expect(metadata.byteCount == UInt64(original.count))
            #expect(metadata.contentSHA256 == VideoTestMedia.digest(original))
            #expect(try Data(contentsOf: file) == original)
            #expect(try VideoMediaInspector.contentSHA256(at: file, maximumBytes: UInt64(original.count))
                    == VideoTestMedia.digest(original))
        }
    }

    @Test func rejectsWrongDimensionsFrameCountAndFrameRate() async throws {
        try await withVideoFixtureDirectory { directory in
            let file = directory.appendingPathComponent("geometry.mp4")
            let rate = VideoFrameRate(numerator: 24, denominator: 1)
            try await VideoTestMedia.writeMP4(to: file, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(
                    at: file, expected: videoRequest(width: 80, height: 32, frameCount: 5, frameRate: rate)
                )
            }
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(
                    at: file, expected: videoRequest(width: 64, height: 32, frameCount: 9, frameRate: rate)
                )
            }
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(
                    at: file, expected: videoRequest(width: 64, height: 32, frameCount: 5,
                                                     frameRate: .init(numerator: 30, denominator: 1))
                )
            }
        }
    }

    @Test func rejectsWrongPerFrameTimestampsAndContainerDuration() async throws {
        try await withVideoFixtureDirectory { directory in
            let rate = VideoFrameRate(numerator: 24, denominator: 1)
            let request = videoRequest(width: 64, height: 32, frameCount: 5, frameRate: rate)
            let badPTS = directory.appendingPathComponent("bad-pts.mp4")
            let timestamps = [
                CMTime(value: 0, timescale: 48), CMTime(value: 2, timescale: 48),
                CMTime(value: 5, timescale: 48), CMTime(value: 6, timescale: 48),
                CMTime(value: 8, timescale: 48)
            ]
            try await VideoTestMedia.writeMP4(to: badPTS, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate,
                                              presentationTimes: timestamps)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: badPTS, expected: request)
            }

            let badDuration = directory.appendingPathComponent("bad-duration.mp4")
            try await VideoTestMedia.writeMP4(to: badDuration, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate,
                                              endTime: CMTime(value: 6, timescale: 24))
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: badDuration, expected: request)
            }
        }
    }

    @Test func rejectsAudioTrackAndTruncatedMP4() async throws {
        try await withVideoFixtureDirectory { directory in
            let rate = VideoFrameRate(numerator: 24, denominator: 1)
            let request = videoRequest(width: 64, height: 32, frameCount: 5, frameRate: rate)
            let audio = directory.appendingPathComponent("audio.mp4")
            try await VideoTestMedia.writeMP4(to: audio, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate, includeAudio: true)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: audio, expected: request)
            }

            let truncated = directory.appendingPathComponent("truncated.mp4")
            try await VideoTestMedia.writeMP4(to: truncated, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate)
            let size = try #require(try truncated.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let handle = try FileHandle(forWritingTo: truncated)
            try handle.truncate(atOffset: UInt64(size / 2))
            try handle.close()
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: truncated, expected: request)
            }
        }
    }

    @Test func rejectsDirectAndAncestorSymlinksAndByteBudget() async throws {
        try await withVideoFixtureDirectory { directory in
            let file = directory.appendingPathComponent("safe.mp4")
            let rate = VideoFrameRate(numerator: 24, denominator: 1)
            try await VideoTestMedia.writeMP4(to: file, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate)
            let request = videoRequest(width: 64, height: 32, frameCount: 5, frameRate: rate)
            let size = UInt64(try #require(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize))
            #expect(throws: (any Error).self) {
                try VideoMediaInspector.contentSHA256(at: file, maximumBytes: size - 1)
            }

            let alias = directory.appendingPathComponent("alias.mp4")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(at: alias, expected: request)
            }

            let realParent = directory.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
            let nested = realParent.appendingPathComponent("nested.mp4")
            try FileManager.default.copyItem(at: file, to: nested)
            let parentAlias = directory.appendingPathComponent("parent-alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: realParent)
            await #expect(throws: (any Error).self) {
                try await VideoMediaInspector.inspect(
                    at: parentAlias.appendingPathComponent("nested.mp4"), expected: request
                )
            }
        }
    }

    @Test func decoderNeverFollowsRestoredPathSubstitution() async throws {
        try await withVideoFixtureDirectory { directory in
            let rate = VideoFrameRate(numerator: 24, denominator: 1)
            let request = videoRequest(width: 64, height: 32, frameCount: 5, frameRate: rate)
            let selected = directory.appendingPathComponent("selected.mp4")
            let substitute = directory.appendingPathComponent("substitute.mp4")
            try await VideoTestMedia.writeMP4(to: selected, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate)
            try await VideoTestMedia.writeMP4(to: substitute, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate)
            let selectedSize = try #require(try selected.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let selectedHandle = try FileHandle(forWritingTo: selected)
            try selectedHandle.truncate(atOffset: UInt64(selectedSize / 2))
            try selectedHandle.close()

            let swap = PathSwap(selected: selected, substitute: substitute,
                                held: directory.appendingPathComponent("held.mp4"))
            await #expect(throws: (any Error).self) {
                try await VideoInspectionTestHooks.$checkpoint.withValue({ point in
                    swap.reach(point)
                }) {
                    try await VideoMediaInspector.inspect(at: selected, expected: request)
                }
            }
            #expect(swap.restoredWithoutError)
            #expect(FileManager.default.fileExists(atPath: selected.path))
        }
    }

    @Test func validDescriptorSurvivesDirectorySubstitutionUntilFullDecode() async throws {
        try await withVideoFixtureDirectory { directory in
            let rate = VideoFrameRate(numerator: 24, denominator: 1)
            let request = videoRequest(width: 64, height: 32, frameCount: 5, frameRate: rate)
            let selectedDirectory = directory.appendingPathComponent("selected-directory", isDirectory: true)
            let substituteDirectory = directory.appendingPathComponent("substitute-directory", isDirectory: true)
            try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: substituteDirectory, withIntermediateDirectories: false)
            let selected = selectedDirectory.appendingPathComponent("asset.mp4")
            let substitute = substituteDirectory.appendingPathComponent("asset.mp4")
            try await VideoTestMedia.writeMP4(to: selected, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate)
            try await VideoTestMedia.writeMP4(to: substitute, width: 80, height: 32,
                                              frameCount: 5, frameRate: rate)
            let originalSelected = try Data(contentsOf: selected)
            let originalSubstitute = try Data(contentsOf: substitute)
            let swap = DirectorySwap(
                selected: selectedDirectory, substitute: substituteDirectory,
                held: directory.appendingPathComponent("held-directory", isDirectory: true)
            )
            defer { swap.restoreIfNeeded() }

            let metadata = try await VideoInspectionTestHooks.$checkpoint.withValue({ point in
                swap.reach(point)
            }) {
                try await VideoMediaInspector.inspect(at: selected, expected: request)
            }
            #expect(metadata.width == 64 && metadata.height == 32)
            #expect(swap.restoredWithoutError)
            #expect(try Data(contentsOf: selected) == originalSelected)
            #expect(try Data(contentsOf: substitute) == originalSubstitute)
        }
    }

    @Test func cancellationAtResourceAndDecodedReadsWaitsForDrain() async throws {
        try await withVideoFixtureDirectory { directory in
            let rate = VideoFrameRate(numerator: 24, denominator: 1)
            let request = videoRequest(width: 64, height: 32, frameCount: 5, frameRate: rate)
            let file = directory.appendingPathComponent("cancel.mp4")
            try await VideoTestMedia.writeMP4(to: file, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate)

            for checkpoint in [VideoInspectionTestCheckpoint.resourceRead, .decodedSampleRead] {
                await expectCancelledInspection(at: checkpoint, file: file, request: request)
            }
        }
    }

    @Test func deadlinesAtFinalHashAndSuccessBoundaryWaitForDrain() async throws {
        try await withVideoFixtureDirectory { directory in
            let rate = VideoFrameRate(numerator: 24, denominator: 1)
            let request = videoRequest(width: 64, height: 32, frameCount: 5, frameRate: rate)
            let file = directory.appendingPathComponent("deadline.mp4")
            try await VideoTestMedia.writeMP4(to: file, width: 64, height: 32,
                                              frameCount: 5, frameRate: rate)

            await expectTimedOutInspection(at: .finalHashChunk, file: file, request: request)
            await expectTimedOutInspection(at: .beforeSuccessfulFinish, file: file, request: request)
        }
    }
}

private func videoRequest(width: Int, height: Int, frameCount: Int,
                          frameRate: VideoFrameRate) -> VideoRequest {
    VideoRequest(prompt: "fixture", negativePrompt: "", width: width, height: height,
                 frameCount: frameCount, frameRate: frameRate, steps: 1,
                 guidanceScale: 1, scheduleShift: 1, seed: 1,
                 executionProfile: VideoExecutionCapability.wan21.profile)
}

private enum VideoTestMedia {
    static func writeMP4(to url: URL, width: Int, height: Int, frameCount: Int,
                         frameRate: VideoFrameRate, presentationTimes: [CMTime]? = nil,
                         endTime: CMTime? = nil, includeAudio: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var completed = false
        defer {
            if !completed, writer.status == .writing || writer.status == .unknown {
                writer.cancelWriting()
            }
        }
        writer.shouldOptimizeForNetworkUse = false
        writer.movieTimeScale = frameRate.numerator
        let encoderID = try softwareH264EncoderID()
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
                kVTVideoEncoderSpecification_EncoderID as String: encoderID
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 100_000,
                AVVideoExpectedSourceFrameRateKey: Double(frameRate.numerator) / Double(frameRate.denominator),
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: frameCount,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = frameRate.numerator
        guard writer.canAdd(videoInput) else { throw FixtureError("无法添加视频轨") }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: false
            ]
        )

        var audioInput: AVAssetWriterInput?
        var audioSample: CMSampleBuffer?
        if includeAudio {
            let audio = try makeSilentAudio(duration: CMTime(value: Int64(frameCount) * Int64(frameRate.denominator),
                                                             timescale: frameRate.numerator))
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audio.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000
                ],
                sourceFormatHint: audio.format
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw FixtureError("无法添加音轨") }
            writer.add(input)
            audioInput = input
            audioSample = audio.sample
        }

        guard writer.startWriting() else { throw FixtureError(writer.error?.localizedDescription ?? "编码无法开始") }
        writer.startSession(atSourceTime: .zero)
        let times = presentationTimes ?? (0..<frameCount).map {
            CMTime(value: Int64($0) * Int64(frameRate.denominator), timescale: frameRate.numerator)
        }
        guard times.count == frameCount else { throw FixtureError("时间戳数量错误") }
        for index in 0..<frameCount {
            try await waitUntilReady(videoInput, writer: writer, deadline: deadline)
            let pixel = try pixelBuffer(width: width, height: height, value: UInt8(index * 31))
            guard adaptor.append(pixel, withPresentationTime: times[index]) else {
                throw FixtureError(writer.error?.localizedDescription ?? "无法追加视频帧")
            }
        }
        if let audioInput, let audioSample {
            try await waitUntilReady(audioInput, writer: writer, deadline: deadline)
            guard audioInput.append(audioSample) else {
                throw FixtureError(writer.error?.localizedDescription ?? "无法追加音频样本")
            }
            audioInput.markAsFinished()
        }
        let expectedEnd = CMTime(value: Int64(frameCount) * Int64(frameRate.denominator),
                                 timescale: frameRate.numerator)
        writer.endSession(atSourceTime: endTime ?? expectedEnd)
        videoInput.markAsFinished()
        let signal = LockedFlag()
        writer.finishWriting { signal.set() }
        while !signal.value {
            guard ContinuousClock.now < deadline else { throw FixtureError("软件 H264 编码超时") }
            if writer.status == .failed || writer.status == .cancelled { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard writer.status == .completed else {
            throw FixtureError(writer.error?.localizedDescription ?? "编码未完成")
        }
        completed = true
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func softwareH264EncoderID() throws -> String {
        var copied: CFArray?
        let status = VTCopyVideoEncoderList(nil, &copied)
        guard status == noErr, let encoders = copied as? [[String: Any]] else {
            throw FixtureError("无法枚举软件编码器：\(status)")
        }
        for encoder in encoders {
            let codec = (encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value
            let hardware = (encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue ?? false
            if codec == kCMVideoCodecType_H264, !hardware,
               let identifier = encoder[kVTVideoEncoderList_EncoderID as String] as? String {
                return identifier
            }
        }
        throw FixtureError("本机没有软件 H264 编码器")
    }

    private static func pixelBuffer(width: Int, height: Int, value: UInt8) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferMetalCompatibilityKey: false] as CFDictionary,
                                         &optional)
        guard status == kCVReturnSuccess, let pixel = optional else {
            throw FixtureError("无法创建 CPU pixel buffer：\(status)")
        }
        guard CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pixel) else {
            throw FixtureError("无法映射 CPU pixel buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        memset(base, Int32(value), CVPixelBufferGetBytesPerRow(pixel) * height)
        return pixel
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter,
                                       deadline: ContinuousClock.Instant) async throws {
        while !input.isReadyForMoreMediaData {
            guard ContinuousClock.now < deadline else { throw FixtureError("等待软件编码器超时") }
            guard writer.status != .failed, writer.status != .cancelled else {
                throw FixtureError(writer.error?.localizedDescription ?? "编码器停止")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func makeSilentAudio(duration: CMTime) throws ->
        (sample: CMSampleBuffer, format: CMAudioFormatDescription, sampleRate: Double) {
        let sampleRate = 48_000.0
        let frameCount = max(1, Int((CMTimeGetSeconds(duration) * sampleRate).rounded(.up)))
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var optionalFormat: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &optionalFormat
        )
        guard formatStatus == noErr, let format = optionalFormat else {
            throw FixtureError("无法创建音频格式：\(formatStatus)")
        }
        let byteCount = frameCount * 2
        var optionalBlock: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &optionalBlock
        )
        guard blockStatus == noErr, let block = optionalBlock else {
            throw FixtureError("无法创建音频数据：\(blockStatus)")
        }
        let silence = Data(repeating: 0, count: byteCount)
        let copyStatus = silence.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copyStatus == noErr else { throw FixtureError("无法填充音频数据：\(copyStatus)") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = 2
        var optionalSample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &optionalSample
        )
        guard sampleStatus == noErr, let sample = optionalSample else {
            throw FixtureError("无法创建音频样本：\(sampleStatus)")
        }
        return (sample, format, sampleRate)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set() {
        lock.lock(); stored = true; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

private struct FixtureError: Error { let message: String; init(_ message: String) { self.message = message } }

private func expectCancelledInspection(at checkpoint: VideoInspectionTestCheckpoint,
                                       file: URL, request: VideoRequest) async {
    let gate = InspectionGate(target: checkpoint)
    let completion = CompletionProbe()
    let task = Task {
        do {
            let value = try await VideoInspectionTestHooks.$checkpoint.withValue({ point in gate.reach(point) }) {
                try await VideoMediaInspector.inspect(at: file, expected: request)
            }
            completion.finish()
            return value
        } catch {
            completion.finish()
            throw error
        }
    }
    let blocked = gate.waitUntilBlocked()
    if !blocked {
        task.cancel()
        gate.release()
        _ = try? await task.value
        Issue.record("检查未到达预期取消边界 \(checkpoint)")
        return
    }
    task.cancel()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!completion.isFinished)
    gate.release()
    do {
        _ = try await task.value
        Issue.record("取消边界 \(checkpoint) 错误返回成功")
    } catch is CancellationError {
        // Expected only after the blocked owner/resource-loader work has been released and drained.
    } catch {
        Issue.record("取消边界 \(checkpoint) 返回了非取消错误：\(error)")
    }
    let countAtReturn = gate.reachCount
    try? await Task.sleep(for: .milliseconds(20))
    #expect(gate.reachCount == countAtReturn)
}

private func expectTimedOutInspection(at checkpoint: VideoInspectionTestCheckpoint,
                                     file: URL, request: VideoRequest) async {
    let gate = InspectionGate(target: checkpoint)
    let completion = CompletionProbe()
    let task = Task {
        do {
            let value = try await VideoInspectionTestHooks.$checkpoint.withValue({ point in gate.reach(point) }) {
                try await VideoMediaInspector.inspect(at: file, expected: request, timeoutSeconds: 2)
            }
            completion.finish()
            return value
        } catch {
            completion.finish()
            throw error
        }
    }
    let blocked = gate.waitUntilBlocked()
    if !blocked {
        task.cancel()
        gate.release()
        _ = try? await task.value
        Issue.record("检查未到达预期期限边界 \(checkpoint)")
        return
    }
    try? await Task.sleep(for: .milliseconds(2_100))
    #expect(!completion.isFinished)
    gate.release()
    do {
        _ = try await task.value
        Issue.record("期限边界 \(checkpoint) 错误返回成功")
    } catch {
        #expect(error.localizedDescription.contains("超过期限"))
    }
    let countAtReturn = gate.reachCount
    try? await Task.sleep(for: .milliseconds(20))
    #expect(gate.reachCount == countAtReturn)
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish() {
        lock.lock(); finished = true; lock.unlock()
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }
}

private final class InspectionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let target: VideoInspectionTestCheckpoint
    private var blocked = false
    private var released = false
    private var count = 0

    init(target: VideoInspectionTestCheckpoint) { self.target = target }

    func reach(_ checkpoint: VideoInspectionTestCheckpoint) {
        condition.lock()
        count += 1
        if checkpoint == target, !blocked {
            blocked = true
            condition.broadcast()
            while !released { condition.wait() }
        }
        condition.unlock()
    }

    func waitUntilBlocked() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let end = Date().addingTimeInterval(5)
        while !blocked, condition.wait(until: end) {}
        return blocked
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    var reachCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }
}

private final class DirectorySwap: @unchecked Sendable {
    private let lock = NSLock()
    private let selected: URL
    private let substitute: URL
    private let held: URL
    private var phase = 0
    private var storedError: (any Error)?

    init(selected: URL, substitute: URL, held: URL) {
        self.selected = selected; self.substitute = substitute; self.held = held
    }

    func reach(_ checkpoint: VideoInspectionTestCheckpoint) {
        lock.lock()
        defer { lock.unlock() }
        do {
            if checkpoint == .descriptorOpened, phase == 0 {
                try FileManager.default.moveItem(at: selected, to: held)
                try FileManager.default.moveItem(at: substitute, to: selected)
                phase = 1
            } else if checkpoint == .afterFullDecode, phase == 1 {
                try restoreLocked()
            }
        } catch {
            storedError = error
        }
    }

    func restoreIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard phase == 1 else { return }
        do { try restoreLocked() }
        catch { storedError = error }
    }

    private func restoreLocked() throws {
        try FileManager.default.moveItem(at: selected, to: substitute)
        try FileManager.default.moveItem(at: held, to: selected)
        phase = 2
    }

    var restoredWithoutError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase == 2 && storedError == nil
    }
}

private final class PathSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let selected: URL
    private let substitute: URL
    private let held: URL
    private var phase = 0
    private var error: (any Error)?

    init(selected: URL, substitute: URL, held: URL) {
        self.selected = selected; self.substitute = substitute; self.held = held
    }

    func reach(_ checkpoint: VideoInspectionTestCheckpoint) {
        lock.lock()
        defer { lock.unlock() }
        do {
            if checkpoint == .descriptorOpened, phase == 0 {
                try FileManager.default.moveItem(at: selected, to: held)
                try FileManager.default.moveItem(at: substitute, to: selected)
                phase = 1
            } else if checkpoint == .resourceRead, phase == 1 {
                try FileManager.default.moveItem(at: selected, to: substitute)
                try FileManager.default.moveItem(at: held, to: selected)
                phase = 2
            }
        } catch {
            self.error = error
        }
    }

    var restoredWithoutError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase == 2 && error == nil
    }
}

private func withVideoFixtureDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let base = ProcessInfo.processInfo.environment["D_TEST_WORKBENCH_ROOT"]
        ?? ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("D-Workbench-Video-Tests").path
    let directory = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory.resolvingSymlinksInPath())
}
