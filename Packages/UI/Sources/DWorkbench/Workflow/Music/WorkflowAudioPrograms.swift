import AVFoundation
import Foundation
import Synchronization

/// Deterministic, model-free audio transformations over a Store-owned frozen snapshot.
/// The caller remains responsible for publishing the returned derived WAV as a new asset.
public enum WorkflowAudioPrograms {
    /// Returns an in-memory, interleaved little-endian Float32 WAV. The source is never written.
    public static func transform(at source: URL, registered: AudioAssetMetadata,
                                 range: AudioFrameRange?, sampleRate: Int?,
                                 channels: Int?) throws -> Data {
        try Task.checkCancellation()
        if let sampleRate, ![16_000, 44_100, 48_000].contains(sampleRate) {
            throw AudioMediaError.unsupportedFormat
        }
        if let channels, channels != 1 && channels != 2 {
            throw AudioMediaError.unsupportedFormat
        }

        let policy: AudioInspectionPolicy
        switch registered.origin {
        case .modelGenerated, .programGenerated: policy = .generated
        case .importedFile, .microphone: policy = .original
        }
        let before = try AudioMediaInspector.inspect(at: source, policy: policy)
        guard before.format == registered.format,
              before.contentSHA256 == registered.contentSHA256 else {
            throw ProjectStoreError.externalModification
        }

        let format = before.format
        let selected = range ?? AudioFrameRange(startFrame: 0, endFrame: format.frameCount)
        guard selected.startFrame >= 0, selected.startFrame < selected.endFrame,
              selected.endFrame <= format.frameCount else {
            throw AudioMediaError.invalidRange
        }
        let selectedFrames = selected.endFrame - selected.startFrame
        let outputRate: Double
        if let sampleRate {
            outputRate = Double(sampleRate)
        } else {
            outputRate = Double(try exactIntegerRate(format.sampleRate))
        }
        let outputChannels = channels ?? format.channelCount
        let duration = Double(selectedFrames) / format.sampleRate
        guard duration.isFinite, duration <= AudioLimits.maximumSeconds else {
            throw AudioMediaError.limitExceeded
        }

        let expectedFrames = Double(selectedFrames) * outputRate / format.sampleRate
        guard expectedFrames.isFinite, expectedFrames > 0,
              expectedFrames <= Double(Int64.max - 1) else {
            throw AudioMediaError.limitExceeded
        }
        let maximumOutputFrames = outputRate == format.sampleRate
            ? selectedFrames
            : Int64((expectedFrames + 1).rounded(.down))
        try validateOutputStorage(frames: maximumOutputFrames, channels: outputChannels)

        let payload = try AudioMediaInspector.withOriginalSource(at: source, policy: policy) { _, _ in
            let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            guard file.length == format.frameCount,
                  file.processingFormat.sampleRate == format.sampleRate,
                  Int(file.processingFormat.channelCount) == format.channelCount,
                  file.processingFormat.commonFormat == .pcmFormatFloat32,
                  !file.processingFormat.isInterleaved else {
                throw AudioMediaError.invalidMedia("转换前音频格式已改变")
            }
            file.framePosition = selected.startFrame
            if outputRate == format.sampleRate {
                return try decodeWithoutResampling(file: file, frames: selectedFrames,
                                                   sourceChannels: format.channelCount,
                                                   outputChannels: outputChannels)
            }
            return try resample(file: file, frames: selectedFrames,
                                sourceRate: format.sampleRate,
                                sourceChannels: format.channelCount,
                                outputRate: outputRate, outputChannels: outputChannels,
                                expectedFrames: expectedFrames,
                                maximumOutputFrames: maximumOutputFrames)
        }

        let outputFrames = payload.count / (outputChannels * MemoryLayout<Float>.size)
        guard payload.count % (outputChannels * MemoryLayout<Float>.size) == 0,
              outputFrames > 0 else {
            throw AudioMediaError.invalidMedia("转换输出的 PCM 帧未完整对齐")
        }
        if outputRate == format.sampleRate {
            guard Int64(outputFrames) == selectedFrames else {
                throw AudioMediaError.invalidMedia("同采样率转换未保留精确选区帧数")
            }
        } else {
            guard abs(Double(outputFrames) - expectedFrames) <= 1 else {
                throw AudioMediaError.invalidMedia("重采样输出漂移超过一个采样帧")
            }
        }
        try validateOutputBudget(frames: Int64(outputFrames), sampleRate: outputRate,
                                 channels: outputChannels)

        try Task.checkCancellation()
        let after = try AudioMediaInspector.inspect(at: source, policy: policy)
        guard after.format == before.format, after.contentSHA256 == before.contentSHA256,
              after.format == registered.format,
              after.contentSHA256 == registered.contentSHA256 else {
            throw ProjectStoreError.externalModification
        }

        let rate = UInt32(outputRate)
        var result = wavHeader(dataBytes: UInt32(payload.count), sampleRate: rate,
                               channels: UInt16(outputChannels))
        result.reserveCapacity(44 + payload.count)
        let cancellationStride = 64 * 1_024
        var offset = 0
        while offset < payload.count {
            try Task.checkCancellation()
            let end = min(payload.count, offset + cancellationStride)
            result.append(contentsOf: payload[offset..<end])
            offset = end
        }
        return result
    }

