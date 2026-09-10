import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Bounded validation for the original PCM formats admitted by HUM1.
public enum AudioMediaInspector {
    public static func inspect(at url: URL, policy: AudioInspectionPolicy = .original) throws -> AudioInspection {
        try AudioSafeFile.withOpen(url, maximumBytes: policy.maximumBytes) { descriptor, identity in
            let contentSHA256 = try AudioSafeFile.sha256(descriptor: descriptor, byteCount: identity.size)
            let layout = try AudioSafeFile.layout(descriptor: descriptor, byteCount: identity.size)
            try validateLayoutLimits(layout, policy: policy)
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = try validatedFormat(file.fileFormat, container: layout.container,
                                             frameCount: file.length, policy: policy)
            guard format.frameCount == layout.frameCount,
                  format.channelCount == layout.channelCount,
                  format.bitDepth == layout.bitDepth,
                  format.floatingPoint == layout.floatingPoint,
                  format.sampleRate == layout.sampleRate else {
                throw AudioMediaError.invalidMedia("容器声明、PCM 数据长度与解码格式不一致")
            }
            let bucketCount = min(AudioLimits.maximumWaveformBuckets, Int(format.frameCount))
            var minima = [Float](repeating: .infinity, count: bucketCount)
            var maxima = [Float](repeating: -.infinity, count: bucketCount)
            var decodedFrames: Int64 = 0

            while decodedFrames < format.frameCount {
                try Task.checkCancellation()
                let requested = AVAudioFrameCount(min(4_096, format.frameCount - decodedFrames))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: requested) else {
                    throw AudioMediaError.invalidMedia("无法分配有界 PCM 解码缓冲区")
                }
                try file.read(into: buffer, frameCount: requested)
                let count = Int(buffer.frameLength)
                guard count > 0, let channels = buffer.floatChannelData else {
                    throw AudioMediaError.invalidMedia("音频在声明的帧数前结束")
                }
                for frame in 0..<count {
                    let absoluteFrame = decodedFrames + Int64(frame)
                    let bucket = min(bucketCount - 1,
                                     Int(absoluteFrame * Int64(bucketCount) / format.frameCount))
                    for channel in 0..<format.channelCount {
                        let sample = channels[channel][frame]
                        guard sample.isFinite else {
                            throw AudioMediaError.invalidMedia("PCM 包含非有限采样值")
                        }
                        minima[bucket] = min(minima[bucket], sample)
                        maxima[bucket] = max(maxima[bucket], sample)
                    }
                }
                decodedFrames += Int64(count)
                guard decodedFrames <= format.frameCount else {
                    throw AudioMediaError.invalidMedia("解码帧数超过格式声明")
                }
            }
            guard decodedFrames == format.frameCount else {
                throw AudioMediaError.invalidMedia("实际帧数与格式声明不符")
            }
            let waveform = zip(minima, maxima).map { AudioPeak(minimum: $0, maximum: $1) }
            return AudioInspection(format: format, contentSHA256: contentSHA256, waveform: waveform)
        }
    }

    /// Inspects one already-owned capture inode without resolving its display URL again.
    /// Captures are frozen to little-endian mono Float32 CAF, so decoding the data chunk
    /// directly also keeps validation and hashing on the exact descriptor supplied by the store.
    struct DescriptorInspection: Sendable {
        let inspection: AudioInspection
        let fingerprint: AudioCaptureFingerprint
    }

    static func inspectCapture(descriptor: Int32) throws -> DescriptorInspection {
        let initialFingerprint = try AudioSafeFile.captureFingerprint(descriptor)
        let identity = try AudioSafeFile.identity(descriptor: descriptor,
                                                  maximumBytes: AudioLimits.maximumBytes)
        let layout = try AudioSafeFile.layout(descriptor: descriptor, byteCount: identity.size)
        try validateLayoutLimits(layout, policy: .original)
        guard layout.container == .caf, layout.channelCount > 0,
              layout.bitDepth == 32, layout.floatingPoint, !layout.bigEndian,
              layout.bytesPerFrame == layout.channelCount * 4 else {
            throw AudioMediaError.invalidMedia("录音不是受支持的 float32 PCM CAF")
        }
        let contentSHA256 = try AudioSafeFile.sha256(descriptor: descriptor,
                                                     byteCount: identity.size)
        let bucketCount = min(AudioLimits.maximumWaveformBuckets, Int(layout.frameCount))
        var minima = [Float](repeating: .infinity, count: bucketCount)
        var maxima = [Float](repeating: -.infinity, count: bucketCount)
        var frame: Int64 = 0
        var bytes = [UInt8](repeating: 0, count: layout.bytesPerFrame * 4_096)
        while frame < layout.frameCount {
            try Task.checkCancellation()
            let frames = min(4_096, Int(layout.frameCount - frame))
            try AudioSafeFile.readExact(descriptor: descriptor,
                                        offset: layout.audioDataOffset + Int(frame) * layout.bytesPerFrame,
                                        into: &bytes, count: frames * layout.bytesPerFrame)
            for index in 0..<frames {
                let absolute = frame + Int64(index)
                let bucket = min(bucketCount - 1,
                                 Int(absolute * Int64(bucketCount) / layout.frameCount))
                for channel in 0..<layout.channelCount {
                    let offset = index * layout.bytesPerFrame + channel * 4
                    let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                        | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                    let sample = Float(bitPattern: bits)
                    guard sample.isFinite else {
                        throw AudioMediaError.invalidMedia("PCM 包含非有限采样值")
                    }
                    minima[bucket] = min(minima[bucket], sample)
                    maxima[bucket] = max(maxima[bucket], sample)
                }
            }
            frame += Int64(frames)
        }
        _ = try AudioSafeFile.identity(descriptor: descriptor,
                                       maximumBytes: AudioLimits.maximumBytes)
        let finalFingerprint = try AudioSafeFile.captureFingerprint(descriptor)
        guard finalFingerprint == initialFingerprint else {
            throw AudioMediaError.unavailable("录音在读取期间发生改变")
        }
        let format = AudioFormatInfo(container: .caf, sampleRate: layout.sampleRate,
                                     channelCount: layout.channelCount,
                                     frameCount: layout.frameCount, bitDepth: layout.bitDepth,
                                     floatingPoint: layout.floatingPoint)
        let inspection = AudioInspection(format: format, contentSHA256: contentSHA256,
                                         waveform: zip(minima, maxima).map {
                                             AudioPeak(minimum: $0.0, maximum: $0.1)
                                         })
        return DescriptorInspection(inspection: inspection, fingerprint: finalFingerprint)
    }

    /// Copies the already-opened selected inode exactly once. Validation is intentionally done
    /// on the owned result, while the source identity is compared before this method returns.
    static func withOriginalSource<T>(at source: URL,
                                      policy: AudioInspectionPolicy = .original,
                                      body: (Int32, Int) throws -> T) throws -> T {
        try AudioSafeFile.withOpen(source, maximumBytes: policy.maximumBytes) { descriptor, identity in
            try body(descriptor, identity.size)
        }
    }

    static func copyOriginal(from source: Int32, byteCount: Int, to destination: Int32) throws {
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while total < byteCount {
            try Task.checkCancellation()
            let count = Darwin.pread(source, &buffer, min(buffer.count, byteCount - total), off_t(total))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw AudioMediaError.io("复制原始音频时提前结束") }
            try buffer.withUnsafeBytes {
                try AudioSafeFile.writeAll(UnsafeRawBufferPointer(rebasing: $0[..<count]), to: destination)
            }
            total += count
        }
        guard total == byteCount else { throw AudioMediaError.io("原始音频复制不完整") }
    }

    /// Writes one validated half-open range as interleaved IEEE float32 WAV without resampling.
    static func writeFloat32WAV(from source: URL, registered: AudioAssetMetadata,
                                range: AudioFrameRange, to descriptor: Int32) throws {
        let inspection = try inspect(at: source)
        guard inspection.format == registered.format,
              inspection.contentSHA256 == registered.contentSHA256 else {
            throw ProjectStoreError.externalModification
        }
        let format = inspection.format
        guard range.startFrame >= 0, range.startFrame < range.endFrame,
              range.endFrame <= format.frameCount else { throw AudioMediaError.invalidRange }
        let roundedRate = format.sampleRate.rounded()
        guard roundedRate == format.sampleRate, roundedRate > 0, roundedRate <= Double(UInt32.max) else {
            throw AudioMediaError.unsupportedFormat
        }
        let frames = range.endFrame - range.startFrame
        let dataBytes64 = frames * Int64(format.channelCount) * 4
        guard dataBytes64 >= 0, dataBytes64 <= Int64(UInt32.max) - 36 else {
            throw AudioMediaError.limitExceeded
        }
        let dataBytes = UInt32(dataBytes64)
        let sampleRate = UInt32(roundedRate)
        let channels = UInt16(format.channelCount)
        let blockAlign = UInt16(format.channelCount * 4)
        let byteRate = sampleRate * UInt32(blockAlign)
        let header = wavHeader(dataBytes: dataBytes, sampleRate: sampleRate, channels: channels,
                               byteRate: byteRate, blockAlign: blockAlign)
        try header.withUnsafeBytes { try AudioSafeFile.writeAll($0, to: descriptor) }

        try AudioSafeFile.withOpen(source, maximumBytes: AudioLimits.maximumBytes) { _, _ in
            let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
            let actual = try validatedFormat(file.fileFormat, container: format.container, frameCount: file.length)
            guard actual == format else { throw AudioMediaError.invalidMedia("导出前音频格式已改变") }
            file.framePosition = range.startFrame
            var writtenFrames: Int64 = 0
            while writtenFrames < frames {
                try Task.checkCancellation()
                let requested = AVAudioFrameCount(min(4_096, frames - writtenFrames))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: requested) else {
                    throw AudioMediaError.io("无法分配导出缓冲区")
                }
                try file.read(into: buffer, frameCount: requested)
                let count = Int(buffer.frameLength)
                guard count > 0, let channelData = buffer.floatChannelData else {
                    throw AudioMediaError.invalidMedia("选定范围无法完整解码")
                }
                var interleaved = Data(capacity: count * format.channelCount * 4)
                for frame in 0..<count {
                    for channel in 0..<format.channelCount {
                        let sample = channelData[channel][frame]
                        guard sample.isFinite else {
                            throw AudioMediaError.invalidMedia("PCM 包含非有限采样值")
                        }
                        var bits = sample.bitPattern.littleEndian
                        Swift.withUnsafeBytes(of: &bits) { interleaved.append(contentsOf: $0) }
                    }
                }
                try interleaved.withUnsafeBytes { try AudioSafeFile.writeAll($0, to: descriptor) }
                writtenFrames += Int64(count)
                guard writtenFrames <= frames else { throw AudioMediaError.invalidMedia("导出帧数超出选区") }
            }
            guard writtenFrames == frames else { throw AudioMediaError.invalidMedia("选区导出不完整") }
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == off_t(44 + dataBytes64) else {
            throw AudioMediaError.io("导出文件长度验证失败")
        }
    }

    private static func validatedFormat(_ audioFormat: AVAudioFormat, container: AudioContainer,
                                        frameCount: Int64,
                                        policy: AudioInspectionPolicy = .original) throws -> AudioFormatInfo {
        let description = audioFormat.streamDescription.pointee
        guard description.mFormatID == kAudioFormatLinearPCM else { throw AudioMediaError.unsupportedFormat }
        let floatingPoint = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signedInteger = description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bitDepth = Int(description.mBitsPerChannel)
        guard (floatingPoint && bitDepth == 32) || (!floatingPoint && signedInteger && [16, 24, 32].contains(bitDepth)) else {
            throw AudioMediaError.unsupportedFormat
        }
        let sampleRate = description.mSampleRate
        let channelCount = Int(description.mChannelsPerFrame)
        guard sampleRate.isFinite, (8_000...96_000).contains(sampleRate),
              channelCount == 1 || channelCount == 2, frameCount > 0 else {
            throw AudioMediaError.limitExceeded
        }
        let duration = Double(frameCount) / sampleRate
        guard duration.isFinite, duration <= policy.maximumSeconds else {
            throw AudioMediaError.limitExceeded
        }
        return AudioFormatInfo(container: container, sampleRate: sampleRate, channelCount: channelCount,
                               frameCount: frameCount, bitDepth: bitDepth, floatingPoint: floatingPoint)
    }

    private static func validateLayoutLimits(_ layout: AudioContainerLayout,
                                             policy: AudioInspectionPolicy) throws {
        guard (layout.floatingPoint && layout.bitDepth == 32) ||
                (!layout.floatingPoint && [16, 24, 32].contains(layout.bitDepth)) else {
            throw AudioMediaError.unsupportedFormat
        }
        guard layout.sampleRate.isFinite, (8_000...96_000).contains(layout.sampleRate),
              layout.channelCount == 1 || layout.channelCount == 2, layout.frameCount > 0 else {
            throw AudioMediaError.limitExceeded
        }
        let duration = Double(layout.frameCount) / layout.sampleRate
        guard duration.isFinite, duration <= policy.maximumSeconds else {
            throw AudioMediaError.limitExceeded
        }
    }

    private static func wavHeader(dataBytes: UInt32, sampleRate: UInt32, channels: UInt16,
                                  byteRate: UInt32, blockAlign: UInt16) -> Data {
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        append(UInt32(36) + dataBytes)
        result.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(3)); append(channels); append(sampleRate)
        append(byteRate); append(blockAlign); append(UInt16(32))
        result.append(Data("data".utf8)); append(dataBytes)
        return result
    }
}

