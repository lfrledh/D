import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import DWorkbench

@Suite("Deterministic workflow audio programs")
struct WorkflowAudioProgramsTests {
    @Test func exactHalfOpenRampUsesSourceFramesAndLeavesSnapshotUnchanged() throws {
        try withWorkflowAudioFixture { directory in
            let source = directory.appendingPathComponent("ramp.wav")
            let ramp = (0..<12).map { Float($0) / 16 }
            try AudioTestMedia.writePCM(to: source, samples: [ramp], sampleRate: 16_000,
                                        bitDepth: 32, floatingPoint: true)
            let original = try Data(contentsOf: source)
            let registered = try workflowAudioMetadata(at: source)

            let output = try WorkflowAudioPrograms.transform(
                at: source, registered: registered,
                range: AudioFrameRange(startFrame: 2, endFrame: 7),
                sampleRate: nil, channels: nil
            )
            let decoded = try inspectAndDecode(output, in: directory, name: "trimmed.wav")
            #expect(decoded.inspection.format.container == .wav)
            #expect(decoded.inspection.format.floatingPoint)
            #expect(decoded.inspection.format.bitDepth == 32)
            #expect(decoded.inspection.format.sampleRate == 16_000)
            #expect(decoded.inspection.format.channelCount == 1)
            #expect(decoded.inspection.format.frameCount == 5)
            #expect(decoded.samples[0] == Array(ramp[2..<7]))
            #expect(try Data(contentsOf: source) == original)
            #expect(try SHA256.hash(data: Data(contentsOf: source)).hex
                    == registered.contentSHA256)
        }
    }

    @Test func rejectsEmptyReversedAndOutOfBoundsRangesWithoutClamping() throws {
        try withWorkflowAudioFixture { directory in
            let source = directory.appendingPathComponent("range.wav")
            try AudioTestMedia.writePCM(to: source, samples: [[0, 0.25, 0.5, 0.75]],
                                        sampleRate: 16_000, bitDepth: 32, floatingPoint: true)
            let registered = try workflowAudioMetadata(at: source)
            let invalid = [
                AudioFrameRange(startFrame: 0, endFrame: 0),
                AudioFrameRange(startFrame: 3, endFrame: 2),
                AudioFrameRange(startFrame: -1, endFrame: 2),
                AudioFrameRange(startFrame: 0, endFrame: 5)
            ]
            for range in invalid {
                #expect(throws: AudioMediaError.invalidRange) {
                    try WorkflowAudioPrograms.transform(at: source, registered: registered,
                                                        range: range, sampleRate: nil,
                                                        channels: nil)
                }
            }
        }
    }

    @Test func rejectsUnapprovedExplicitRatesAndChannelCounts() throws {
        try withWorkflowAudioFixture { directory in
            let source = directory.appendingPathComponent("parameters.wav")
            try AudioTestMedia.writePCM(to: source, samples: [[0, 0.25]], sampleRate: 16_000,
                                        bitDepth: 32, floatingPoint: true)
            let registered = try workflowAudioMetadata(at: source)
            for rate in [0, 8_000, 22_050, 96_000] {
                #expect(throws: AudioMediaError.unsupportedFormat) {
                    try WorkflowAudioPrograms.transform(at: source, registered: registered,
                                                        range: nil, sampleRate: rate,
                                                        channels: nil)
                }
            }
            for channelCount in [0, 3, 8] {
                #expect(throws: AudioMediaError.unsupportedFormat) {
                    try WorkflowAudioPrograms.transform(at: source, registered: registered,
                                                        range: nil, sampleRate: nil,
                                                        channels: channelCount)
                }
            }
        }
    }

    @Test func stereoToMonoIsArithmeticMeanAndMonoToStereoDuplicates() throws {
        try withWorkflowAudioFixture { directory in
            let stereo = directory.appendingPathComponent("stereo.wav")
            let left: [Float] = [0.2, -0.4, 0.8, -0.6]
            let right: [Float] = [0.6, 0.2, -0.2, -0.4]
            try AudioTestMedia.writePCM(to: stereo, samples: [left, right], sampleRate: 16_000,
                                        bitDepth: 32, floatingPoint: true)
            let monoData = try WorkflowAudioPrograms.transform(
                at: stereo, registered: workflowAudioMetadata(at: stereo),
                range: nil, sampleRate: nil, channels: 1
            )
            let mono = try inspectAndDecode(monoData, in: directory, name: "mean.wav")
            #expect(mono.samples == [zip(left, right).map { ($0 + $1) / 2 }])

            let sourceMono = directory.appendingPathComponent("mono.wav")
            let values: [Float] = [-0.75, -0.1, 0.25, 0.9]
            try AudioTestMedia.writePCM(to: sourceMono, samples: [values], sampleRate: 16_000,
                                        bitDepth: 32, floatingPoint: true)
            let stereoData = try WorkflowAudioPrograms.transform(
                at: sourceMono, registered: workflowAudioMetadata(at: sourceMono),
                range: nil, sampleRate: nil, channels: 2
            )
            let duplicated = try inspectAndDecode(stereoData, in: directory, name: "duplicate.wav")
            #expect(duplicated.samples == [values, values])
        }
    }

    @Test(arguments: [(44_100, 16_000), (48_000, 16_000), (16_000, 48_000)])
    func highQualityResamplingPreservesDurationPitchAndUsefulGain(rates: (Int, Int)) throws {
        try withWorkflowAudioFixture { directory in
            let (inputRate, outputRate) = rates
            let source = directory.appendingPathComponent("sine-\(inputRate).wav")
            let frequency = 440.0
            let input = (0..<inputRate).map {
                Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / Double(inputRate)))
            }
            try AudioTestMedia.writePCM(to: source, samples: [input],
                                        sampleRate: Double(inputRate),
                                        bitDepth: 32, floatingPoint: true)
            let output = try WorkflowAudioPrograms.transform(
                at: source, registered: workflowAudioMetadata(at: source),
                range: nil, sampleRate: outputRate, channels: 1
            )
            let decoded = try inspectAndDecode(output, in: directory,
                                               name: "resampled-\(outputRate).wav")
            let samples = decoded.samples[0]
            let expectedFrames = Double(input.count) * Double(outputRate) / Double(inputRate)
            #expect(abs(Double(samples.count) - expectedFrames) <= 1)
            let measuredDuration = Double(samples.count) / Double(outputRate)
            #expect(abs(measuredDuration - 1) <= 1 / Double(outputRate))

            // Crossing count is independent of the converter implementation and is stable
            // for this one-second, phase-known sine. Two hertz allows boundary-filter settling.
            let crossings = zip(samples.dropLast(), samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
            let measuredFrequency = Double(crossings) / measuredDuration
            #expect(abs(measuredFrequency - frequency) <= 2)
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
            // A 0.5 sine has RMS 0.35355; this guards against normalization or material gain loss.
            #expect(abs(rms - 0.35355) < 0.02)
        }
    }

    @Test func resamplingLengthIsBasedOnSelectedFramesNotWholeSource() throws {
        try withWorkflowAudioFixture { directory in
            let source = directory.appendingPathComponent("selected-sine.wav")
            let rate = 44_100
            let input = (0..<rate).map {
                Float(0.4 * sin(2 * Double.pi * 220 * Double($0) / Double(rate)))
            }
            try AudioTestMedia.writePCM(to: source, samples: [input], sampleRate: Double(rate),
                                        bitDepth: 32, floatingPoint: true)
            let output = try WorkflowAudioPrograms.transform(
                at: source, registered: workflowAudioMetadata(at: source),
                range: AudioFrameRange(startFrame: 11_025, endFrame: 33_075),
                sampleRate: 16_000, channels: 1
            )
            let decoded = try inspectAndDecode(output, in: directory, name: "selected.wav")
            #expect(abs(decoded.inspection.format.frameCount - 8_000) <= 1)
            #expect(abs(Double(decoded.inspection.format.frameCount) / 16_000 - 0.5)
                    <= 1.0 / 16_000)
        }
    }

    @Test func fractionalCAFRateRequiresExplicitRepresentableWAVRate() throws {
        try withWorkflowAudioFixture { directory in
            let source = directory.appendingPathComponent("fractional.caf")
            let sourceRate = 44_100.5
            let input = (0..<44_101).map {
                Float(0.4 * sin(2 * Double.pi * 220 * Double($0) / sourceRate))
            }
            try AudioTestMedia.writePCM(to: source, samples: [input], sampleRate: sourceRate,
                                        bitDepth: 32, floatingPoint: true)
            let registered = try workflowAudioMetadata(at: source)
            #expect(registered.format.container == .caf)
            #expect(registered.format.sampleRate == sourceRate)

            #expect(throws: AudioMediaError.invalidMedia(
                "WAV 输出的采样率字段只能表示整数；源采样率为 44100.5 Hz，请显式选择输出采样率"
            )) {
                try WorkflowAudioPrograms.transform(at: source, registered: registered,
                                                    range: nil, sampleRate: nil, channels: nil)
            }

            let output = try WorkflowAudioPrograms.transform(
                at: source, registered: registered, range: nil,
                sampleRate: 16_000, channels: nil
            )
            let decoded = try inspectAndDecode(output, in: directory,
                                               name: "fractional-to-16k.wav")
            #expect(decoded.inspection.format.sampleRate == 16_000)
            let sourceDuration = Double(input.count) / sourceRate
            let outputDuration = Double(decoded.inspection.format.frameCount) / 16_000
            #expect(abs(outputDuration - sourceDuration) <= 1.0 / 16_000)
        }
    }

    @Test func mismatchedRegistrationCorruptAndNonfiniteSourcesAreRejected() throws {
        try withWorkflowAudioFixture { directory in
            let valid = directory.appendingPathComponent("valid.wav")
            try AudioTestMedia.writePCM(to: valid, samples: [[0, 0.25]], sampleRate: 16_000,
                                        bitDepth: 32, floatingPoint: true)
            let registered = try workflowAudioMetadata(at: valid)
            let wrong = AudioAssetMetadata(format: registered.format,
                                           contentSHA256: String(repeating: "0", count: 64),
                                           origin: registered.origin)
            #expect(throws: ProjectStoreError.externalModification) {
                try WorkflowAudioPrograms.transform(at: valid, registered: wrong, range: nil,
                                                    sampleRate: nil, channels: nil)
            }

            let corrupt = directory.appendingPathComponent("corrupt.wav")
            try Data("not audio".utf8).write(to: corrupt)
            #expect(throws: (any Error).self) {
                try WorkflowAudioPrograms.transform(at: corrupt, registered: registered,
                                                    range: nil, sampleRate: nil, channels: nil)
            }

            let nonfinite = directory.appendingPathComponent("nonfinite.wav")
            try AudioTestMedia.writeMinimalWAV(
                to: nonfinite, formatTag: 3, sampleRate: 16_000, channels: 1, bits: 32,
                samples: AudioTestMedia.floatBytes([0, .infinity])
            )
            #expect(throws: (any Error).self) {
                try WorkflowAudioPrograms.transform(at: nonfinite, registered: registered,
                                                    range: nil, sampleRate: nil, channels: nil)
            }
        }
    }

    @Test func rejectsWholeGeneratedSourceLongerThanProgramBudget() throws {
        try withWorkflowAudioFixture { directory in
            let source = directory.appendingPathComponent("121-seconds.wav")
            try AudioTestMedia.writeSparseFloatWAV(to: source, sampleRate: 8_000,
                                                   channels: 1, frames: 8_000 * 121)
            let inspection = try AudioMediaInspector.inspect(at: source, policy: .generated)
            let registered = AudioAssetMetadata(format: inspection.format,
                                                contentSHA256: inspection.contentSHA256,
                                                origin: .modelGenerated)
            #expect(throws: AudioMediaError.limitExceeded) {
                try WorkflowAudioPrograms.transform(at: source, registered: registered,
                                                    range: nil, sampleRate: nil, channels: nil)
            }
        }
    }

    @Test func refusesSymbolicLinkSource() throws {
        try withWorkflowAudioFixture { directory in
            let source = directory.appendingPathComponent("owned.wav")
            try AudioTestMedia.writePCM(to: source, samples: [[0, 0.25]], sampleRate: 16_000,
                                        bitDepth: 32, floatingPoint: true)
            let registered = try workflowAudioMetadata(at: source)
            let alias = directory.appendingPathComponent("alias.wav")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
            #expect(throws: AudioMediaError.self) {
                try WorkflowAudioPrograms.transform(at: alias, registered: registered,
                                                    range: nil, sampleRate: nil, channels: nil)
            }
        }
    }

    @Test func cancelledTaskStopsBeforeReturningOutput() async throws {
        let directory = try makeWorkflowAudioFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("cancel.wav")
        let frames = 48_000 * 8
        let samples = (0..<frames).map { Float($0 & 255) / 512 - 0.25 }
        try AudioTestMedia.writePCM(to: source, samples: [samples], sampleRate: 48_000,
                                    bitDepth: 32, floatingPoint: true)
        let registered = try workflowAudioMetadata(at: source)
        let work = Task {
            try WorkflowAudioPrograms.transform(at: source, registered: registered,
                                                range: nil, sampleRate: 16_000, channels: 1)
        }
        work.cancel()
        do {
            _ = try await work.value
            Issue.record("A cancelled transform returned output")
        } catch is CancellationError {
            // Expected: inspection, decoding, converter callbacks and encoding all cooperate.
        }
    }
}

