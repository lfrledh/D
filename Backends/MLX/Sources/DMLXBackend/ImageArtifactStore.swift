import CoreGraphics
import Darwin
import DInference
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// CPU-only PNG encoding. Reading pixels back forces ImageIO to decode the complete image.
internal enum ImagePNG {
    static func encode(rgb: [UInt8], width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              rgb.count == width * height * 3 else {
            throw InferenceFailure.backendFailed("Unexpected RGB image size.")
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) {
            rgba[pixel * 4] = rgb[pixel * 3]
            rgba[pixel * 4 + 1] = rgb[pixel * 3 + 1]
            rgba[pixel * 4 + 2] = rgb[pixel * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw InferenceFailure.backendFailed("Could not create the generated image.")
        }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw InferenceFailure.backendFailed("Could not create a PNG encoder.")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else {
            throw InferenceFailure.backendFailed("PNG encoding failed.")
        }
        let result = data as Data
        try validate(result, width: width, height: height)
        return result
    }

    static func validate(_ data: Data, width: Int, height: Int) throws {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source), (type as String) == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height,
              let pixels = image.dataProvider?.data, CFDataGetLength(pixels) > 0 else {
            throw InferenceFailure.backendFailed("Generated PNG failed decoding or dimension validation.")
        }
    }
}

/// One private directory anchored by file descriptors. Only files created by this transaction
/// can be removed. The host explicitly requests cleanup; backend release never removes images.
internal final class ImageArtifactTransaction {
    let directory: URL
    private let root: URL
    private let name: String
    private let rootFD: Int32
    private let directoryFD: Int32
    private var temporaryIdentity: stat?
    private let temporaryName = ".image.partial"
    private(set) var published = false
    private var cleanedUp = false