private struct AudioFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    init(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= off_t(Int.max) else {
            throw AudioMediaError.invalidMedia("音频必须是单链接普通文件")
        }
        device = info.st_dev; inode = info.st_ino; size = Int(info.st_size)
        modificationSeconds = Int(info.st_mtimespec.tv_sec)
        modificationNanoseconds = Int(info.st_mtimespec.tv_nsec)
        changeSeconds = Int(info.st_ctimespec.tv_sec)
        changeNanoseconds = Int(info.st_ctimespec.tv_nsec)
    }
}

private struct AudioContainerLayout {
    let container: AudioContainer
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int64
    let bitDepth: Int
    let floatingPoint: Bool
    let audioDataOffset: Int
    let bytesPerFrame: Int
    let bigEndian: Bool
}

private enum AudioSafeFile {
    static func withOpen<T>(_ url: URL, maximumBytes: Int,
                            body: (Int32, AudioFileIdentity) throws -> T) throws -> T {
        let (descriptor, identity) = try open(url)
        defer { Darwin.close(descriptor) }
        guard identity.size <= maximumBytes else { throw AudioMediaError.limitExceeded }
        let result: Result<T, Error>
        do { result = .success(try body(descriptor, identity)) }
        catch { result = .failure(error) }
        let (verification, finalIdentity) = try open(url)
        Darwin.close(verification)
        guard finalIdentity == identity else { throw AudioMediaError.unavailable("所选音频在读取期间发生改变") }
        return try result.get()
    }