private struct WorkflowDecodedAudio {
    let inspection: AudioInspection
    let samples: [[Float]]
}

private func workflowAudioMetadata(at url: URL,
                                   origin: AudioOrigin = .importedFile) throws -> AudioAssetMetadata {
    let policy: AudioInspectionPolicy = (origin == .modelGenerated || origin == .programGenerated)
        ? .generated : .original
    let inspection = try AudioMediaInspector.inspect(at: url, policy: policy)
    return AudioAssetMetadata(format: inspection.format,
                              contentSHA256: inspection.contentSHA256, origin: origin)
}

private func inspectAndDecode(_ data: Data, in directory: URL,
                              name: String) throws -> WorkflowDecodedAudio {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: .withoutOverwriting)
    let inspection = try AudioMediaInspector.inspect(at: url, policy: .generated)
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    var samples = [[Float]](repeating: [], count: inspection.format.channelCount)
    for channel in samples.indices {
        samples[channel].reserveCapacity(Int(inspection.format.frameCount))
    }
    var totalFrames: Int64 = 0
    while totalFrames < inspection.format.frameCount {
        let requested = AVAudioFrameCount(min(4_096,
                                              inspection.format.frameCount - totalFrames))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: requested))
        try file.read(into: buffer, frameCount: requested)
        let actual = Int(buffer.frameLength)
        guard actual > 0, actual <= Int(requested),
              let channels = buffer.floatChannelData else {
            throw AudioMediaError.invalidMedia("测试回读在声明帧数前停止")
        }
        for channel in samples.indices {
            samples[channel].append(contentsOf: (0..<actual).map { channels[channel][$0] })
        }
        totalFrames += Int64(actual)
        guard totalFrames <= inspection.format.frameCount else {
            throw AudioMediaError.invalidMedia("测试回读超过声明帧数")
        }
    }
    guard totalFrames == inspection.format.frameCount,
          samples.allSatisfy({ $0.count == Int(inspection.format.frameCount) }) else {
        throw AudioMediaError.invalidMedia("测试回读未覆盖全部声明帧")
    }
    return WorkflowDecodedAudio(inspection: inspection, samples: samples)
}

private func withWorkflowAudioFixture(_ body: (URL) throws -> Void) throws {
    let directory = try makeWorkflowAudioFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func makeWorkflowAudioFixtureDirectory() throws -> URL {
    let root = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.temporaryDirectory
    let directory = root.appendingPathComponent("WorkflowAudioPrograms-\(UUID().uuidString)",
                                                isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.resolvingSymlinksInPath()
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
