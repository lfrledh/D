import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import VideoToolbox

@main
@MainActor
private struct VideoMediaChecks {
    private static var checks = 0

    static func main() async throws {
        guard let temporaryPath = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"],
              temporaryPath.hasPrefix("/") else {
            throw CheckFailure("D_TEST_TEMP_DIR must name the approved absolute temporary root.")
        }
        let root = URL(fileURLWithPath: temporaryPath, isDirectory: true)
            .appendingPathComponent("video-media-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { FileHandle.standardError.write(Data("cleanup warning: \(error)\n".utf8)) }
        }

        try await checkFrameCountsAndDurations(root)
        try await checkDifferentFrameRateRejected(root)
        try checkBitRateOverflow()
        try checkWriterDirectoryIdentity(root)
        try await checkRationalTimeColorAndOrientation(root)
        try await checkInputAndDestinationProtection(root)
        try await checkInspectionFailures(root)
        try await checkCancellationTimeoutAndBudgets(root)
        try assertNoStagingDirectories(root)
        print("PASS VideoMediaChecks: \(checks) assertions")
    }

    private static func checkFrameCountsAndDurations(_ root: URL) async throws {
        for count in [1, 2, 17] {
            let directory = try makeDirectory(root, "duration-\(count)")
            let raw = directory.appendingPathComponent("frames.raw")
            let frame = solidFrame(width: 64, height: 64, rgb: (74, 131, 203))
            let sequence = try makeSequence(raw: raw, frames: Array(repeating: frame, count: count),
                                            width: 64, height: 64, numerator: 16, denominator: 1)
            let destination = directory.appendingPathComponent("结果 \(count) 🎞️.mp4")
            let result = try await VideoArtifactWriter.encode(sequence, to: destination, limits: generousLimits)
            try require(result.frameCount == count, "decoded frame count \(count)")
            try require(result.width == 64 && result.height == 64, "reported dimensions \(count)")
            try require(result.codec == "h264", "reported H.264 codec \(count)")
            try require(result.sha256.count == 64 && result.byteCount > 0, "MP4 digest and size \(count)")
            let duration = Double(result.durationNumerator) / Double(result.durationDenominator)
            try require(abs(duration - Double(count) / 16.0) <= 1.0 / 600.0,
                        "complete duration for \(count) frames")
            let again = try await VideoArtifactWriter.inspect(destination, matching: sequence, limits: generousLimits)
            try require(again.sha256 == result.sha256 && again.frameCount == count,
                        "independent public inspect \(count)")
            try require(try digest(raw) == sequence.sha256, "source raw preserved \(count)")
        }
    }

