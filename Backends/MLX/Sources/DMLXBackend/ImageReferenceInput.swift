import CryptoKit
import Darwin
import DInference
import Foundation

/// One immutable read of the host-frozen row-major RGB8 derivative.
/// The opened inode, the path after the read, the declared length and digest must all agree.
struct ImageReferenceInput: Sendable, Equatable {
    let rgb: Data
    let sha256: String
    let width: Int
    let height: Int
    let encoding: String

    static func load(_ reference: ImageReference) throws -> Self {
        try reference.validate()
        let (descriptor, initial) = try open(reference.url, expectedByteCount: reference.byteCount)
        defer { Darwin.close(descriptor) }

        guard reference.byteCount <= UInt64(Int.max) else {
            throw InferenceFailure.invalidRequest("The frozen image reference is too large to read on this platform.")
        }
        let count = Int(reference.byteCount)
        var mutable = Data(count: count)
        var offset = 0
        try mutable.withUnsafeMutableBytes { bytes in
            while offset < count {
                try Task.checkCancellation()
                let requested = min(64 * 1024, count - offset)
                let amount = Darwin.pread(descriptor, bytes.baseAddress!.advanced(by: offset), requested, off_t(offset))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else {
                    throw InferenceFailure.invalidRequest("The frozen image reference ended before its declared byte count.")
                }
                offset += amount
            }
        }
        try Task.checkCancellation()
        guard try identity(descriptor, expectedByteCount: reference.byteCount) == initial else {
            throw InferenceFailure.invalidRequest("The frozen image reference changed while it was being read.")
        }

        // Reopen the absolute path without following any component. This detects replacement
        // of the selected path while retaining the already-read descriptor and bytes.
        let (verification, final) = try open(reference.url, expectedByteCount: reference.byteCount)
        Darwin.close(verification)
        guard final == initial else {
            throw InferenceFailure.invalidRequest("The frozen image reference path changed while it was being read.")
        }

        let immutable = Data(mutable)
        let digest = SHA256.hash(data: immutable).map { String(format: "%02x", $0) }.joined()
        guard digest == reference.sha256 else {
            throw InferenceFailure.invalidRequest("The frozen image reference SHA-256 does not match the submitted request.")
        }
        return Self(rgb: immutable, sha256: digest, width: reference.width,
                    height: reference.height, encoding: reference.encoding)
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int

        init(_ value: stat, expectedByteCount: UInt64) throws {
            guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
                  value.st_size >= 0, UInt64(value.st_size) == expectedByteCount else {
                throw InferenceFailure.invalidRequest(
                    "The frozen image reference must be a single-link regular file with the declared byte count.")
            }
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modificationSeconds = Int(value.st_mtimespec.tv_sec)
            modificationNanoseconds = Int(value.st_mtimespec.tv_nsec)
            changeSeconds = Int(value.st_ctimespec.tv_sec)
            changeNanoseconds = Int(value.st_ctimespec.tv_nsec)
        }
    }

    private static func identity(_ descriptor: Int32, expectedByteCount: UInt64) throws -> Identity {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { throw fileFailure("Cannot inspect the frozen image reference") }
        return try Identity(value, expectedByteCount: expectedByteCount)
    }

    private static func open(_ url: URL, expectedByteCount: UInt64) throws -> (Int32, Identity) {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.standardizedFileURL.path == url.path else {
            throw InferenceFailure.invalidRequest("The frozen image reference path is not a safe local absolute path.")
        }
        let components = url.path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw InferenceFailure.invalidRequest("The frozen image reference path is not safe.")
        }

        var parent = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw fileFailure("Cannot open the frozen image reference root") }
        for component in components.dropLast() {
            let next = Darwin.openat(parent, component, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            Darwin.close(parent)
            guard next >= 0 else {
                errno = failure
                throw fileFailure("Cannot open a frozen image reference directory without following links")
            }
            parent = next
        }
        let descriptor = Darwin.openat(parent, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let failure = errno
        Darwin.close(parent)
        guard descriptor >= 0 else {
            errno = failure
            throw fileFailure("Cannot open the frozen image reference without following links")
        }
        do {
            return (descriptor, try identity(descriptor, expectedByteCount: expectedByteCount))
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func fileFailure(_ description: String) -> InferenceFailure {
        .invalidRequest("\(description): \(String(cString: strerror(errno)))")
    }
}
