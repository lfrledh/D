import CryptoKit
import Darwin
import DInference
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Owns private input snapshots until execute has drained and release has completed.
struct QwenVLMInputSnapshot: Sendable {
    struct Source: Sendable {
        let original: URL
        let privateURL: URL
        let byteCount: UInt64
        let digest: String
        let identity: AudioFileSystem.Identity
    }

    let directory: URL
    let images: [Source]
    let video: Source?

    static func freeze(_ request: TextRequest, in artifactDirectory: URL, modelDirectory: URL) throws -> Self {
        let root = try AudioFileSystem.absoluteLocal(artifactDirectory, label: "VLM snapshot root")
        try AudioFileSystem.validateDirectory(root, label: "VLM snapshot root")
        guard !AudioFileSystem.overlaps(root, modelDirectory) else {
            throw InferenceFailure.invalidRequest("Snapshot root must be separate from model files.")
        }
        let references = (request.images ?? []).map { ($0.url, $0.byteCount, $0.contentSHA256) }
        let videoReference = request.video.map { ($0.url, $0.byteCount, $0.contentSHA256) }
        for (url, _, _) in references + (videoReference.map { [$0] } ?? []) {
            guard !AudioFileSystem.overlaps(root, url) else {
                throw InferenceFailure.invalidRequest("Snapshot root overlaps visual source.")
            }
        }
        let directory = root.appendingPathComponent("vlm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let images = try references.enumerated().map { index, value in
                let ext = value.0.pathExtension.lowercased()
                let item = try copy(value.0, bytes: value.1, digest: value.2,
                                    to: directory.appendingPathComponent("image-\(index).\(ext)"))
                try validateImage(item.privateURL, declared: request.images![index])
                return item
            }
            let video = try videoReference.map { value in
                try copy(value.0, bytes: value.1, digest: value.2,
                         to: directory.appendingPathComponent("video.mp4"))
            }
            return Self(directory: directory, images: images, video: video)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func verifyOriginals() throws {
        for source in images + (video.map { [$0] } ?? []) {
            let (digest, identity) = try Self.hashFile(source.original, expectedBytes: source.byteCount)
            guard identity == source.identity, digest == source.digest else {
                throw InferenceFailure.invalidRequest("A visual source changed during inference.")
            }
        }
    }

    func removePrivateFiles() {
        // Only this instance's unpublished snapshot directory is ever removed.
        try? FileManager.default.removeItem(at: directory)
    }

    private static func copy(_ source: URL, bytes: UInt64, digest: String, to destination: URL) throws -> Source {
        let (input, before) = try openSource(source, expectedBytes: bytes)
        defer { Darwin.close(input) }
        let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw InferenceFailure.backendFailed("Cannot create private visual snapshot.") }
        defer { Darwin.close(output) }
        var hasher = SHA256()
        var copied: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while copied < bytes {
            try Task.checkCancellation()
            let wanted = min(buffer.count, Int(bytes - copied))
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw InferenceFailure.invalidRequest("Visual source ended while copying.") }
            hasher.update(data: Data(buffer.prefix(count)))
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    Darwin.write(output, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw InferenceFailure.backendFailed("Cannot write private visual snapshot.") }
                offset += written
            }
            copied += UInt64(count)
        }
        guard Darwin.fsync(output) == 0 else { throw InferenceFailure.backendFailed("Cannot flush visual snapshot.") }
        let value = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard value == digest else { throw InferenceFailure.invalidRequest("Visual source digest mismatch.") }
        let (_, after) = try openSource(source, expectedBytes: bytes, closeDescriptor: true)
        guard before == after else { throw InferenceFailure.invalidRequest("Visual source changed during copying.") }
        return Source(original: source, privateURL: destination, byteCount: bytes, digest: digest, identity: before)
    }

    private static func hashFile(_ source: URL, expectedBytes: UInt64) throws -> (String, AudioFileSystem.Identity) {
        let (descriptor, before) = try openSource(source, expectedBytes: expectedBytes)
        defer { Darwin.close(descriptor) }
        var hasher = SHA256()
        var remaining = expectedBytes
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while remaining > 0 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, min($0.count, Int(remaining))) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw InferenceFailure.invalidRequest("Visual source truncated after inference.") }
            hasher.update(data: Data(buffer.prefix(count)))
            remaining -= UInt64(count)
        }
        let (_, after) = try openSource(source, expectedBytes: expectedBytes, closeDescriptor: true)
        guard before == after else { throw InferenceFailure.invalidRequest("Visual source replaced after inference.") }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), before)
    }

    private static func openSource(_ url: URL, expectedBytes: UInt64, closeDescriptor: Bool = false)
        throws -> (Int32, AudioFileSystem.Identity) {
        let location = try AudioFileSystem.absoluteLocal(url, label: "visual source")
        let parent = try AudioFileSystem.openDirectory(location.deletingLastPathComponent(), label: "visual source parent")
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(parent, location.lastPathComponent,
                                      O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw InferenceFailure.invalidRequest("Cannot open regular visual source.") }
        var statValue = stat()
        guard Darwin.fstat(descriptor, &statValue) == 0,
              statValue.st_mode & S_IFMT == S_IFREG, statValue.st_nlink == 1,
              statValue.st_size >= 0, UInt64(statValue.st_size) == expectedBytes else {
            Darwin.close(descriptor)
            throw InferenceFailure.invalidRequest("Visual source is not an intact regular file.")
        }
        let identity = AudioFileSystem.Identity(statValue)
        if closeDescriptor { Darwin.close(descriptor); return (-1, identity) }
        return (descriptor, identity)
    }

    private static func validateImage(_ url: URL, declared: TextImageReference) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier].contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == declared.width,
              (properties[kCGImagePropertyPixelHeight] as? Int) == declared.height else {
            throw InferenceFailure.invalidRequest("Encoded image header or dimensions do not match request.")
        }
    }
}
