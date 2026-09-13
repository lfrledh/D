import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import VideoToolbox

/// CPU media delivery for a completed, private RGB8 frame spool.
///
/// The writer owns every AVFoundation object for the full operation. A successful return means
/// that encoding, a separate decode pass, and exclusive publication have all completed.
internal enum VideoArtifactWriter {
    static func encode(
        _ sequence: VideoFrameSequence,
        to destination: URL,
        limits: VideoMediaLimits
    ) async throws -> VideoMediaInspection {
        let policy = try ValidatedVideoPolicy(sequence: sequence, limits: limits)
        let deadline = try Deadline(seconds: limits.timeoutSeconds)
        let source = try AnchoredReadFile(url: sequence.rawURL, expectedSize: policy.totalBytes, purpose: "frame spool")
        let publication = try VideoPublication(destination: destination)
        var writer: AVAssetWriter?

        do {
            try deadline.check()
            let temporaryURL = publication.temporaryURL
            let assetWriter = try AVAssetWriter(outputURL: try publication.identityAddressedWriterURL(), fileType: .mp4)
            writer = assetWriter
            assetWriter.shouldOptimizeForNetworkUse = false
            assetWriter.movieTimeScale = sequence.fpsNumerator

            let settings = try videoSettings(sequence: sequence, policy: policy)
            guard assetWriter.canApply(outputSettings: settings, forMediaType: .video) else {
                throw VideoMediaError.encoding("The software H.264 encoder rejected the requested geometry or time base.")
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            // Preserve q/p frame durations in the media track itself, including 1001/30000.
            // movieTimeScale alone controls the container timeline, not this track's sample table.
            input.mediaTimeScale = sequence.fpsNumerator
            guard assetWriter.canAdd(input) else {
                throw VideoMediaError.encoding("Could not add the single video track to the MP4 writer.")
            }
            assetWriter.add(input)

            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: sequence.width,
                kCVPixelBufferHeightKey as String: sequence.height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferMetalCompatibilityKey as String: false,
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: attributes
            )

            let started = assetWriter.startWriting()
            // startWriting() creates the output even when encoder startup subsequently fails.
            // Record that exclusively-created inode before interpreting the result.
            let capturedOutput = try publication.captureTemporaryIdentityIfPresent()
            guard !started || capturedOutput else {
                throw VideoMediaError.verification("The started encoder did not create the expected private regular file.")
            }
            guard started else {
                throw VideoMediaError.encoding(writerMessage(assetWriter, fallback: "Could not start MP4 encoding."))
            }
            assetWriter.startSession(atSourceTime: .zero)

            var hasher = SHA256()
            for index in 0..<sequence.frameCount {
                try await waitUntilReady(input: input, writer: assetWriter, publication: publication,
                                         outputLimit: limits.maximumOutputBytes, deadline: deadline)
                let rgb = try source.readExactly(policy.frameBytes)
                hasher.update(data: rgb)
                let pixelBuffer = try makePixelBuffer(rgb: rgb, sequence: sequence, policy: policy)
                let presentationTime = CMTime(
                    value: try checkedTimelineValue(index: index, denominator: sequence.fpsDenominator),
                    timescale: sequence.fpsNumerator
                )
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw VideoMediaError.encoding(writerMessage(assetWriter, fallback: "The H.264 encoder rejected a frame."))
                }
                try publication.checkTemporarySize(maximum: limits.maximumOutputBytes)
                try deadline.check()
                await Task.yield()
            }

            try source.requireEndOfFile()
            try source.validateUnchanged()
            let actualRawDigest = Self.hexDigest(hasher.finalize())
            guard actualRawDigest == sequence.sha256 else {
                throw VideoMediaError.verification("Frame spool SHA-256 changed or did not match the submitted digest.")
            }

            let endTime = CMTime(
                value: try checkedTimelineValue(index: sequence.frameCount, denominator: sequence.fpsDenominator),
                timescale: sequence.fpsNumerator
            )
            assetWriter.endSession(atSourceTime: endTime)
            input.markAsFinished()
            try await finish(writer: assetWriter, deadline: deadline)
            guard assetWriter.status == .completed else {
                throw VideoMediaError.encoding(writerMessage(assetWriter, fallback: "MP4 encoding did not complete."))
            }
            try publication.validateCompletedTemporary(maximum: limits.maximumOutputBytes)
            try source.validateUnchanged()

            // This is deliberately a new AVAssetReader pass, not an AVAssetWriter status check.
            let inspection = try await inspectVerified(
                temporaryURL,
                matching: sequence,
                limits: limits,
                deadline: deadline
            )
            try source.validateUnchanged()
            try deadline.check()
            try publication.publish(expectedSHA256: inspection.sha256, deadline: deadline)
            return inspection
        } catch is CancellationError {
            if let writer { cancelAndDrain(writer) }
            writer = nil
            try publication.cleanupUnpublished()
            throw CancellationError()
        } catch let error as VideoMediaError {
            if let writer, writer.status == .writing { cancelAndDrain(writer) }
            writer = nil
            do {
                try publication.cleanupUnpublished()
            } catch let cleanupError {
                throw VideoMediaError.io("\(error.localizedDescription) Cleanup also failed: \(cleanupError.localizedDescription)")
            }
            throw error
        } catch {
            if let writer, writer.status == .writing { cancelAndDrain(writer) }
            writer = nil
            let original = error
            do {
                try publication.cleanupUnpublished()
            } catch {
                throw VideoMediaError.io("\(original.localizedDescription) Cleanup also failed: \(error.localizedDescription)")
            }
            throw VideoMediaError.encoding(error.localizedDescription)
        }
    }

    static func inspect(
        _ url: URL,
        matching sequence: VideoFrameSequence,
        limits: VideoMediaLimits
    ) async throws -> VideoMediaInspection {
        _ = try ValidatedVideoPolicy(sequence: sequence, limits: limits)
        let deadline = try Deadline(seconds: limits.timeoutSeconds)
        return try await inspectVerified(url, matching: sequence, limits: limits, deadline: deadline)
    }

    private static func videoSettings(
        sequence: VideoFrameSequence,
        policy: ValidatedVideoPolicy
    ) throws -> [String: Any] {
        let fps = Double(sequence.fpsNumerator) / Double(sequence.fpsDenominator)
        let bitRate = try checkedBitRate(pixelCount: policy.pixelCount, fps: fps)
        let softwareEncoderID = try softwareH264EncoderID()
        let encoderSpecification: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
            kVTVideoEncoderSpecification_EncoderID as String: softwareEncoderID,
        ]
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoMaxKeyFrameIntervalKey: sequence.frameCount,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: sequence.width,
            AVVideoHeightKey: sequence.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: color,
            AVVideoEncoderSpecificationKey: encoderSpecification,
        ]
    }

    static func checkedBitRate(pixelCount: Int, fps: Double) throws -> Int {
        let derived = Double(pixelCount) * fps * 4
        guard pixelCount > 0, fps.isFinite, fps > 0, derived.isFinite, derived >= 1,
              let result = Int(exactly: derived.rounded(.up)) else {
            throw VideoMediaError.invalidInput("The derived H.264 bit rate is not representable.")
        }
        return result
    }

    private static func softwareH264EncoderID() throws -> String {
        var copied: CFArray?
        let status = VTCopyVideoEncoderList(nil, &copied)
        guard status == noErr, let encoders = copied as? [[String: Any]] else {
            throw VideoMediaError.encoding("Could not enumerate VideoToolbox encoders (OSStatus \(status)).")
        }
        for encoder in encoders {
            let codec = (encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value
            let hardware = (encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue ?? false
            if codec == kCMVideoCodecType_H264, !hardware,
               let identifier = encoder[kVTVideoEncoderList_EncoderID as String] as? String {
                return identifier
            }
        }
        throw VideoMediaError.encoding("No software H.264 encoder is available; hardware encoding remains disabled.")
    }

    private static func makePixelBuffer(
        rgb: Data,
        sequence: VideoFrameSequence,
        policy: ValidatedVideoPolicy
    ) throws -> CVPixelBuffer {
        guard rgb.count == policy.frameBytes else {
            throw VideoMediaError.io("A complete RGB8 frame could not be read.")
        }
        var optional: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: false,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            sequence.width,
            sequence.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &optional
        )
        guard status == kCVReturnSuccess, let pixelBuffer = optional else {
            throw VideoMediaError.encoding("Could not allocate a CPU pixel buffer (CVReturn \(status)).")
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw VideoMediaError.encoding("Could not map the CPU pixel buffer.")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard bytesPerRow >= policy.bgraRowBytes,
              bytesPerRow <= Int.max / sequence.height else {
            throw VideoMediaError.encoding("The pixel-buffer row allocation is not representable.")
        }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        rgb.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            for y in 0..<sequence.height {
                let sourceRow = y * policy.rgbRowBytes
                let destinationRow = y * bytesPerRow
                for x in 0..<sequence.width {
                    let s = sourceRow + x * 3
                    let d = destinationRow + x * 4
                    destination[d] = source[s + 2]
                    destination[d + 1] = source[s + 1]
                    destination[d + 2] = source[s]
                    destination[d + 3] = 255
                }
            }
        }
        return pixelBuffer
    }

    private static func waitUntilReady(
        input: AVAssetWriterInput,
        writer: AVAssetWriter,
        publication: VideoPublication,
        outputLimit: UInt64,
        deadline: Deadline
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try deadline.check()
            try publication.checkTemporarySize(maximum: outputLimit)
            if writer.status == .failed || writer.status == .cancelled {
                throw VideoMediaError.encoding(writerMessage(writer, fallback: "The video encoder stopped before accepting all frames."))
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        try deadline.check()
    }

    private static func finish(writer: AVAssetWriter, deadline: Deadline) async throws {
        let completion = FinishSignal()
        writer.finishWriting {
            Task { await completion.finish() }
        }
        do {
            while !(await completion.isFinished()) {
                try deadline.check()
                if writer.status == .failed || writer.status == .cancelled { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            try deadline.check()
        } catch {
            cancelAndDrain(writer)
            throw error
        }
    }

    private static func cancelAndDrain(_ writer: AVAssetWriter) {
        if writer.status == .writing || writer.status == .unknown {
            writer.cancelWriting()
        }
        var pause = timespec(tv_sec: 0, tv_nsec: 1_000_000)
        while writer.status == .writing || writer.status == .unknown {
            _ = nanosleep(&pause, nil)
        }
    }

    private static func inspectVerified(
        _ url: URL,
        matching sequence: VideoFrameSequence,
        limits: VideoMediaLimits,
        deadline: Deadline
    ) async throws -> VideoMediaInspection {
        let file = try AnchoredReadFile(url: url, maximumSize: limits.maximumOutputBytes, purpose: "MP4")
        guard file.size > 0 else { throw VideoMediaError.verification("The MP4 is empty.") }
        let digest = try file.sha256(deadline: deadline)
        try file.validateUnchanged()
        try deadline.check()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try deadline.check()
        guard videoTracks.count == 1, audioTracks.isEmpty else {
            throw VideoMediaError.verification("Expected exactly one video track and no audio tracks.")
        }
        let track = videoTracks[0]
        let descriptions = try await track.load(.formatDescriptions)
        let transform = try await track.load(.preferredTransform)
        let trackTimeRange = try await track.load(.timeRange)
        let assetDuration = try await asset.load(.duration)
        try deadline.check()
        guard descriptions.count == 1,
              CMFormatDescriptionGetMediaSubType(descriptions[0]) == kCMVideoCodecType_H264 else {
            throw VideoMediaError.verification("The video track is not a single H.264 format.")
        }
        guard transform.a == 1, transform.b == 0, transform.c == 0, transform.d == 1,
              transform.tx == 0, transform.ty == 0 else {
            throw VideoMediaError.verification("The video track contains a rotation, reflection, or translation transform.")
        }
        try verifyRec709(descriptions[0])

        let dimensions = CMVideoFormatDescriptionGetDimensions(descriptions[0])
        guard Int(dimensions.width) == sequence.width, Int(dimensions.height) == sequence.height else {
            throw VideoMediaError.verification("The encoded dimensions do not match the submitted sequence.")
        }

        let expectedSampleDuration = CMTime(
            value: Int64(sequence.fpsDenominator),
            timescale: sequence.fpsNumerator
        )
        let expectedEnd = CMTime(
            value: try checkedTimelineValue(index: sequence.frameCount, denominator: sequence.fpsDenominator),
            timescale: sequence.fpsNumerator
        )
        guard trackTimeRange.start.isNumeric,
              sameTime(trackTimeRange.start, .zero),
              trackTimeRange.duration.isNumeric,
              sameTime(trackTimeRange.duration, expectedEnd),
              assetDuration.isNumeric,
              sameTime(assetDuration, expectedEnd) else {
            throw VideoMediaError.verification("The MP4 container or video-track duration is not N*q/p.")
        }

        // Compressed samples retain the authoritative MP4 sample-table durations. A decoder may
        // legitimately vend BGRA frames with kCMTimeInvalid duration, so timing is proven here,
        // independently of the complete decoded-frame pass below.
        let timingOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        timingOutput.alwaysCopiesSampleData = false
        let timingReader = try AVAssetReader(asset: asset)
        guard timingReader.canAdd(timingOutput) else {
            throw VideoMediaError.verification("Could not create the compressed-sample timing reader.")
        }
        timingReader.add(timingOutput)
        guard timingReader.startReading() else {
            throw VideoMediaError.verification(
                readerMessage(timingReader, fallback: "Could not begin compressed-sample timing verification.")
            )
        }
        var timedFrameCount = 0
        var actualEnd = CMTime.invalid
        do {
            while let sample = timingOutput.copyNextSampleBuffer() {
                try deadline.check()
                let samples = CMSampleBufferGetNumSamples(sample)
                if samples == 0 { continue } // AVAssetReader may vend marker-only buffers for passthrough.
                guard samples == 1, timedFrameCount < sequence.frameCount else {
                    throw VideoMediaError.verification("The compressed H.264 sample count is not one sample per frame.")
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let duration = CMSampleBufferGetDuration(sample)
                let expectedPTS = CMTime(
                    value: try checkedTimelineValue(index: timedFrameCount, denominator: sequence.fpsDenominator),
                    timescale: sequence.fpsNumerator
                )
                guard pts.isNumeric, duration.isNumeric, duration > .zero,
                      sameTime(pts, expectedPTS),
                      sameTime(duration, expectedSampleDuration) else {
                    throw VideoMediaError.verification(
                        "Compressed frame \(timedFrameCount) has an incorrect PTS or sample-table duration."
                    )
                }
                let decodeTime = CMSampleBufferGetDecodeTimeStamp(sample)
                if decodeTime.isNumeric, !sameTime(decodeTime, pts) {
                    throw VideoMediaError.verification("The compressed video contains reordered/B frames.")
                }
                actualEnd = CMTimeAdd(pts, duration)
                timedFrameCount += 1
                await Task.yield()
            }
            try deadline.check()
        } catch {
            timingReader.cancelReading()
            while timingReader.status == .reading { _ = timingOutput.copyNextSampleBuffer() }
            throw error
        }
        guard timingReader.status == .completed else {
            throw VideoMediaError.verification(
                readerMessage(timingReader, fallback: "Compressed-sample timing verification did not complete.")
            )
        }
        guard timedFrameCount == sequence.frameCount,
              actualEnd.isNumeric,
              sameTime(actualEnd, expectedEnd) else {
            throw VideoMediaError.verification("Compressed samples do not prove the expected frame count and N*q/p end time.")
        }

        let decodedOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        )
        decodedOutput.alwaysCopiesSampleData = false
        let decodedReader = try AVAssetReader(asset: asset)
        guard decodedReader.canAdd(decodedOutput) else {
            throw VideoMediaError.verification("Could not create the independent video decoder.")
        }
        decodedReader.add(decodedOutput)
        guard decodedReader.startReading() else {
            throw VideoMediaError.verification(
                readerMessage(decodedReader, fallback: "Could not begin independent MP4 decoding.")
            )
        }

        var decodedFrameCount = 0
        do {
            while let sample = decodedOutput.copyNextSampleBuffer() {
                try deadline.check()
                guard decodedFrameCount < sequence.frameCount else {
                    throw VideoMediaError.verification("The MP4 contains more frames than expected.")
                }
                guard let image = CMSampleBufferGetImageBuffer(sample),
                      CVPixelBufferGetWidth(image) == sequence.width,
                      CVPixelBufferGetHeight(image) == sequence.height else {
                    throw VideoMediaError.verification("A decoded frame has unexpected dimensions.")
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let duration = CMSampleBufferGetDuration(sample)
                let expectedPTS = CMTime(
                    value: try checkedTimelineValue(index: decodedFrameCount, denominator: sequence.fpsDenominator),
                    timescale: sequence.fpsNumerator
                )
                guard pts.isNumeric, sameTime(pts, expectedPTS) else {
                    throw VideoMediaError.verification("Decoded frame \(decodedFrameCount) has an incorrect PTS.")
                }
                // A decompressor may omit sample duration. If it provides one, it must agree with
                // the independently verified compressed sample table; missing is not fabricated.
                if duration.isNumeric,
                   (duration <= .zero || !sameTime(duration, expectedSampleDuration)) {
                    throw VideoMediaError.verification("Decoded frame \(decodedFrameCount) reports a contradictory duration.")
                }
                decodedFrameCount += 1
                await Task.yield()
            }
            try deadline.check()
        } catch {
            decodedReader.cancelReading()
            while decodedReader.status == .reading { _ = decodedOutput.copyNextSampleBuffer() }
            throw error
        }
        guard decodedReader.status == .completed else {
            throw VideoMediaError.verification(
                readerMessage(decodedReader, fallback: "Independent MP4 decoding did not complete.")
            )
        }
        guard decodedFrameCount == sequence.frameCount else {
            throw VideoMediaError.verification(
                "Decoded \(decodedFrameCount) frames; expected \(sequence.frameCount)."
            )
        }
        try file.validateUnchanged()
        return VideoMediaInspection(
            width: sequence.width,
            height: sequence.height,
            frameCount: decodedFrameCount,
            fpsNumerator: sequence.fpsNumerator,
            fpsDenominator: sequence.fpsDenominator,
            durationNumerator: actualEnd.value,
            durationDenominator: actualEnd.timescale,
            byteCount: UInt64(file.size),
            sha256: digest,
            codec: "h264",
            colorInterpretation: "full-range Rec.709 display RGB; encoded with Rec.709 primaries/transfer/matrix"
        )
    }

    private static func verifyRec709(_ description: CMFormatDescription) throws {
        guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] else {
            throw VideoMediaError.verification("The H.264 format has no color metadata.")
        }
        func value(_ key: CFString) -> String? {
            (extensions[key as String] as? String)
        }
        guard value(kCMFormatDescriptionExtension_ColorPrimaries) == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String),
              value(kCMFormatDescriptionExtension_TransferFunction) == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String),
              value(kCMFormatDescriptionExtension_YCbCrMatrix) == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String) else {
            throw VideoMediaError.verification("The H.264 format is not tagged with Rec.709 primaries, transfer, and matrix.")
        }
    }

    private static func checkedTimelineValue(index: Int, denominator: Int32) throws -> Int64 {
        let (value, overflow) = Int64(index).multipliedReportingOverflow(by: Int64(denominator))
        guard !overflow else { throw VideoMediaError.invalidInput("The video timeline exceeds Int64.") }
        return value
    }

    private static func sameTime(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
        // p is our track time scale; all q/p times are exactly representable.
        // A coarse time base cannot justify accepting a different frame rate.
        lhs.isNumeric && rhs.isNumeric && CMTimeCompare(lhs, rhs) == 0
    }

    private static func writerMessage(_ writer: AVAssetWriter, fallback: String) -> String {
        guard let error = writer.error else { return fallback }
        let nsError = error as NSError
        return "\(fallback) \(nsError.domain) \(nsError.code): \(nsError.localizedDescription) \(nsError.userInfo)"
    }

    private static func readerMessage(_ reader: AVAssetReader, fallback: String) -> String {
        reader.error.map { "\(fallback) \($0.localizedDescription)" } ?? fallback
    }

    fileprivate static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private actor FinishSignal {
    private var value = false
    func finish() { value = true }
    func isFinished() -> Bool { value }
}

private struct ValidatedVideoPolicy {
    let pixelCount: Int
    let rgbRowBytes: Int
    let bgraRowBytes: Int
    let frameBytes: Int
    let totalBytes: Int64

    init(sequence: VideoFrameSequence, limits: VideoMediaLimits) throws {
        let counts = try sequence.validatedByteCounts()
        guard limits.maximumFrameBytes > 0, limits.maximumOutputBytes > 0,
              limits.timeoutSeconds.isFinite, limits.timeoutSeconds > 0 else {
            throw VideoMediaError.invalidInput("Media limits must be finite positive values.")
        }
        guard UInt64(counts.frame) <= limits.maximumFrameBytes else {
            throw VideoMediaError.invalidInput("A raw RGB8 frame exceeds maximumFrameBytes.")
        }
        let (pixels, pixelOverflow) = sequence.width.multipliedReportingOverflow(by: sequence.height)
        let (rgbRow, rgbRowOverflow) = sequence.width.multipliedReportingOverflow(by: 3)
        let (bgraRow, bgraRowOverflow) = sequence.width.multipliedReportingOverflow(by: 4)
        let (_, bgraTotalOverflow) = bgraRow.multipliedReportingOverflow(by: sequence.height)
        guard !pixelOverflow, !rgbRowOverflow, !bgraRowOverflow, !bgraTotalOverflow,
              pixels > 0, rgbRow > 0, bgraRow > 0 else {
            throw VideoMediaError.invalidInput("Required RGB/BGRA allocation arithmetic overflowed.")
        }
        pixelCount = pixels
        rgbRowBytes = rgbRow
        bgraRowBytes = bgraRow
        frameBytes = counts.frame
        totalBytes = counts.total
    }
}

private struct Deadline: Sendable {
    private let value: Double

    init(seconds: Double) throws {
        guard seconds.isFinite, seconds > 0 else {
            throw VideoMediaError.invalidInput("timeoutSeconds must be finite and positive.")
        }
        let now = Self.now()
        let sum = now + seconds
        value = sum.isFinite ? sum : Double.greatestFiniteMagnitude
    }

    func check() throws {
        try Task.checkCancellation()
        if Self.now() >= value { throw VideoMediaError.timedOut }
    }

    private static func now() -> Double {
        var time = timespec()
        _ = clock_gettime(CLOCK_MONOTONIC_RAW, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}

private final class AnchoredReadFile {
    let size: Int64
    private let location: LocalFileLocation
    private let parentFD: Int32
    private let fd: Int32
    private let identity: stat

    init(url: URL, expectedSize: Int64, purpose: String) throws {
        location = try LocalFileLocation(url: url)
        parentFD = try SecurePath.openDirectory(location.parentPath)
        fd = openat(parentFD, location.leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            close(parentFD)
            throw VideoMediaError.io("Could not open \(purpose): \(SecurePath.errnoText).")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd); close(parentFD)
            throw VideoMediaError.invalidInput("The \(purpose) must be a regular file, not a directory or symbolic link.")
        }
        guard info.st_size == expectedSize else {
            close(fd); close(parentFD)
            throw VideoMediaError.verification("The \(purpose) byte count is \(info.st_size); expected \(expectedSize).")
        }
        size = info.st_size
        identity = info
        try validateUnchanged()
    }

    init(url: URL, maximumSize: UInt64, purpose: String) throws {
        location = try LocalFileLocation(url: url)
        parentFD = try SecurePath.openDirectory(location.parentPath)
        fd = openat(parentFD, location.leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            close(parentFD)
            throw VideoMediaError.io("Could not open \(purpose): \(SecurePath.errnoText).")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            close(fd); close(parentFD)
            throw VideoMediaError.invalidInput("The \(purpose) must be a regular file, not a directory or symbolic link.")
        }
        guard UInt64(info.st_size) <= maximumSize else {
            close(fd); close(parentFD)
            throw VideoMediaError.verification("The \(purpose) exceeds maximumOutputBytes.")
        }
        size = info.st_size
        identity = info
        try validateUnchanged()
    }

    deinit { close(fd); close(parentFD) }

    func readExactly(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let amount = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset)
            }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw VideoMediaError.io("The frame spool ended before a complete frame was available.") }
            offset += amount
        }
        return Data(bytes)
    }

    func requireEndOfFile() throws {
        var byte: UInt8 = 0
        while true {
            let amount = Darwin.read(fd, &byte, 1)
            if amount < 0, errno == EINTR { continue }
            guard amount == 0 else { throw VideoMediaError.verification("The frame spool contains trailing bytes.") }
            return
        }
    }

    func sha256(deadline: Deadline) throws -> String {
        guard lseek(fd, 0, SEEK_SET) == 0 else {
            throw VideoMediaError.io("Could not seek the MP4 for hashing: \(SecurePath.errnoText).")
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var total: Int64 = 0
        while true {
            try deadline.check()
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if amount < 0, errno == EINTR { continue }
            guard amount >= 0 else { throw VideoMediaError.io("Could not hash the MP4: \(SecurePath.errnoText).") }
            if amount == 0 { break }
            total += Int64(amount)
            guard total <= size else { throw VideoMediaError.verification("The MP4 grew while it was being hashed.") }
            hasher.update(data: Data(buffer.prefix(amount)))
        }
        guard total == size else { throw VideoMediaError.verification("The MP4 changed length while it was being hashed.") }
        return VideoArtifactWriter.hexDigest(hasher.finalize())
    }

    func validateUnchanged() throws {
        var descriptor = stat(), named = stat(), parent = stat(), reopenedParent = stat()
        guard fstat(fd, &descriptor) == 0,
              fstatat(parentFD, location.leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(parentFD, &parent) == 0 else {
            throw VideoMediaError.verification("The opened file or its parent became unavailable.")
        }
        let currentParent = try SecurePath.openDirectory(location.parentPath)
        defer { close(currentParent) }
        guard fstat(currentParent, &reopenedParent) == 0,
              SecurePath.same(parent, reopenedParent),
              SecurePath.sameVersion(identity, descriptor),
              SecurePath.sameVersion(identity, named),
              named.st_mode & S_IFMT == S_IFREG else {
            throw VideoMediaError.verification("The opened file, its name, or its parent changed during the operation.")
        }
    }
}

internal final class VideoPublication {
    let temporaryURL: URL
    private let destination: LocalFileLocation
    private let parentFD: Int32
    private let parentIdentity: stat
    private let directoryName: String
    private let directoryFD: Int32
    private let temporaryName = "video.partial.mp4"
    private var temporaryIdentity: stat?
    private var completedFD: Int32 = -1
    private var published = false
    private var cleaned = false

    init(destination url: URL) throws {
        destination = try LocalFileLocation(url: url)
        parentFD = try SecurePath.openDirectory(destination.parentPath)
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0 else {
            close(parentFD)
            throw VideoMediaError.io("Could not inspect the destination parent: \(SecurePath.errnoText).")
        }
        parentIdentity = parentInfo
        var existing = stat()
        guard fstatat(parentFD, destination.leaf, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            close(parentFD)
            throw VideoMediaError.invalidInput("The destination already exists; video artifacts are never overwritten.")
        }
        directoryName = ".video-\(UUID().uuidString)"
        guard mkdirat(parentFD, directoryName, 0o700) == 0 else {
            close(parentFD)
            throw VideoMediaError.io("Could not create the private video staging directory: \(SecurePath.errnoText).")
        }
        directoryFD = openat(parentFD, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            _ = unlinkat(parentFD, directoryName, AT_REMOVEDIR)
            close(parentFD)
            throw VideoMediaError.io("Could not anchor the private video staging directory: \(SecurePath.errnoText).")
        }
        temporaryURL = destination.parentURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(temporaryName, isDirectory: false)
    }

    deinit {
        if completedFD >= 0 { close(completedFD) }
        close(directoryFD)
        close(parentFD)
    }

    /// Bind AVFoundation's URL-only writer to the held private directory's inode.
    /// No pathname fallback: unavailable identity paths fail before AV starts.
    func identityAddressedWriterURL() throws -> URL {
        try validateLocations()
        var info = stat(), reopened = stat()
        guard fstat(directoryFD, &info) == 0 else {
            throw VideoMediaError.io("Cannot inspect the held media staging directory.")
        }
        let path = "/.vol/\(UInt32(bitPattern: info.st_dev))/\(info.st_ino)"
        let checkFD = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard checkFD >= 0 else {
            throw VideoMediaError.io("This filesystem cannot provide identity-bound media writing: \(SecurePath.errnoText).")
        }
        defer { close(checkFD) }
        guard fstat(checkFD, &reopened) == 0, SecurePath.same(info, reopened) else {
            throw VideoMediaError.verification("The inode-addressed directory differs from the held staging directory.")
        }
        return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(temporaryName)
    }

    func captureTemporaryIdentityIfPresent() throws -> Bool {
        try validateLocations()
        var info = stat()
        guard fstatat(directoryFD, temporaryName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw VideoMediaError.io("Could not inspect the encoder output: \(SecurePath.errnoText).")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw VideoMediaError.verification("The encoder did not create the expected private regular file.")
        }
        temporaryIdentity = info
        return true
    }

    func checkTemporarySize(maximum: UInt64) throws {
        guard let expected = temporaryIdentity else { return }
        var info = stat()
        guard fstatat(directoryFD, temporaryName, &info, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePath.same(expected, info), info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw VideoMediaError.verification("The private MP4 was replaced during encoding.")
        }
        guard UInt64(info.st_size) <= maximum else {
            throw VideoMediaError.encoding("The encoded MP4 exceeds maximumOutputBytes.")
        }
        try validateLocations()
    }

    func validateCompletedTemporary(maximum: UInt64) throws {
        try checkTemporarySize(maximum: maximum)
        guard let expected = temporaryIdentity else {
            throw VideoMediaError.verification("The private MP4 has no recorded identity.")
        }
        let fd = openat(directoryFD, temporaryName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VideoMediaError.io("Could not reopen the completed MP4: \(SecurePath.errnoText).") }
        var info = stat()
        guard fstat(fd, &info) == 0, SecurePath.same(expected, info), info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw VideoMediaError.verification("The completed private MP4 changed identity.")
        }
        guard fsync(fd) == 0 else {
            close(fd)
            throw VideoMediaError.io("Could not flush the completed MP4: \(SecurePath.errnoText).")
        }
        temporaryIdentity = info
        completedFD = fd
    }

    fileprivate func publish(expectedSHA256: String, deadline: Deadline) throws {
        try validateLocations()
        guard let expected = temporaryIdentity, completedFD >= 0 else {
            throw VideoMediaError.verification("The private MP4 has no publication identity.")
        }
        var temporary = stat(), heldBeforeRename = stat(), existing = stat()
        guard fstatat(directoryFD, temporaryName, &temporary, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(completedFD, &heldBeforeRename) == 0,
              SecurePath.sameVersion(expected, temporary),
              SecurePath.sameVersion(expected, heldBeforeRename),
              temporary.st_nlink == 1 else {
            throw VideoMediaError.verification("The private MP4 changed before publication.")
        }
        guard fstatat(parentFD, destination.leaf, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw VideoMediaError.invalidInput("The destination appeared before publication; it was not overwritten.")
        }
        try Task.checkCancellation()
        guard renameatx_np(directoryFD, temporaryName, parentFD, destination.leaf, UInt32(RENAME_EXCL)) == 0 else {
            throw VideoMediaError.io("Could not publish the MP4 exclusively: \(SecurePath.errnoText).")
        }
        published = true
        temporaryIdentity = nil
        do {
            guard fsync(parentFD) == 0 else {
                throw VideoMediaError.io("Could not flush the destination directory: \(SecurePath.errnoText).")
            }
            try validateParentOnly()
            let namedFD = openat(parentFD, destination.leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard namedFD >= 0 else {
                throw VideoMediaError.io("Could not reopen the published MP4 by its destination name: \(SecurePath.errnoText).")
            }
            defer { close(namedFD) }
            var heldAfterRename = stat(), named = stat(), result = stat()
            guard fstat(completedFD, &heldAfterRename) == 0,
                  fstat(namedFD, &named) == 0,
                  fstatat(parentFD, destination.leaf, &result, AT_SYMLINK_NOFOLLOW) == 0,
                  publicationStableFieldsMatch(expected, heldAfterRename),
                  SecurePath.sameVersion(heldAfterRename, named),
                  SecurePath.sameVersion(heldAfterRename, result),
                  result.st_mode & S_IFMT == S_IFREG,
                  result.st_nlink == 1 else {
                throw VideoMediaError.verification("The published MP4 was replaced during final verification.")
            }
            let publishedDigest = try digestHeldFile(
                expectedSize: expected.st_size,
                deadline: deadline,
                stableVersion: heldAfterRename
            )
            guard publishedDigest == expectedSHA256 else {
                throw VideoMediaError.verification("The published MP4 content does not match the independently inspected MP4.")
            }
            var finalHeld = stat(), finalNamed = stat()
            guard fstat(completedFD, &finalHeld) == 0,
                  fstatat(parentFD, destination.leaf, &finalNamed, AT_SYMLINK_NOFOLLOW) == 0,
                  SecurePath.sameVersion(heldAfterRename, finalHeld),
                  SecurePath.sameVersion(heldAfterRename, finalNamed) else {
                throw VideoMediaError.verification("The published MP4 changed while its content was verified.")
            }
            close(completedFD)
            completedFD = -1
            guard unlinkat(parentFD, directoryName, AT_REMOVEDIR) == 0 else {
                throw VideoMediaError.io("Could not remove the empty staging directory: \(SecurePath.errnoText).")
            }
            cleaned = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VideoMediaError.io(
                "Video publication completed at \(destination.url.path), but final synchronization or verification failed: \(error.localizedDescription). The published file was preserved."
            )
        }
    }

    func cleanupUnpublished() throws {
        guard !published, !cleaned else { return }
        try validateLocations()
        if completedFD >= 0 {
            close(completedFD)
            completedFD = -1
        }
        if let expected = temporaryIdentity {
            var current = stat()
            if fstatat(directoryFD, temporaryName, &current, AT_SYMLINK_NOFOLLOW) == 0 {
                guard SecurePath.same(expected, current), current.st_mode & S_IFMT == S_IFREG else {
                    throw VideoMediaError.verification("Refusing to remove a replaced private MP4.")
                }
                guard unlinkat(directoryFD, temporaryName, 0) == 0 else {
                    throw VideoMediaError.io("Could not remove the unpublished private MP4: \(SecurePath.errnoText).")
                }
            } else if errno != ENOENT {
                throw VideoMediaError.io("Could not inspect the unpublished private MP4: \(SecurePath.errnoText).")
            }
            temporaryIdentity = nil
        }
        guard unlinkat(parentFD, directoryName, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw VideoMediaError.io("Could not remove the private staging directory: \(SecurePath.errnoText).")
        }
        cleaned = true
    }

    private func digestHeldFile(expectedSize: Int64, deadline: Deadline, stableVersion: stat) throws -> String {
        guard expectedSize >= 0, lseek(completedFD, 0, SEEK_SET) == 0 else {
            throw VideoMediaError.io("Could not seek the published MP4 for content verification: \(SecurePath.errnoText).")
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var total: Int64 = 0
        while true {
            try deadline.check()
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(completedFD, $0.baseAddress, $0.count) }
            if amount < 0, errno == EINTR { continue }
            guard amount >= 0 else {
                throw VideoMediaError.io("Could not read the published MP4 for content verification: \(SecurePath.errnoText).")
            }
            if amount == 0 { break }
            let (nextTotal, overflow) = total.addingReportingOverflow(Int64(amount))
            guard !overflow, nextTotal <= expectedSize else {
                throw VideoMediaError.verification("The published MP4 grew during content verification.")
            }
            total = nextTotal
            hasher.update(data: Data(buffer.prefix(amount)))
        }
        var after = stat()
        guard total == expectedSize,
              fstat(completedFD, &after) == 0,
              SecurePath.sameVersion(stableVersion, after) else {
            throw VideoMediaError.verification("The published MP4 changed while its digest was calculated.")
        }
        return VideoArtifactWriter.hexDigest(hasher.finalize())
    }

    /// rename(2) legitimately updates ctime. Every content/ownership field that must remain stable
    /// is compared here; the post-rename ctime is then frozen by sameVersion checks plus a digest.
    private func publicationStableFieldsMatch(_ before: stat, _ after: stat) -> Bool {
        SecurePath.same(before, after)
            && before.st_size == after.st_size
            && before.st_mode == after.st_mode
            && before.st_nlink == after.st_nlink
            && before.st_uid == after.st_uid
            && before.st_gid == after.st_gid
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    }

    private func validateLocations() throws {
        try validateParentOnly()
        var named = stat(), opened = stat()
        guard fstatat(parentFD, directoryName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(directoryFD, &opened) == 0,
              SecurePath.same(named, opened), named.st_mode & S_IFMT == S_IFDIR else {
            throw VideoMediaError.verification("The private staging directory was moved or replaced.")
        }
    }

    private func validateParentOnly() throws {
        let reopened = try SecurePath.openDirectory(destination.parentPath)
        defer { close(reopened) }
        var current = stat(), held = stat()
        guard fstat(reopened, &current) == 0, fstat(parentFD, &held) == 0,
              SecurePath.same(parentIdentity, current), SecurePath.same(parentIdentity, held) else {
            throw VideoMediaError.verification("The destination parent directory was moved or replaced.")
        }
    }
}

private struct LocalFileLocation {
    let url: URL
    let parentURL: URL
    let parentPath: String
    let leaf: String

    init(url: URL) throws {
        guard url.isFileURL, let scheme = url.scheme, scheme.lowercased() == "file",
              url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
            throw VideoMediaError.invalidInput("Media URLs must be local file URLs without a nonlocal host, query, or fragment.")
        }
        let path = url.path
        guard path.hasPrefix("/"), path.count > 1, !path.contains("\0"), !path.hasSuffix("/"),
              !path.dropFirst().contains("//") else {
            throw VideoMediaError.invalidInput("Media paths must be unambiguous absolute filesystem paths.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == true, components.count >= 2,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw VideoMediaError.invalidInput("Media paths may not contain empty, dot, or parent components.")
        }
        leaf = String(components.last!)
        let parents = components.dropFirst().dropLast().map(String.init)
        parentPath = parents.isEmpty ? "/" : "/" + parents.joined(separator: "/")
        parentURL = URL(fileURLWithPath: parentPath, isDirectory: true)
        self.url = url
    }
}

private enum SecurePath {
    static var errnoText: String { String(cString: strerror(errno)) }

    static func openDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw VideoMediaError.invalidInput("Directory paths must be absolute local paths.")
        }
        let components = path.split(separator: "/")
        let traversalFlags = O_SEARCH | O_NOFOLLOW | O_CLOEXEC
        let finalFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open("/", components.isEmpty ? finalFlags : traversalFlags)
        guard descriptor >= 0 else { throw VideoMediaError.io("Could not open filesystem root: \(errnoText).") }
        for (index, component) in components.enumerated() {
            let next = openat(descriptor, String(component), index == components.count - 1 ? finalFlags : traversalFlags)
            close(descriptor)
            guard next >= 0 else {
                throw VideoMediaError.io("Could not securely open a media directory component: \(errnoText).")
            }
            descriptor = next
        }
        return descriptor
    }

    static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        same(lhs, rhs) && lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