    static func layout(descriptor: Int32, byteCount: Int) throws -> AudioContainerLayout {
        let signature = try readExact(descriptor, offset: 0, count: min(12, byteCount))
        guard signature.count >= 4 else { throw AudioMediaError.invalidMedia("文件头不完整") }
        if signature.count >= 12, Array(signature[0..<4]) == Array("RIFF".utf8),
           Array(signature[8..<12]) == Array("WAVE".utf8) {
            return try wavLayout(descriptor, byteCount: byteCount, header: signature)
        }
        if Array(signature[0..<4]) == Array("caff".utf8) {
            return try cafLayout(descriptor, byteCount: byteCount)
        }
        throw AudioMediaError.unsupportedFormat
    }

    private static func wavLayout(_ descriptor: Int32, byteCount: Int,
                                  header: [UInt8]) throws -> AudioContainerLayout {
        guard byteCount >= 12, Int(little32(header, 4)) + 8 == byteCount else {
            throw AudioMediaError.invalidMedia("RIFF 声明长度与文件长度不一致")
        }
        var offset = 12
        var format: (Double, Int, Int, Bool, Int)?
        var dataBytes: Int?
        while offset < byteCount {
            guard byteCount - offset >= 8 else { throw AudioMediaError.invalidMedia("WAV 数据块头被截断") }
            let chunk = try readExact(descriptor, offset: offset, count: 8)
            let size = Int(little32(chunk, 4))
            let payload = offset + 8
            guard size <= byteCount - payload else { throw AudioMediaError.invalidMedia("WAV 数据块被截断") }
            let type = String(bytes: chunk[0..<4], encoding: .ascii)
            if type == "fmt " {
                guard format == nil, size >= 16 else { throw AudioMediaError.invalidMedia("WAV fmt 数据块无效") }
                let bytes = try readExact(descriptor, offset: payload, count: min(size, 40))
                var tag = little16(bytes, 0)
                let channels = Int(little16(bytes, 2))
                let rate = little32(bytes, 4)
                let byteRate = little32(bytes, 8)
                let blockAlign = Int(little16(bytes, 12))
                let bits = Int(little16(bytes, 14))
                if tag == 0xfffe {
                    guard size >= 40, bytes.count >= 40 else { throw AudioMediaError.invalidMedia("WAV extensible fmt 被截断") }
                    tag = little16(bytes, 24)
                }
                guard tag == 1 || tag == 3, channels > 0, rate > 0, bits > 0,
                      blockAlign == channels * ((bits + 7) / 8),
                      UInt64(byteRate) == UInt64(rate) * UInt64(blockAlign) else {
                    throw AudioMediaError.unsupportedFormat
                }
                format = (Double(rate), channels, bits, tag == 3, blockAlign)
            } else if type == "data" {
                guard dataBytes == nil else { throw AudioMediaError.invalidMedia("WAV 包含多个 PCM data 数据块") }
                dataBytes = size
            }
            let padding = size & 1
            guard payload + size + padding <= byteCount else { throw AudioMediaError.invalidMedia("WAV 数据块填充被截断") }
            offset = payload + size + padding
        }
        guard offset == byteCount, let format, let dataBytes, dataBytes > 0,
              dataBytes % format.4 == 0 else { throw AudioMediaError.invalidMedia("WAV PCM 帧未完整对齐") }
        return .init(container: .wav, sampleRate: format.0, channelCount: format.1,
                     frameCount: Int64(dataBytes / format.4), bitDepth: format.2,
                     floatingPoint: format.3, audioDataOffset: 0,
                     bytesPerFrame: format.4, bigEndian: false)
    }