    private static func checkRationalTimeColorAndOrientation(_ root: URL) async throws {
        let directory = try makeDirectory(root, "rational-color")
        let raw = directory.appendingPathComponent("色 彩.raw")
        let width = 64, height = 64
        let colors: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255),
            (0, 0, 0), (255, 255, 255), (128, 128, 128),
        ]
        let exactThreeRaw = directory.appendingPathComponent("exact-three.raw")
        let exactThreeFrames = colors.prefix(3).map { solidFrame(width: width, height: height, rgb: $0) }
        let exactThree = try makeSequence(
            raw: exactThreeRaw,
            frames: exactThreeFrames,
            width: width,
            height: height,
            numerator: 30_000,
            denominator: 1_001
        )
        let exactThreeResult = try await VideoArtifactWriter.encode(
            exactThree,
            to: directory.appendingPathComponent("exact-three-30000-1001.mp4"),
            limits: generousLimits
        )
        let exactThreeDuration = Double(exactThreeResult.durationNumerator)
            / Double(exactThreeResult.durationDenominator)
        try require(exactThreeResult.frameCount == 3, "exact three-frame 30000/1001 count")
        try require(abs(exactThreeDuration - Double(3 * 1_001) / 30_000.0) <= 1.0 / 30_000.0,
                    "exact three-frame 30000/1001 duration")

        var frames = colors.map { solidFrame(width: width, height: height, rgb: $0) }
        frames.append(asymmetricFrame(width: width, height: height))
        let sequence = try makeSequence(raw: raw, frames: frames, width: width, height: height,
                                        numerator: 30_000, denominator: 1_001)
        let destination = directory.appendingPathComponent("rational.mp4")
        let result = try await VideoArtifactWriter.encode(sequence, to: destination, limits: generousLimits)
        let duration = Double(result.durationNumerator) / Double(result.durationDenominator)
        let expected = Double(frames.count * 1_001) / 30_000.0
        try require(abs(duration - expected) <= 1.0 / 30_000.0, "30000/1001 complete rational duration")
        try require(result.fpsNumerator == 30_000 && result.fpsDenominator == 1_001,
                    "30000/1001 report remains rational")
        try require(result.colorInterpretation.contains("Rec.709"), "explicit Rec.709 interpretation")

        let probes = try await decodeProbes(destination)
        try require(probes.count == frames.count, "color fixture decoded frame count")
        for (index, expectedColor) in colors.enumerated() {
            try require(channelDifference(probes[index].center, expectedColor) <= 12,
                        "decoded center color \(index) within 8-bit tolerance")
        }
        let black = probes[3].center.0, gray = probes[5].center.0, white = probes[4].center.0
        try require(black < gray && gray < white, "decoded grayscale remains monotonic")
        let orientation = probes[6]
        try require(channelDifference(orientation.top, (255, 0, 0)) <= 12,
                    "top marker stays red")
        try require(channelDifference(orientation.bottom, (0, 0, 255)) <= 12,
                    "bottom marker stays blue")
    }

    private static func checkDifferentFrameRateRejected(_ root: URL) async throws {
        let directory = try makeDirectory(root, "different-fps")
        let sequence = try makeSequence(raw: directory.appendingPathComponent("frames.raw"),
            frames: [solidFrame(width: 64, height: 64, rgb: (80, 120, 160))],
            width: 64, height: 64, numerator: 16, denominator: 1)
        let output = directory.appendingPathComponent("video.mp4")
        _ = try await VideoArtifactWriter.encode(sequence, to: output, limits: generousLimits)
        let wrong = VideoFrameSequence(rawURL: sequence.rawURL, width: 64, height: 64, frameCount: 1,
                                       fpsNumerator: 32, fpsDenominator: 1, sha256: sequence.sha256)
        try await expectFailure("different fps cannot fit within a whole-frame tolerance") {
            _ = try await VideoArtifactWriter.inspect(output, matching: wrong, limits: generousLimits)
        }
    }

    private static func checkBitRateOverflow() throws {
        do {
            _ = try VideoArtifactWriter.checkedBitRate(pixelCount: 1 << 31, fps: Double(1 << 30))
            throw CheckFailure("2^63 bit rate must throw, never trap or accept")
        } catch is VideoMediaError { checks += 1 }
        try require(try VideoArtifactWriter.checkedBitRate(pixelCount: 4096, fps: 16) == 262144,
                    "normal derived bit rate preserved")
    }

    private static func checkWriterDirectoryIdentity(_ root: URL) throws {
        let parent = try makeDirectory(root, "identity-parent")
        let publication = try VideoPublication(destination: parent.appendingPathComponent("final.mp4"))
        let stableURL = try publication.identityAddressedWriterURL()
        let writer = try AVAssetWriter(outputURL: stableURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
                kVTVideoEncoderSpecification_EncoderID as String: "com.apple.videotoolbox.videoencoder.h264"]])
        writer.add(input)
        // The writer already exists before the name is exchanged. A later URL
        // re-resolution must still address the held directory, not this replacement.
        let moved = root.appendingPathComponent("moved-" + UUID().uuidString)
        try FileManager.default.moveItem(at: parent, to: moved)
        let stagingLeaf = publication.temporaryURL.deletingLastPathComponent().lastPathComponent
        let replacement = parent.appendingPathComponent(stagingLeaf, isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let sentinel = replacement.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        let started = writer.startWriting()
        defer { if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() } }
        // cancelWriting can remove the encoder's unfinished file; inspect the
        // target of the actual write before cancelling this controlled fixture.
        try require(started, "identity-addressed AV writer starts after parent rename")
        try require(FileManager.default.fileExists(atPath: moved.appendingPathComponent(stagingLeaf)
            .appendingPathComponent("video.partial.mp4").path), "AV wrote into the held original directory")
        try require(try FileManager.default.contentsOfDirectory(atPath: replacement.path) == ["sentinel"],
                    "replacement staging directory received no AV file")
        try require(try Data(contentsOf: sentinel) == Data("untouched".utf8), "replacement sentinel unchanged")
    }

    private static func checkInputAndDestinationProtection(_ root: URL) async throws {
        let directory = try makeDirectory(root, "protection")
        let frame = solidFrame(width: 64, height: 64, rgb: (20, 40, 60))
        let raw = directory.appendingPathComponent("source.raw")
        let valid = try makeSequence(raw: raw, frames: [frame, frame], width: 64, height: 64,
                                     numerator: 16, denominator: 1)
        let sourceDigest = try digest(raw)

        var badDigest = valid.sha256
        badDigest.replaceSubrange(badDigest.startIndex...badDigest.startIndex, with: "f")
        if badDigest == valid.sha256 { badDigest.replaceSubrange(badDigest.startIndex...badDigest.startIndex, with: "e") }
        let wrongDigest = VideoFrameSequence(rawURL: raw, width: 64, height: 64, frameCount: 2,
                                             fpsNumerator: 16, fpsDenominator: 1, sha256: badDigest)
        try await expectFailure("wrong raw digest") {
            _ = try await VideoArtifactWriter.encode(wrongDigest,
                to: directory.appendingPathComponent("wrong-digest.mp4"), limits: generousLimits)
        }

        let shortRaw = directory.appendingPathComponent("short.raw")
        try Data(frame.dropLast()).write(to: shortRaw, options: .withoutOverwriting)
        let short = VideoFrameSequence(rawURL: shortRaw, width: 64, height: 64, frameCount: 1,
                                       fpsNumerator: 16, fpsDenominator: 1,
                                       sha256: String(repeating: "0", count: 64))
        try await expectFailure("truncated raw") {
            _ = try await VideoArtifactWriter.encode(short,
                to: directory.appendingPathComponent("short.mp4"), limits: generousLimits)
        }

        let longRaw = directory.appendingPathComponent("long.raw")
        var trailing = frame; trailing.append(1)
        try Data(trailing).write(to: longRaw, options: .withoutOverwriting)
        let long = VideoFrameSequence(rawURL: longRaw, width: 64, height: 64, frameCount: 1,
                                      fpsNumerator: 16, fpsDenominator: 1,
                                      sha256: String(repeating: "0", count: 64))
        try await expectFailure("trailing raw") {
            _ = try await VideoArtifactWriter.encode(long,
                to: directory.appendingPathComponent("long.mp4"), limits: generousLimits)
        }

        let symlink = directory.appendingPathComponent("source-link.raw")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: raw)
        let linked = VideoFrameSequence(rawURL: symlink, width: 64, height: 64, frameCount: 2,
                                        fpsNumerator: 16, fpsDenominator: 1, sha256: valid.sha256)
        try await expectFailure("symbolic-link raw") {
            _ = try await VideoArtifactWriter.encode(linked,
                to: directory.appendingPathComponent("linked.mp4"), limits: generousLimits)
        }

        let existing = directory.appendingPathComponent("existing.mp4")
        let old = Data("do-not-overwrite".utf8)
        try old.write(to: existing, options: .withoutOverwriting)
        try await expectFailure("existing target") {
            _ = try await VideoArtifactWriter.encode(valid, to: existing, limits: generousLimits)
        }
        try require(try Data(contentsOf: existing) == old, "existing target bytes preserved")

        let hardLink = directory.appendingPathComponent("hard-link.mp4")
        try FileManager.default.linkItem(at: raw, to: hardLink)
        try await expectFailure("same-inode hard-link target") {
            _ = try await VideoArtifactWriter.encode(valid, to: hardLink, limits: generousLimits)
        }
        try require(try digest(raw) == sourceDigest, "hard-linked source bytes preserved")

        let targetDirectory = directory.appendingPathComponent("target-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
        try await expectFailure("directory target") {
            _ = try await VideoArtifactWriter.encode(valid, to: targetDirectory, limits: generousLimits)
        }

        let invalid = VideoFrameSequence(rawURL: raw, width: 0, height: 64, frameCount: 2,
                                         fpsNumerator: 16, fpsDenominator: 1, sha256: valid.sha256)
        try await expectFailure("invalid geometry") {
            _ = try await VideoArtifactWriter.encode(invalid,
                to: directory.appendingPathComponent("invalid.mp4"), limits: generousLimits)
        }
        let overflow = VideoFrameSequence(rawURL: raw, width: Int.max, height: Int.max, frameCount: Int.max,
                                          fpsNumerator: 16, fpsDenominator: 1, sha256: valid.sha256)
        try await expectFailure("overflow geometry") {
            _ = try await VideoArtifactWriter.encode(overflow,
                to: directory.appendingPathComponent("overflow.mp4"), limits: generousLimits)
        }
        try require(try digest(raw) == sourceDigest, "all negative input cases preserve source")
    }

    private static func checkInspectionFailures(_ root: URL) async throws {
        let directory = try makeDirectory(root, "inspection")
        let raw = directory.appendingPathComponent("source.raw")
        let frame = solidFrame(width: 64, height: 64, rgb: (90, 100, 110))
        let sequence = try makeSequence(raw: raw, frames: [frame, frame, frame], width: 64, height: 64,
                                        numerator: 16, denominator: 1)
        let mp4 = directory.appendingPathComponent("valid.mp4")
        _ = try await VideoArtifactWriter.encode(sequence, to: mp4, limits: generousLimits)
        let mp4Digest = try digest(mp4)

        let wrongSize = VideoFrameSequence(rawURL: raw, width: 32, height: 64, frameCount: 3,
                                           fpsNumerator: 16, fpsDenominator: 1, sha256: sequence.sha256)
        try await expectFailure("inspect wrong dimensions") {
            _ = try await VideoArtifactWriter.inspect(mp4, matching: wrongSize, limits: generousLimits)
        }
        let wrongCount = VideoFrameSequence(rawURL: raw, width: 64, height: 64, frameCount: 2,
                                            fpsNumerator: 16, fpsDenominator: 1, sha256: sequence.sha256)
        try await expectFailure("inspect wrong frame count") {
            _ = try await VideoArtifactWriter.inspect(mp4, matching: wrongCount, limits: generousLimits)
        }
        let corrupt = directory.appendingPathComponent("corrupt.mp4")
        try Data("not an mp4".utf8).write(to: corrupt, options: .withoutOverwriting)
        try await expectFailure("inspect damaged MP4") {
            _ = try await VideoArtifactWriter.inspect(corrupt, matching: sequence, limits: generousLimits)
        }
        try require(try digest(mp4) == mp4Digest, "failed inspections do not modify MP4")
    }

    private static func checkCancellationTimeoutAndBudgets(_ root: URL) async throws {
        let directory = try makeDirectory(root, "lifecycle")
        let raw = directory.appendingPathComponent("source.raw")
        let frame = solidFrame(width: 256, height: 256, rgb: (30, 80, 130))
        let frames = Array(repeating: frame, count: 60)
        let sequence = try makeSequence(raw: raw, frames: frames, width: 256, height: 256,
                                        numerator: 24, denominator: 1)
        let sourceDigest = try digest(raw)

        let preDestination = directory.appendingPathComponent("pre-cancel.mp4")
        let preCancelled = Task {
            try Task.checkCancellation()
            return try await VideoArtifactWriter.encode(sequence, to: preDestination, limits: generousLimits)
        }
        preCancelled.cancel()
        try await expectCancellation("pre-cancel") { _ = try await preCancelled.value }
        try require(!FileManager.default.fileExists(atPath: preDestination.path), "pre-cancel publishes nothing")

        let midDestination = directory.appendingPathComponent("mid-cancel.mp4")
        let midCancelled = Task {
            try await VideoArtifactWriter.encode(sequence, to: midDestination, limits: generousLimits)
        }
        try await Task.sleep(for: .milliseconds(4))
        midCancelled.cancel()
        try await expectCancellation("in-flight cancel") { _ = try await midCancelled.value }
        try require(!FileManager.default.fileExists(atPath: midDestination.path), "in-flight cancel publishes nothing")

        let timeoutDestination = directory.appendingPathComponent("timeout.mp4")
        let tinyTimeout = VideoMediaLimits(maximumFrameBytes: 1_000_000,
                                           maximumOutputBytes: 50_000_000,
                                           timeoutSeconds: Double.leastNonzeroMagnitude)
        try await expectSpecificFailure("tiny positive timeout", isExpected: {
            if case VideoMediaError.timedOut = $0 { return true }
            return false
        }) {
            _ = try await VideoArtifactWriter.encode(sequence, to: timeoutDestination, limits: tinyTimeout)
        }
        try require(!FileManager.default.fileExists(atPath: timeoutDestination.path), "timeout publishes nothing")

        let frameBudgetDestination = directory.appendingPathComponent("frame-budget.mp4")
        let smallFrameBudget = VideoMediaLimits(maximumFrameBytes: 1,
                                                maximumOutputBytes: 50_000_000,
                                                timeoutSeconds: 30)
        try await expectFailure("raw single-frame budget") {
            _ = try await VideoArtifactWriter.encode(sequence, to: frameBudgetDestination, limits: smallFrameBudget)
        }
        let outputBudgetDestination = directory.appendingPathComponent("output-budget.mp4")
        let smallOutputBudget = VideoMediaLimits(maximumFrameBytes: 1_000_000,
                                                 maximumOutputBytes: 1,
                                                 timeoutSeconds: 30)
        try await expectFailure("output-byte budget") {
            _ = try await VideoArtifactWriter.encode(sequence, to: outputBudgetDestination, limits: smallOutputBudget)
        }
        try require(!FileManager.default.fileExists(atPath: outputBudgetDestination.path), "output budget publishes nothing")
        try require(try digest(raw) == sourceDigest, "lifecycle failures preserve the source")
        try assertNoStagingDirectories(directory)
    }

    private static let generousLimits = VideoMediaLimits(
        maximumFrameBytes: 8_000_000,
        maximumOutputBytes: 50_000_000,
        timeoutSeconds: 60
    )

    private static func makeDirectory(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private static func makeSequence(
        raw: URL,
        frames: [[UInt8]],
        width: Int,
        height: Int,
        numerator: Int32,
        denominator: Int32
    ) throws -> VideoFrameSequence {
        var data = Data()
        for frame in frames { data.append(contentsOf: frame) }
        try data.write(to: raw, options: .withoutOverwriting)
        return VideoFrameSequence(rawURL: raw, width: width, height: height, frameCount: frames.count,
                                  fpsNumerator: numerator, fpsDenominator: denominator,
                                  sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private static func solidFrame(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(width * height * 3)
        for _ in 0..<(width * height) { result.append(contentsOf: [rgb.0, rgb.1, rgb.2]) }
        return result
    }

    private static func asymmetricFrame(width: Int, height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let color: (UInt8, UInt8, UInt8) = y < height / 2 ? (255, 0, 0) : (0, 0, 255)
            for x in 0..<width {
                let offset = (y * width + x) * 3
                result[offset] = color.0; result[offset + 1] = color.1; result[offset + 2] = color.2
            }
        }
        return result
    }

    private struct Probe {
        let center: (UInt8, UInt8, UInt8)
        let top: (UInt8, UInt8, UInt8)
        let bottom: (UInt8, UInt8, UInt8)
    }

    private static func decodeProbes(_ url: URL) async throws -> [Probe] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1 else { throw CheckFailure("probe decoder expected one video track") }
        let output = AVAssetReaderTrackOutput(
            track: tracks[0],
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        )
        let reader = try AVAssetReader(asset: asset)
        guard reader.canAdd(output) else { throw CheckFailure("probe decoder could not add output") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CheckFailure("probe decoder did not start") }
        var result: [Probe] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess,
                  let base = CVPixelBufferGetBaseAddress(image) else {
                throw CheckFailure("probe decoder could not map a frame")
            }
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
            let rowBytes = CVPixelBufferGetBytesPerRow(image)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
                let offset = y * rowBytes + x * 4
                return (bytes[offset + 2], bytes[offset + 1], bytes[offset])
            }
            result.append(Probe(center: rgb(width / 2, height / 2),
                                top: rgb(width / 2, height / 8),
                                bottom: rgb(width / 2, height * 7 / 8)))
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }
        guard reader.status == .completed else { throw reader.error ?? CheckFailure("probe decode failed") }
        return result
    }

    private static func channelDifference(
        _ lhs: (UInt8, UInt8, UInt8),
        _ rhs: (UInt8, UInt8, UInt8)
    ) -> Int {
        max(abs(Int(lhs.0) - Int(rhs.0)), abs(Int(lhs.1) - Int(rhs.1)), abs(Int(lhs.2) - Int(rhs.2)))
    }

    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func assertNoStagingDirectories(_ directory: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try require(!names.contains(where: { $0.hasPrefix(".video-") }), "no private staging directories remain")
    }

    private static func expectFailure(_ name: String, operation: () async throws -> Void) async throws {
        do {
            try await operation()
            throw CheckFailure("\(name) unexpectedly succeeded")
        } catch is CheckFailure { throw CheckFailure("\(name) unexpectedly succeeded") }
        catch { checks += 1 }
    }

    private static func expectSpecificFailure(
        _ name: String,
        isExpected: (Error) -> Bool,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw CheckFailure("\(name) unexpectedly succeeded")
        } catch is CheckFailure { throw CheckFailure("\(name) unexpectedly succeeded") }
        catch {
            guard isExpected(error) else { throw CheckFailure("\(name) returned wrong error: \(error)") }
            checks += 1
        }
    }

    private static func expectCancellation(_ name: String, operation: () async throws -> Void) async throws {
        do {
            try await operation()
            throw CheckFailure("\(name) unexpectedly succeeded")
        } catch is CancellationError { checks += 1 }
        catch { throw CheckFailure("\(name) returned non-cancellation error: \(error)") }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw CheckFailure("assertion failed: \(name)") }
        checks += 1
    }
}

private struct CheckFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
