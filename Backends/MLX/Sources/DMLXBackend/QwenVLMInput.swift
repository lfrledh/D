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

    struct Ownership: Sendable, Equatable {
        let device: Int64
        let inode: UInt64

        init(_ value: stat) {
            device = Int64(value.st_dev)
            inode = UInt64(value.st_ino)
        }
    }

    struct Proof: Sendable {
        let original: URL
        let byteCount: UInt64
        let digest: String
        let identity: AudioFileSystem.Identity
    }

    let directory: URL
    let directoryOwnership: Ownership
    let ownedFiles: [String: Ownership]
    let images: [Source]
    let videos: [Source]
    var video: Source? { videos.first }

    static func freeze(_ request: TextRequest, in artifactDirectory: URL, modelDirectory: URL) throws -> Self {
        let root = try AudioFileSystem.absoluteLocal(artifactDirectory, label: "VLM snapshot root")
        try AudioFileSystem.validateDirectory(root, label: "VLM snapshot root")
        guard !AudioFileSystem.overlaps(root, modelDirectory) else {
            throw InferenceFailure.invalidRequest("Snapshot root must be separate from model files.")
        }
        let imageReferences = request.allImages
        let videoReferences = request.allVideos
        let references = imageReferences.map { ($0.url, $0.byteCount, $0.contentSHA256) }
        let videoItems = videoReferences.map { ($0.url, $0.byteCount, $0.contentSHA256) }
        for (url, _, _) in references + videoItems {
            guard !AudioFileSystem.overlaps(root, url) else {
                throw InferenceFailure.invalidRequest("Snapshot root overlaps visual source.")
            }
        }
        let directory = root.appendingPathComponent("vlm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let directoryFD = try AudioFileSystem.openDirectory(directory, label: "VLM snapshot")
        var directoryStat = stat()
        guard Darwin.fstat(directoryFD, &directoryStat) == 0 else {
            Darwin.close(directoryFD)
            throw InferenceFailure.backendFailed("Cannot identify private visual snapshot directory.")
        }
        Darwin.close(directoryFD)
        let directoryOwnership = Ownership(directoryStat)
        var ownedFiles = [String: Ownership]()
        var touched = [Proof]()
        do {
            let images = try references.enumerated().map { index, value in
                let ext = value.0.pathExtension.lowercased()
                let item = try copy(value.0, bytes: value.1, digest: value.2,
                                    to: directory.appendingPathComponent("image-\(index).\(ext)"),
                                    registered: { proof in touched.append(proof) },
                                    created: { name, owner in ownedFiles[name] = owner })
                try validateImage(item.privateURL, declared: imageReferences[index])
                return item
            }
            let videos = try videoItems.enumerated().map { index, value in
                try copy(value.0, bytes: value.1, digest: value.2,
                         to: directory.appendingPathComponent("video-\(index).mp4"),
                         registered: { proof in touched.append(proof) },
                         created: { name, owner in ownedFiles[name] = owner })
            }
            return Self(directory: directory, directoryOwnership: directoryOwnership,
                        ownedFiles: ownedFiles, images: images, videos: videos)
        } catch {
            let originalError = error
            // A failed second copy or cancellation still audits every source already opened.
            var terminalError: Error = originalError
            do { try verify(touched) } catch { terminalError = error }
            let partial = Self(directory: directory, directoryOwnership: directoryOwnership,
                               ownedFiles: ownedFiles, images: [], videos: [])
            do { try partial.removePrivateFiles() }
            catch { throw InferenceFailure.resourceCleanupUnconfirmed("Incomplete VLM snapshot retained at \(directory.path): \(error.localizedDescription)") }
            throw terminalError
        }
    }

    func verifyOriginals() throws {
        try Self.verify((images + videos).map {
            Proof(original: $0.original, byteCount: $0.byteCount,
                  digest: $0.digest, identity: $0.identity)
        })
    }

    private static func verify(_ proofs: [Proof]) throws {
        do {
            for proof in proofs {
                let (digest, identity) = try hashFile(proof.original, expectedBytes: proof.byteCount)
                guard identity == proof.identity, digest == proof.digest else {
                    throw InferenceFailure.inputIntegrityChanged("A visual source changed during inference.")
                }
            }
        } catch {
            throw InferenceFailure.inputIntegrityChanged("Visual source verification failed: \(error.localizedDescription)")
        }
    }

    func removePrivateFiles() throws {
        let parent = try AudioFileSystem.openDirectory(directory.deletingLastPathComponent(),
                                                       label: "VLM snapshot parent")
        defer { Darwin.close(parent) }
        let fd = Darwin.openat(parent, directory.lastPathComponent,
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw InferenceFailure.backendFailed("Private visual snapshot directory is missing or replaced.")
        }
        defer { Darwin.close(fd) }
        var directoryStat = stat()
        guard Darwin.fstat(fd, &directoryStat) == 0,
              Ownership(directoryStat) == directoryOwnership else {
            throw InferenceFailure.backendFailed("Private visual snapshot directory ownership changed.")
        }
        let streamFD = Darwin.dup(fd)
        guard streamFD >= 0, let stream = Darwin.fdopendir(streamFD) else {
            if streamFD >= 0 { Darwin.close(streamFD) }
            throw InferenceFailure.backendFailed("Cannot inspect private visual snapshot entries.")
        }
        var names = Set<String>()
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.insert(name) }
        }
        let enumerationError = errno
        Darwin.closedir(stream)
        guard enumerationError == 0 else {
            throw InferenceFailure.backendFailed("Cannot finish inspecting private visual snapshot.")
        }
        guard names == Set(ownedFiles.keys) else {
            throw InferenceFailure.backendFailed("Private visual snapshot has unknown or missing entries.")
        }
        // Check all entries before removing any. No recursive deletion is permitted.
        for (name, owner) in ownedFiles {
            var item = stat()
            guard Darwin.fstatat(fd, name, &item, AT_SYMLINK_NOFOLLOW) == 0,
                  item.st_mode & S_IFMT == S_IFREG,
                  Ownership(item) == owner else {
                throw InferenceFailure.backendFailed("Private visual snapshot file ownership changed.")
            }
        }
        for (name, owner) in ownedFiles {
            var item = stat()
            guard Darwin.fstatat(fd, name, &item, AT_SYMLINK_NOFOLLOW) == 0,
                  item.st_mode & S_IFMT == S_IFREG, Ownership(item) == owner else {
                throw InferenceFailure.backendFailed("Private visual snapshot file changed during cleanup.")
            }
            guard Darwin.unlinkat(fd, name, 0) == 0 else {
                throw InferenceFailure.backendFailed("Cannot remove owned private visual snapshot file.")
            }
        }
        var finalDirectory = stat()
        guard Darwin.fstatat(parent, directory.lastPathComponent, &finalDirectory,
                            AT_SYMLINK_NOFOLLOW) == 0,
              Ownership(finalDirectory) == directoryOwnership else {
            throw InferenceFailure.backendFailed("Private visual snapshot directory changed during cleanup.")
        }
        guard Darwin.unlinkat(parent, directory.lastPathComponent, AT_REMOVEDIR) == 0 else {
            throw InferenceFailure.backendFailed("Cannot remove owned private visual snapshot directory.")
        }
    }

    private static func copy(_ source: URL, bytes: UInt64, digest: String, to destination: URL,
                             registered: (Proof) -> Void,
                             created: (String, Ownership) -> Void) throws -> Source {
        guard (1...2 * 1024 * 1024 * 1024).contains(bytes) else {
            throw InferenceFailure.invalidRequest("Visual source exceeds bounded verification size.")
        }
        let (input, before) = try openSource(source, expectedBytes: bytes)
        defer { Darwin.close(input) }
        registered(Proof(original: source, byteCount: bytes, digest: digest, identity: before))
        let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw InferenceFailure.backendFailed("Cannot create private visual snapshot.") }
        defer { Darwin.close(output) }
        var outputStat = stat()
        guard Darwin.fstat(output, &outputStat) == 0 else {
            throw InferenceFailure.backendFailed("Cannot identify private visual snapshot file.")
        }
        created(destination.lastPathComponent, Ownership(outputStat))
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