    private static func exactIntegerRate(_ value: Double) throws -> Int {
        let rounded = value.rounded()
        guard value.isFinite, value == rounded, rounded > 0,
              rounded <= Double(UInt32.max) else {
            throw AudioMediaError.invalidMedia(
                "WAV 输出的采样率字段只能表示整数；源采样率为 \(value) Hz，请显式选择输出采样率"
            )
        }
        return Int(rounded)
    }

    private static func validateOutputBudget(frames: Int64, sampleRate: Double,
                                             channels: Int) throws {
        guard frames > 0, channels == 1 || channels == 2,
              sampleRate.isFinite, sampleRate > 0,
              Double(frames) / sampleRate <= AudioLimits.maximumSeconds else {
            throw AudioMediaError.limitExceeded
        }
        try validateOutputStorage(frames: frames, channels: channels)
    }

    private static func validateOutputStorage(frames: Int64, channels: Int) throws {
        guard frames > 0, channels == 1 || channels == 2 else {
            throw AudioMediaError.limitExceeded
        }
        let (sampleCount, sampleOverflow) = frames.multipliedReportingOverflow(by: Int64(channels))
        let (dataBytes, byteOverflow) = sampleCount.multipliedReportingOverflow(by: 4)
        guard !sampleOverflow, !byteOverflow, dataBytes > 0,
              dataBytes <= Int64(UInt32.max) - 36,
              dataBytes + 44 <= Int64(AudioLimits.maximumGeneratedBytes),
              dataBytes <= Int64(Int.max) else {
            throw AudioMediaError.limitExceeded
        }
    }

    private static func decodeWithoutResampling(file: AVAudioFile, frames: Int64,
                                                sourceChannels: Int,
                                                outputChannels: Int) throws -> Data {
        let byteCount = try exactByteCount(frames: frames, channels: outputChannels)
        var result = Data(capacity: byteCount)
        var remaining = frames
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(min(4_096, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: requested) else {
                throw AudioMediaError.unavailable("无法分配 PCM 解码缓冲区")
            }
            try file.read(into: buffer, frameCount: requested)
            guard buffer.frameLength == requested, let samples = buffer.floatChannelData else {
                throw AudioMediaError.invalidMedia("选区发生不完整读取")
            }
            try appendMapped(samples: samples, frameCount: Int(requested),
                             sourceChannels: sourceChannels, outputChannels: outputChannels,
                             to: &result)
            remaining -= Int64(requested)
        }
        guard result.count == byteCount else {
            throw AudioMediaError.invalidMedia("选区转换字节数不完整")
        }
        return result
    }