    static func validateRoot(_ root: URL, model: URL? = nil) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0") else {
            throw InferenceFailure.invalidRequest("Artifact directory must be an absolute local directory.")
        }
        let canonical = root.standardizedFileURL
        if let model {
            let modelPath = model.standardizedFileURL.path
            guard canonical.path != modelPath, !canonical.path.hasPrefix(modelPath + "/") else {
                throw InferenceFailure.invalidRequest("Artifacts must be outside the installed model directory.")
            }
        }
        let fd = try openDirectory(canonical)
        close(fd)
    }

    init(root: URL, requestID: UUID) throws {
        self.root = root.standardizedFileURL
        name = requestID.uuidString + "-" + UUID().uuidString
        directory = root.appendingPathComponent(name, isDirectory: true)
        let parent = try Self.openDirectory(root)
        guard mkdirat(parent, name, 0o700) == 0 else {
            close(parent)
            throw Self.ioFailure("Create task artifact directory")
        }
        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            _ = unlinkat(parent, name, AT_REMOVEDIR)
            close(parent)
            throw Self.ioFailure("Open task artifact directory")
        }
        rootFD = parent
        directoryFD = child
    }

    deinit { close(directoryFD); close(rootFD) }

    func publish(_ png: Data, width: Int, height: Int) throws -> ArtifactReference {
        guard !published, !cleanedUp, temporaryIdentity == nil else {
            throw InferenceFailure.backendFailed("Artifact transaction was already used.")
        }
        try validateLocations()
        try Task.checkCancellation()
        let fd = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.ioFailure("Create temporary image") }
        defer { close(fd) }
        var identity = stat()
        guard fstat(fd, &identity) == 0 else { throw Self.ioFailure("Inspect temporary image") }
        temporaryIdentity = identity
        try png.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.ioFailure("Write generated image (check disk space and external drive)") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Self.ioFailure("Flush generated image to disk") }
        let savedIdentity = try readAndValidate(temporaryName, expected: identity, png: png, width: width, height: height)
        try Task.checkCancellation()
        try validateLocations()
        var currentTemporary = stat()
        guard fstatat(directoryFD, temporaryName, &currentTemporary, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameVersion(savedIdentity, currentTemporary), currentTemporary.st_mode & S_IFMT == S_IFREG else {
            throw InferenceFailure.backendFailed("Temporary image changed before publication.")
        }
        guard renameatx_np(directoryFD, temporaryName, directoryFD, "image.png", UInt32(RENAME_EXCL)) == 0 else {
            throw Self.ioFailure("Publish image without overwriting an existing file")
        }
        // Ownership changes immediately at rename, including if later notification/cleanup fails.
        published = true
        temporaryIdentity = nil
        do {
            guard fsync(directoryFD) == 0 else { throw Self.ioFailure("Flush image directory") }
            try validateLocations()
            // Recheck the published name as well. A pre-rename stat alone is not an
            // atomic identity condition on rename; never return an unvalidated replacement.
            _ = try readAndValidate("image.png", expected: identity, png: png, width: width, height: height)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw InferenceFailure.backendFailed(
                "Image publication completed at \(directory.path), but final verification failed: \(error.localizedDescription). The published file was preserved."
            )
        }
        return ArtifactReference(url: directory.appendingPathComponent("image.png"), mediaType: "image/png")
    }

    func cleanupUnpublished() throws {
        guard !published, !cleanedUp else { return }
        try validateLocations()
        if let expected = temporaryIdentity {
            var actual = stat()
            if fstatat(directoryFD, temporaryName, &actual, AT_SYMLINK_NOFOLLOW) == 0 {
                guard Self.same(expected, actual), actual.st_mode & S_IFMT == S_IFREG else {
                    throw InferenceFailure.backendFailed("Refusing to remove a replaced temporary artifact.")
                }
                guard unlinkat(directoryFD, temporaryName, 0) == 0 else { throw Self.ioFailure("Remove temporary image") }
            } else if errno != ENOENT { throw Self.ioFailure("Inspect temporary image for cleanup") }
            temporaryIdentity = nil
        }
        // Never recurse. An unexpected or published file makes the directory nonempty and is preserved.
        guard unlinkat(rootFD, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw Self.ioFailure("Remove empty task directory")
        }
        cleanedUp = true
    }

    /// Bounded reads avoid consuming an arbitrarily growing replacement. O_NONBLOCK
    /// also keeps an unexpected FIFO from hanging before the regular-file check.
    private func readAndValidate(_ filename: String, expected: stat, png: Data, width: Int, height: Int) throws -> stat {
        let fd = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.ioFailure("Read saved image") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, Self.same(expected, before),
              before.st_mode & S_IFMT == S_IFREG, before.st_size == png.count else {
            throw InferenceFailure.backendFailed("Saved image was replaced before validation.")
        }
        var saved = Data()
        var buffer = [UInt8](repeating: 0, count: min(max(png.count, 1), 1024 * 1024))
        while saved.count < png.count {
            try Task.checkCancellation()
            let length = min(buffer.count, png.count - saved.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, length) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Self.ioFailure("Read complete saved image") }
            saved.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Self.sameVersion(before, after), saved == png else {
            throw InferenceFailure.backendFailed("Saved image changed or differs from the generated data.")
        }
        try ImagePNG.validate(saved, width: width, height: height)
        return after
    }

    private func validateLocations() throws {
        let currentRoot = try Self.openDirectory(root)
        defer { close(currentRoot) }
        var a = stat(), b = stat(), child = stat(), original = stat()
        guard fstat(rootFD, &a) == 0, fstat(currentRoot, &b) == 0, Self.same(a, b),
              fstatat(rootFD, name, &child, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(directoryFD, &original) == 0, Self.same(child, original),
              child.st_mode & S_IFMT == S_IFDIR else {
            throw InferenceFailure.backendFailed("Artifact directory was moved, replaced, or disconnected.")
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw InferenceFailure.invalidRequest("Invalid artifact directory.")
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ioFailure("Open filesystem root") }
        for component in url.standardizedFileURL.path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw ioFailure("Open artifact directory (must exist and contain no symbolic links)") }
            fd = next
        }
        return fd
    }

    private static func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
    private static func sameVersion(_ a: stat, _ b: stat) -> Bool {
        same(a, b) && a.st_size == b.st_size && a.st_mode == b.st_mode
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func ioFailure(_ action: String) -> InferenceFailure {
        .backendFailed("\(action): \(String(cString: strerror(errno)))")
    }
}
