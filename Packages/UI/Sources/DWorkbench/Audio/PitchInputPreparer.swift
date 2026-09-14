import AVFoundation
import CryptoKit
import DInference
import Foundation
import Synchronization

/// Converts only an explicitly selected interval of an already-owned original snapshot.
/// This derived input never replaces the original. No normalization or pitch correction.
public enum PitchInputPreparer {
    public static func prepare(at snapshot: URL, source: PitchSourceIdentity) throws -> Data {
        try source.validate()
        let before = try AudioMediaInspector.inspect(at: snapshot)
        guard before.contentSHA256 == source.contentSHA256,
              before.format.sampleRate == source.sampleRate, before.format.frameCount == source.frameCount,
              before.format.channelCount == 1 else {
            throw AudioMediaError.invalidMedia("本识别配置只接收已验证的单声部单声道原声；原件未改变")
        }
        let expected = Double(source.endFrame - source.startFrame) * 16000 / source.sampleRate
        guard expected >= 256, expected <= 1_920_000 else { throw AudioMediaError.limitExceeded }
        let file = try AVAudioFile(forReading: snapshot, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                        channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            throw AudioMediaError.unavailable("无法准备16kHz音高分析输入")
        }
        converter.primeMethod = .normal
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        file.framePosition = source.startFrame
        let inputState = Mutex(PitchConversionInput(file: file, remaining: source.endFrame - source.startFrame))
        var bytes = Data(), noProgress = 0
        let maximumOutput = Int(expected.rounded(.up)) + 1
        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, status in
                inputState.withLock { state in
                    if state.failure != nil || state.remaining == 0 { status.pointee = .endOfStream; return nil }
                    do {
                        try Task.checkCancellation()
                        let frames = AVAudioFrameCount(min(Int64(requested), min(4096, state.remaining)))
                        guard let input = AVAudioPCMBuffer(pcmFormat: state.file.processingFormat, frameCapacity: frames) else {
                            throw AudioMediaError.unavailable("无法分配分析输入缓冲")
                        }
                        try state.file.read(into: input, frameCount: frames)
                        guard input.frameLength > 0 else { throw AudioMediaError.invalidMedia("原声在选区结束前中断") }
                        state.remaining -= Int64(input.frameLength)
                        status.pointee = .haveData
                        return input
                    } catch { state.failure = error; status.pointee = .endOfStream; return nil }
                }
            }
            if let failure = inputState.withLock({ $0.failure }) { throw failure }
            if let conversionError { throw AudioMediaError.io(conversionError.localizedDescription) }
            guard status != .error else { throw AudioMediaError.invalidMedia("分析重采样失败") }
            let count = Int(output.frameLength)
            guard bytes.count / 4 + count <= maximumOutput, let channel = output.floatChannelData?[0] else {
                throw AudioMediaError.invalidMedia("Converter produced \(bytes.count / 4)+\(count) samples; expected \(expected), status \(status.rawValue)")
            }
            for i in 0..<count {
                let value = channel[i]
                guard value.isFinite else { throw AudioMediaError.invalidMedia("分析输入包含非有限值") }
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            noProgress = count == 0 ? noProgress + 1 : 0
            guard noProgress < 8 else { throw AudioMediaError.invalidMedia("分析重采样没有继续输出") }
            if status == .endOfStream { break }
        }
        guard inputState.withLock({ $0.remaining }) == 0, abs(Double(bytes.count / 4) - expected) <= 1,
              bytes.count / 4 >= 256, bytes.count / 4 <= 1_920_000 else {
            throw AudioMediaError.invalidMedia("分析重采样长度与原帧范围不一致")
        }
        let after = try AudioMediaInspector.inspect(at: snapshot)
        guard after.contentSHA256 == before.contentSHA256, after.format == before.format else {
            throw ProjectStoreError.externalModification
        }
        return bytes
    }
}

// The converter callback and its caller access one explicit lock-owned input state.
private struct PitchConversionInput {
    let file: AVAudioFile
    var remaining: Int64
    var failure: Error?
}