    private static func cafLayout(_ descriptor: Int32, byteCount: Int) throws -> AudioContainerLayout {
        guard byteCount >= 8 else { throw AudioMediaError.invalidMedia("CAF 文件头被截断") }
        var offset = 8
        var format: (Double, Int, Int, Bool, Int, Int, Bool)?
        var audioBytes: Int?
        var audioDataOffset: Int?
        while offset < byteCount {
            guard byteCount - offset >= 12 else { throw AudioMediaError.invalidMedia("CAF 数据块头被截断") }
            let chunk = try readExact(descriptor, offset: offset, count: 12)
            let type = String(bytes: chunk[0..<4], encoding: .ascii)
            let unsignedSize = big64(chunk, 4)
            guard unsignedSize <= UInt64(byteCount - offset - 12) else {
                throw AudioMediaError.invalidMedia("CAF 数据块声明长度无效或被截断")
            }
            let size = Int(unsignedSize)
            let payload = offset + 12
            if type == "desc" {
                guard format == nil, size == 32 else { throw AudioMediaError.invalidMedia("CAF desc 数据块无效") }
                let bytes = try readExact(descriptor, offset: payload, count: 32)
                let rate = Double(bitPattern: big64(bytes, 0))
                let formatID = String(bytes: bytes[8..<12], encoding: .ascii)
                let flags = big32(bytes, 12)
                let bytesPerPacket = Int(big32(bytes, 16))
                let framesPerPacket = Int(big32(bytes, 20))
                let channels = Int(big32(bytes, 24))
                let bits = Int(big32(bytes, 28))
                guard formatID == "lpcm", bytesPerPacket > 0, framesPerPacket > 0,
                      channels > 0, bits > 0 else { throw AudioMediaError.unsupportedFormat }
                // CAF LPCM uses bit 1 for LITTLE endian; ASBD uses that bit for BIG endian.
                // CAFFile.h / Apple CAF specification define these container masks as 1 and 2.
                format = (rate, channels, bits, flags & 1 != 0,
                          bytesPerPacket, framesPerPacket, flags & 2 == 0)
            } else if type == "data" {
                guard audioBytes == nil, size >= 4 else { throw AudioMediaError.invalidMedia("CAF data 数据块无效") }
                audioBytes = size - 4
                audioDataOffset = payload + 4
            }
            offset = payload + size
        }
        guard offset == byteCount, let format, let audioBytes, let audioDataOffset, audioBytes > 0,
              format.4 % format.5 == 0,
              format.4 / format.5 == format.1 * ((format.2 + 7) / 8),
              audioBytes % format.4 == 0 else {
            throw AudioMediaError.invalidMedia("CAF PCM 帧未完整对齐")
        }
        let packets = audioBytes / format.4
        guard packets <= Int(Int64.max) / format.5 else { throw AudioMediaError.limitExceeded }
        return .init(container: .caf, sampleRate: format.0, channelCount: format.1,
                     frameCount: Int64(packets * format.5), bitDepth: format.2,
                     floatingPoint: format.3, audioDataOffset: audioDataOffset,
                     bytesPerFrame: format.4 / format.5,
                     bigEndian: format.6)
    }

