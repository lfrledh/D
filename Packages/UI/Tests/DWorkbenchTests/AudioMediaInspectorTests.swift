import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DWorkbench

@Suite("Bounded PCM audio inspection")
struct AudioMediaInspectorTests {
    @Test(arguments: ["wav", "caf"])
    func supportedContainersUseActualBytesFramesAndKnownExtrema(extension suffix: String) throws {
        try withAudioFixture { directory in
            let file = directory.appendingPathComponent("组合 空格.\(suffix)")
            let samples: [Float] = [-1, -0.5, 0.25, 1]
            try AudioTestMedia.writePCM(to: file, samples: [samples], sampleRate: 8_000,
                                        bitDepth: 32, floatingPoint: true)
            let bytes = try Data(contentsOf: file)
            let inspection = try AudioMediaInspector.inspect(at: file)
            #expect(inspection.format.container == (suffix == "wav" ? .wav : .caf))
            #expect(inspection.format.frameCount == 4)
            #expect(inspection.format.channelCount == 1)
            #expect(inspection.format.bitDepth == 32)
            #expect(inspection.format.floatingPoint)
            #expect(inspection.contentSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            #expect(inspection.waveform == samples.map { AudioPeak(minimum: $0, maximum: $0) })
        }
    }

    @Test func multichannelWaveformCombinesChannelExtremaIntoBoundedBuckets() throws {
        try withAudioFixture { directory in
            let file = directory.appendingPathComponent("stereo.wav")
            try AudioTestMedia.writePCM(to: file,
                samples: [[-1, 0.1, 0.2, 0.3], [0.5, -0.7, 0.8, -0.9]],
                sampleRate: 8_000, bitDepth: 32, floatingPoint: true)
            let inspection = try AudioMediaInspector.inspect(at: file)
            #expect(inspection.waveform == [
                .init(minimum: -1, maximum: 0.5), .init(minimum: -0.7, maximum: 0.1),
                .init(minimum: 0.2, maximum: 0.8), .init(minimum: -0.9, maximum: 0.3)
            ])
            #expect(inspection.waveform.count <= AudioLimits.maximumWaveformBuckets)
        }
    }

    @Test func rejectsUnsupportedMalformedTruncatedOversizedAndTooLongPayloads() throws {
        try withAudioFixture { directory in
            let nonPCM = directory.appendingPathComponent("not-pcm.wav")
            try AudioTestMedia.writeMinimalWAV(to: nonPCM, formatTag: 6, sampleRate: 8_000,
                                               channels: 1, bits: 8, samples: Data([0]))
            #expect(throws: AudioMediaError.self) { try AudioMediaInspector.inspect(at: nonPCM) }

            let truncated = directory.appendingPathComponent("truncated.wav")
            try AudioTestMedia.writePCM(to: truncated, samples: [[0, 0.5, -0.5]], sampleRate: 8_000,
                                        bitDepth: 32, floatingPoint: true)
            var truncatedBytes = try Data(contentsOf: truncated)
            truncatedBytes.removeLast()
            try truncatedBytes.write(to: truncated)
            #expect(throws: AudioMediaError.self) { try AudioMediaInspector.inspect(at: truncated) }

            let oversized = directory.appendingPathComponent("oversized.wav")
            try Data().write(to: oversized)
            let oversizedHandle = try FileHandle(forWritingTo: oversized)
            try oversizedHandle.truncate(atOffset: UInt64(AudioLimits.maximumBytes + 1))
            try oversizedHandle.close()
            #expect(throws: AudioMediaError.limitExceeded) { try AudioMediaInspector.inspect(at: oversized) }

            let tooLong = directory.appendingPathComponent("too-long.wav")
            let frames = 8_000 * 121
            try AudioTestMedia.writeSparseFloatWAV(to: tooLong, sampleRate: 8_000, channels: 1, frames: frames)
            #expect(throws: AudioMediaError.limitExceeded) { try AudioMediaInspector.inspect(at: tooLong) }
        }
    }

    @Test func rejectsActuallyDeclaredLowSampleRate() throws {
        try withAudioFixture { directory in
            let lowRate = directory.appendingPathComponent("low-rate.wav")
            try AudioTestMedia.writeMinimalWAV(to: lowRate, formatTag: 3, sampleRate: 4_000,
                                               channels: 1, bits: 32,
                                               samples: AudioTestMedia.floatBytes([0, 0]))
            let header = try AudioTestMedia.wavHeaderFacts(at: lowRate)
            #expect(header.formatTag == 3 && header.sampleRate == 4_000)
            #expect(header.channels == 1 && header.bits == 32 && header.dataBytes == 8)
            #expect(throws: AudioMediaError.limitExceeded) { try AudioMediaInspector.inspect(at: lowRate) }
        }
    }

    @Test func rejectsActuallyDeclaredThreeChannelPCM() throws {
        try withAudioFixture { directory in
            let channels = directory.appendingPathComponent("three-channel.wav")
            try AudioTestMedia.writeMinimalWAV(to: channels, formatTag: 3, sampleRate: 8_000,
                                               channels: 3, bits: 32,
                                               samples: AudioTestMedia.floatBytes([0, 0, 0]))
            let header = try AudioTestMedia.wavHeaderFacts(at: channels)
            #expect(header.formatTag == 3 && header.sampleRate == 8_000)
            #expect(header.channels == 3 && header.bits == 32 && header.dataBytes == 12)
            #expect(throws: AudioMediaError.limitExceeded) { try AudioMediaInspector.inspect(at: channels) }
        }
    }

    @Test func rejectsActuallyEncodedNonfiniteFloatSample() throws {
        try withAudioFixture { directory in
            let nonfinite = directory.appendingPathComponent("nonfinite.wav")
            try AudioTestMedia.writeMinimalWAV(to: nonfinite, formatTag: 3, sampleRate: 8_000,
                                               channels: 1, bits: 32,
                                               samples: AudioTestMedia.floatBytes([.nan]))
            let header = try AudioTestMedia.wavHeaderFacts(at: nonfinite)
            #expect(header.formatTag == 3 && header.sampleRate == 8_000)
            #expect(header.channels == 1 && header.bits == 32 && header.dataBytes == 4)
            #expect(throws: AudioMediaError.self) { try AudioMediaInspector.inspect(at: nonfinite) }
        }
    }

    @Test func acceptsActualSignedIntegerAndFloatPCMBitDepthsWithoutMutation() throws {
        try withAudioFixture { directory in
            for bits: UInt16 in [16, 24, 32] {
                let file = directory.appendingPathComponent("signed-\(bits).wav")
                let bytesPerFrame = Int(bits / 8)
                try AudioTestMedia.writeMinimalWAV(to: file, formatTag: 1, sampleRate: 8_000,
                                                   channels: 1, bits: bits,
                                                   samples: Data(repeating: 0, count: bytesPerFrame * 2))
                let original = try Data(contentsOf: file)
                let header = try AudioTestMedia.wavHeaderFacts(at: file)
                #expect(header.formatTag == 1 && header.sampleRate == 8_000)
                #expect(header.channels == 1 && header.bits == bits)
                #expect(header.dataBytes == bytesPerFrame * 2)
                let inspection = try AudioMediaInspector.inspect(at: file)
                #expect(inspection.format.bitDepth == Int(bits))
                #expect(!inspection.format.floatingPoint)
                #expect(inspection.format.frameCount == 2)
                #expect(try Data(contentsOf: file) == original)
            }

            let floating = directory.appendingPathComponent("float32.wav")
            try AudioTestMedia.writeMinimalWAV(to: floating, formatTag: 3, sampleRate: 8_000,
                                               channels: 1, bits: 32,
                                               samples: AudioTestMedia.floatBytes([-0.5, 0.5]))
            let original = try Data(contentsOf: floating)
            let header = try AudioTestMedia.wavHeaderFacts(at: floating)
            #expect(header.formatTag == 3 && header.sampleRate == 8_000)
            #expect(header.channels == 1 && header.bits == 32 && header.dataBytes == 8)
            let inspection = try AudioMediaInspector.inspect(at: floating)
            #expect(inspection.format.bitDepth == 32 && inspection.format.floatingPoint)
            #expect(inspection.format.frameCount == 2)
            #expect(try Data(contentsOf: floating) == original)
        }
    }

    @Test func rejectsSymlinksAndHardlinksWithoutTrustingFilenameExtension() throws {
        try withAudioFixture { directory in
            let original = directory.appendingPathComponent("actual.data")
            try AudioTestMedia.writePCM(to: original, samples: [[0, 0.25]], sampleRate: 8_000,
                                        bitDepth: 32, floatingPoint: true, containerExtension: "wav")
            #expect(try AudioMediaInspector.inspect(at: original).format.container == .wav)
            let alias = directory.appendingPathComponent("alias.wav")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
            #expect(throws: AudioMediaError.self) { try AudioMediaInspector.inspect(at: alias) }
            let hardlink = directory.appendingPathComponent("hardlink.wav")
            try FileManager.default.linkItem(at: original, to: hardlink)
            #expect(throws: AudioMediaError.self) { try AudioMediaInspector.inspect(at: original) }
            #expect(throws: AudioMediaError.self) { try AudioMediaInspector.inspect(at: hardlink) }
        }
    }
}