    private static func resample(file: AVAudioFile, frames: Int64,
                                 sourceRate: Double, sourceChannels: Int,
                                 outputRate: Double, outputChannels: Int,
                                 expectedFrames: Double,
                                 maximumOutputFrames: Int64) throws -> Data {
        guard let converterInput = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: sourceRate,
                                                 channels: AVAudioChannelCount(outputChannels),
                                                 interleaved: false),
              let converterOutput = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: outputRate,
                                                  channels: AVAudioChannelCount(outputChannels),
                                                  interleaved: false),
              let converter = AVAudioConverter(from: converterInput, to: converterOutput),
              let output = AVAudioPCMBuffer(pcmFormat: converterOutput, frameCapacity: 4_096) else {
            throw AudioMediaError.unavailable("无法创建高质量 PCM 重采样器")
        }
        converter.primeMethod = .normal
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let inputState = WorkflowAudioConversionState(Mutex(WorkflowAudioConversionInput(
            file: file, converterFormat: converterInput, sourceChannels: sourceChannels,
            outputChannels: outputChannels, remaining: frames
        )))
        let capacity = try exactByteCount(frames: maximumOutputFrames, channels: outputChannels)
        var result = Data(capacity: capacity)
        var producedFrames: Int64 = 0
        var noProgress = 0

        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, status in
                inputState.state.withLock { state in
                    if state.failure != nil || state.remaining == 0 {
                        status.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try Task.checkCancellation()
                        let count = AVAudioFrameCount(min(Int64(max(1, requested)),
                                                          min(4_096, state.remaining)))
                        guard let sourceBuffer = AVAudioPCMBuffer(
                            pcmFormat: state.file.processingFormat, frameCapacity: count
                        ), let mapped = AVAudioPCMBuffer(
                            pcmFormat: state.converterFormat, frameCapacity: count
                        ) else {
                            throw AudioMediaError.unavailable("无法分配有界重采样输入缓冲区")
                        }
                        try state.file.read(into: sourceBuffer, frameCount: count)
                        guard sourceBuffer.frameLength == count,
                              let sourceSamples = sourceBuffer.floatChannelData,
                              let mappedSamples = mapped.floatChannelData else {
                            throw AudioMediaError.invalidMedia("重采样选区发生不完整读取")
                        }
                        mapped.frameLength = count
                        try map(samples: sourceSamples, frameCount: Int(count),
                                sourceChannels: state.sourceChannels,
                                outputChannels: state.outputChannels,
                                into: mappedSamples)
                        state.remaining -= Int64(count)
                        status.pointee = .haveData
                        return mapped
                    } catch {
                        state.failure = error
                        status.pointee = .endOfStream
                        return nil
                    }
                }
            }
            if let failure = inputState.state.withLock({ $0.failure }) { throw failure }
            if let conversionError { throw AudioMediaError.io(conversionError.localizedDescription) }
            guard status != .error else {
                throw AudioMediaError.invalidMedia("PCM 重采样失败")
            }

            let count = Int(output.frameLength)
            if count > 0 {
                guard let samples = output.floatChannelData else {
                    throw AudioMediaError.invalidMedia("重采样输出缺少 PCM 数据")
                }
                producedFrames += Int64(count)
                guard producedFrames <= maximumOutputFrames else {
                    throw AudioMediaError.invalidMedia("重采样输出漂移超过一个采样帧")
                }
                try appendMapped(samples: samples, frameCount: count,
                                 sourceChannels: outputChannels,
                                 outputChannels: outputChannels, to: &result)
                noProgress = 0
            } else {
                noProgress += 1
                guard noProgress < 8 else {
                    throw AudioMediaError.invalidMedia("PCM 重采样没有继续输出")
                }
            }
            if status == .endOfStream { break }
        }

        guard inputState.state.withLock({ $0.remaining }) == 0,
              abs(Double(producedFrames) - expectedFrames) <= 1,
              result.count == Int(producedFrames) * outputChannels * 4 else {
            throw AudioMediaError.invalidMedia("重采样长度与选区不一致")
        }
        return result
    }

    private static func map(samples: UnsafePointer<UnsafeMutablePointer<Float>>,
                            frameCount: Int, sourceChannels: Int, outputChannels: Int,
                            into destination: UnsafePointer<UnsafeMutablePointer<Float>>) throws {
        for frame in 0..<frameCount {
            if frame & 1_023 == 0 { try Task.checkCancellation() }
            let first = samples[0][frame]
            guard first.isFinite else { throw AudioMediaError.invalidMedia("PCM 包含非有限采样值") }
            if sourceChannels == 1 {
                destination[0][frame] = first
                if outputChannels == 2 { destination[1][frame] = first }
            } else {
                let second = samples[1][frame]
                guard second.isFinite else { throw AudioMediaError.invalidMedia("PCM 包含非有限采样值") }
                if outputChannels == 1 {
                    let sum = first + second
                    let mixed = sum.isFinite ? sum / 2 : first / 2 + second / 2
                    guard mixed.isFinite else {
                        throw AudioMediaError.invalidMedia("声道混合产生非有限采样值")
                    }
                    destination[0][frame] = mixed
                } else {
                    destination[0][frame] = first
                    destination[1][frame] = second
                }
            }
        }
    }

    private static func appendMapped(samples: UnsafePointer<UnsafeMutablePointer<Float>>,
                                     frameCount: Int, sourceChannels: Int,
                                     outputChannels: Int, to data: inout Data) throws {
        var chunk = Data(capacity: frameCount * outputChannels * 4)
        for frame in 0..<frameCount {
            if frame & 1_023 == 0 { try Task.checkCancellation() }
            let first = samples[0][frame]
            guard first.isFinite else { throw AudioMediaError.invalidMedia("PCM 包含非有限采样值") }
            if sourceChannels == 1 {
                append(first, to: &chunk)
                if outputChannels == 2 { append(first, to: &chunk) }
            } else {
                let second = samples[1][frame]
                guard second.isFinite else { throw AudioMediaError.invalidMedia("PCM 包含非有限采样值") }
                if outputChannels == 1 {
                    let sum = first + second
                    let mixed = sum.isFinite ? sum / 2 : first / 2 + second / 2
                    guard mixed.isFinite else {
                        throw AudioMediaError.invalidMedia("声道混合产生非有限采样值")
                    }
                    append(mixed, to: &chunk)
                } else {
                    append(first, to: &chunk)
                    append(second, to: &chunk)
                }
            }
        }
        data.append(chunk)
    }

    private static func append(_ sample: Float, to data: inout Data) {
        var bits = sample.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private static func exactByteCount(frames: Int64, channels: Int) throws -> Int {
        let (sampleCount, sampleOverflow) = frames.multipliedReportingOverflow(by: Int64(channels))
        let (byteCount, byteOverflow) = sampleCount.multipliedReportingOverflow(by: 4)
        guard !sampleOverflow, !byteOverflow, byteCount >= 0, byteCount <= Int64(Int.max) else {
            throw AudioMediaError.limitExceeded
        }
        return Int(byteCount)
    }

    private static func wavHeader(dataBytes: UInt32, sampleRate: UInt32,
                                  channels: UInt16) -> Data {
        let blockAlign = channels * 4
        let byteRate = sampleRate * UInt32(blockAlign)
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        append(UInt32(36) + dataBytes)
        result.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(3)); append(channels); append(sampleRate)
        append(byteRate); append(blockAlign); append(UInt16(32))
        result.append(Data("data".utf8)); append(dataBytes)
        return result
    }
}

private struct WorkflowAudioConversionInput {
    let file: AVAudioFile
    let converterFormat: AVAudioFormat
    let sourceChannels: Int
    let outputChannels: Int
    var remaining: Int64
    var failure: Error?
}

/// AVAudioConverter's escaping callback and its caller share only lock-owned input state.
private final class WorkflowAudioConversionState: Sendable {
    let state: Mutex<WorkflowAudioConversionInput>
    init(_ state: consuming Mutex<WorkflowAudioConversionInput>) { self.state = state }
}