    private static func readExact(_ descriptor: Int32, offset: Int, count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw AudioMediaError.invalidMedia("无效读取长度") }
        var result = [UInt8](repeating: 0, count: count)
        var completed = 0
        while completed < count {
            let readCount = result.withUnsafeMutableBytes { raw in
                Darwin.pread(descriptor, raw.baseAddress!.advanced(by: completed), count - completed,
                             off_t(offset + completed))
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { throw AudioMediaError.invalidMedia("容器结构被截断") }
            completed += readCount
        }
        return result
    }

    static func readExact(descriptor: Int32, offset: Int,
                          into buffer: inout [UInt8], count: Int) throws {
        guard count >= 0, count <= buffer.count else {
            throw AudioMediaError.invalidMedia("无效读取长度")
        }
        var completed = 0
        while completed < count {
            let readCount = buffer.withUnsafeMutableBytes { raw in
                Darwin.pread(descriptor, raw.baseAddress!.advanced(by: completed), count - completed,
                             off_t(offset + completed))
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { throw AudioMediaError.invalidMedia("容器结构被截断") }
            completed += readCount
        }
    }

    static func identity(descriptor: Int32, maximumBytes: Int) throws -> AudioFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AudioMediaError.io(String(cString: strerror(errno)))
        }
        let identity = try AudioFileIdentity(info)
        guard identity.size <= maximumBytes else { throw AudioMediaError.limitExceeded }
        return identity
    }

    static func captureFingerprint(_ descriptor: Int32) throws -> AudioCaptureFingerprint {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AudioMediaError.io(String(cString: strerror(errno)))
        }
        return AudioCaptureFingerprint(info)
    }

    private static func little16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func little32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    private static func big32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
    private static func big64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[offset + $1]) }
    }

    static func sha256(descriptor: Int32, byteCount: Int) throws -> String {
        var hasher = SHA256()
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < byteCount {
            try Task.checkCancellation()
            let count = Darwin.pread(descriptor, &buffer, min(buffer.count, byteCount - offset), off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw AudioMediaError.invalidMedia("读取原始字节时提前结束") }
            hasher.update(data: Data(buffer[..<count]))
            offset += count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw AudioMediaError.io(String(cString: strerror(errno))) }
            offset += count
        }
    }

    private static func open(_ url: URL) throws -> (Int32, AudioFileIdentity) {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty,
              url.standardizedFileURL.path == url.path else { throw AudioMediaError.unavailable("文件路径不安全") }
        let components = url.path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw AudioMediaError.unavailable("文件路径不安全")
        }
        var current = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw AudioMediaError.io(String(cString: strerror(errno))) }
        for component in components.dropLast() {
            let next = openat(current, component, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            Darwin.close(current)
            guard next >= 0 else {
                if failure == ELOOP || failure == ENOTDIR { throw AudioMediaError.unavailable("文件路径包含符号链接") }
                throw AudioMediaError.io(String(cString: strerror(failure)))
            }
            current = next
        }
        let descriptor = openat(current, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let failure = errno
        Darwin.close(current)
        guard descriptor >= 0 else {
            if failure == ELOOP { throw AudioMediaError.unavailable("文件路径包含符号链接") }
            throw AudioMediaError.io(String(cString: strerror(failure)))
        }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw AudioMediaError.io(String(cString: strerror(errno))) }
            return (descriptor, try AudioFileIdentity(info))
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}