enum AudioTestMedia {
    static func writePCM(to url: URL, samples: [[Float]], sampleRate: Double,
                         bitDepth: Int, floatingPoint: Bool,
                         containerExtension: String? = nil) throws {
        let channels = samples.count
        let frames = samples.first?.count ?? 0
        precondition(channels > 0 && samples.allSatisfy { $0.count == frames })
        let actualURL: URL
        if let containerExtension {
            actualURL = url.appendingPathExtension(containerExtension)
        } else { actualURL = url }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: floatingPoint, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let processing = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false))
        var writer: AVAudioFile? = try AVAudioFile(forWriting: actualURL, settings: settings,
                                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channelData = try #require(buffer.floatChannelData)
        for channel in 0..<channels {
            for frame in 0..<frames { channelData[channel][frame] = samples[channel][frame] }
        }
        try writer?.write(from: buffer)
        writer = nil
        if actualURL != url { try FileManager.default.moveItem(at: actualURL, to: url) }
    }

    static func writeMinimalWAV(to url: URL, formatTag: UInt16, sampleRate: UInt32,
                                channels: UInt16, bits: UInt16, samples: Data) throws {
        let blockAlign = channels * bits / 8
        var data = Data("RIFF".utf8)
        append(UInt32(36 + samples.count), to: &data)
        data.append(Data("WAVEfmt ".utf8)); append(UInt32(16), to: &data)
        append(formatTag, to: &data); append(channels, to: &data); append(sampleRate, to: &data)
        append(sampleRate * UInt32(blockAlign), to: &data); append(blockAlign, to: &data); append(bits, to: &data)
        data.append(Data("data".utf8)); append(UInt32(samples.count), to: &data); data.append(samples)
        try data.write(to: url)
    }

    static func writeSparseFloatWAV(to url: URL, sampleRate: UInt32, channels: UInt16, frames: Int) throws {
        let bytes = frames * Int(channels) * 4
        try writeMinimalWAV(to: url, formatTag: 3, sampleRate: sampleRate,
                            channels: channels, bits: 32, samples: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndian(UInt32(36 + bytes)))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: littleEndian(UInt32(bytes)))
        try handle.truncate(atOffset: UInt64(44 + bytes))
        try handle.close()
    }

    static func floatBytes(_ values: [Float]) -> Data {
        var result = Data()
        for value in values {
            var bits = value.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
        }
        return result
    }

    static func wavHeaderFacts(at url: URL) throws ->
        (formatTag: UInt16, channels: UInt16, sampleRate: UInt32, bits: UInt16, dataBytes: Int) {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count >= 44, Array(bytes[0..<4]) == Array("RIFF".utf8),
              Array(bytes[8..<12]) == Array("WAVE".utf8),
              Array(bytes[12..<16]) == Array("fmt ".utf8),
              Array(bytes[36..<40]) == Array("data".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (readLittle16(bytes, 20), readLittle16(bytes, 22), readLittle32(bytes, 24),
                readLittle16(bytes, 34), Int(readLittle32(bytes, 40)))
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        data.append(littleEndian(value))
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.littleEndian
        return Swift.withUnsafeBytes(of: &value) { Data($0) }
    }


    private static func readLittle16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readLittle32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

func withAudioFixture(_ body: (URL) throws -> Void) throws {
    let base = ProcessInfo.processInfo.environment["D_TEST_WORKBENCH_ROOT"]
        ?? ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("D-Workbench-Audio-Tests").path
    let directory = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory.resolvingSymlinksInPath())
}
