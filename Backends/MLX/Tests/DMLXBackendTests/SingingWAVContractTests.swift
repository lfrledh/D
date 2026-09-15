import CryptoKit
import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("Mono singing output and stereo compatibility", .serialized)
struct SingingWAVContractTests {
    private func withWAV(channels: Int, samples: [Float],
                         body: (URL, AudioProviderArtifact) throws -> Void) throws {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("singing-wav-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = Data()
        func tag(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { for shift in [0, 8, 16, 24] { data.append(UInt8((value >> shift) & 255)) } }
        tag("RIFF"); u32(UInt32(36 + samples.count * 4)); tag("WAVEfmt "); u32(16)
        u16(3); u16(UInt16(channels)); u32(44_100); u32(UInt32(44_100 * channels * 4))
        u16(UInt16(channels * 4)); u16(32); tag("data"); u32(UInt32(samples.count * 4))
        samples.forEach { u32($0.bitPattern) }
        let url = root.appendingPathComponent("output.wav")
        try data.write(to: url, options: .withoutOverwriting)
        let claim = AudioProviderArtifact(path: url.path,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(data.count), frameCount: Int64(samples.count / channels),
            sampleRate: 44_100, channels: channels, encoding: "float32")
        try body(url, claim)
    }

    @Test("Mono requires explicit selection; old stereo defaults remain")
    func channelsAreExplicit() throws {
        try withWAV(channels: 1, samples: [0.1, -0.2]) { url, claim in
            _ = try AudioWAV.validateOutput(url, claim: claim, expectedFrames: 2, expectedChannels: 1, requireNonzero: true)
            #expect(throws: (any Error).self) { try AudioWAV.validateOutput(url, claim: claim, expectedFrames: 2) }
        }
        try withWAV(channels: 2, samples: [0.1, -0.2, 0, 0]) { url, claim in
            _ = try AudioWAV.validateOutput(url, claim: claim, expectedFrames: 2)
            #expect(throws: (any Error).self) {
                try AudioWAV.validateOutput(url, claim: claim, expectedFrames: 2, expectedChannels: 1)
            }
        }
    }

    @Test("Singing silence check does not change existing silent stereo policy")
    func silenceIsOptIn() throws {
        try withWAV(channels: 1, samples: [0, -0]) { url, claim in
            #expect(throws: (any Error).self) {
                try AudioWAV.validateOutput(url, claim: claim, expectedFrames: 2, expectedChannels: 1, requireNonzero: true)
            }
        }
        try withWAV(channels: 2, samples: [0, 0, 0, 0]) { url, claim in
            _ = try AudioWAV.validateOutput(url, claim: claim, expectedFrames: 2)
        }
    }

    @Test("Nonfinite samples and unreasonable frame counts never pass")
    func invalidOutput() throws {
        try withWAV(channels: 1, samples: [.nan, 0.2]) { url, claim in
            #expect(throws: (any Error).self) {
                try AudioWAV.validateOutput(url, claim: claim, expectedFrames: 2, expectedChannels: 1)
            }
        }
        try withWAV(channels: 1, samples: [0.2]) { url, claim in
            for frames: Int64 in [0, .max] {
                #expect(throws: (any Error).self) {
                    try AudioWAV.validateOutput(url, claim: claim, expectedFrames: frames, expectedChannels: 1)
                }
            }
        }
    }
}
