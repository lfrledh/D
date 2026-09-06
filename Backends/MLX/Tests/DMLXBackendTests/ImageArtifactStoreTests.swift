import CoreGraphics
import Darwin
import DInference
@testable import DMLXBackend
import Foundation
import ImageIO
import Testing

@Suite("CPU PNG artifacts and filesystem ownership")
struct ImageArtifactStoreTests {
    private static let rgb: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0]

    @Test("Known 2 x 2 RGB pixels survive PNG encoding and independent decoding")
    func pngPixels() throws {
        let png = try ImagePNG.encode(rgb: Self.rgb, width: 2, height: 2)
        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let image = try decodedPNG(png)
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(try RGBPixels(image) == Self.rgb)
    }

    @Test("Invalid RGB dimensions and byte counts fail before encoding", arguments: ["zero", "negative", "oversized", "count"])
    func invalidRGB(kind: String) {
        expectArtifactFailure {
            _ = try ImagePNG.encode(rgb: kind == "count" ? [1, 2] : Self.rgb,
                                    width: kind == "zero" ? 0 : (kind == "negative" ? -1 : (kind == "oversized" ? 16_385 : 2)),
                                    height: 2)
        }
    }

    @Test("Corrupt, truncated and incorrectly sized PNG data are rejected", arguments: ["corrupt", "truncated", "dimensions"])
    func invalidPNG(kind: String) throws {
        let valid = try ImagePNG.encode(rgb: Self.rgb, width: 2, height: 2)
        let data = kind == "corrupt" ? Data("not a PNG".utf8) : (kind == "truncated" ? Data(valid.prefix(16)) : valid)
        expectArtifactFailure {
            try ImagePNG.validate(data, width: kind == "dimensions" ? 3 : 2, height: 2)
        }
    }

    @Test("Publishing creates a readable PNG that cleanup and deinit leave with the host")
    func publishedOwnership() throws {
        let fixture = try ArtifactDirectoryFixture()
        defer { fixture.remove() }
        let png = try ImagePNG.encode(rgb: Self.rgb, width: 2, height: 2)
        let artifact: ArtifactReference
        do {
            let transaction = try ImageArtifactTransaction(root: fixture.root, requestID: UUID())
            artifact = try transaction.publish(png, width: 2, height: 2)
            #expect(transaction.published)
            #expect(artifact.url == transaction.directory.appendingPathComponent("image.png"))
            #expect(artifact.mediaType == "image/png")
            #expect(try RGBPixels(decodedPNG(Data(contentsOf: artifact.url))) == Self.rgb)
            try transaction.cleanupUnpublished()
            try transaction.cleanupUnpublished()
            #expect(try Data(contentsOf: artifact.url) == png)
        }
        #expect(try Data(contentsOf: artifact.url) == png)
    }

    @Test("Reusing a request UUID allocates independent transaction directories")
    func repeatedRequestID() throws {
        let fixture = try ArtifactDirectoryFixture()
        defer { fixture.remove() }
        let id = UUID()
        let first = try ImageArtifactTransaction(root: fixture.root, requestID: id)
        let second = try ImageArtifactTransaction(root: fixture.root, requestID: id)
        #expect(first.directory != second.directory)
        #expect(first.directory.lastPathComponent.hasPrefix(id.uuidString + "-"))
        #expect(second.directory.lastPathComponent.hasPrefix(id.uuidString + "-"))
        let png = try ImagePNG.encode(rgb: Self.rgb, width: 2, height: 2)
        let a = try first.publish(png, width: 2, height: 2)
        let b = try second.publish(png, width: 2, height: 2)
        #expect(a.url != b.url)
        #expect(try Data(contentsOf: a.url) == Data(contentsOf: b.url))
    }

    @Test("Failed PNG validation leaves only owned temporary data for explicit host cleanup")
    func failedPublishCleanup() throws {
        let fixture = try ArtifactDirectoryFixture()
        defer { fixture.remove() }
        let transaction = try ImageArtifactTransaction(root: fixture.root, requestID: UUID())
        expectArtifactFailure { _ = try transaction.publish(Data("invalid PNG".utf8), width: 2, height: 2) }
        #expect(!transaction.published)
        #expect(FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent(".image.partial").path))
        #expect(!FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("image.png").path))
        try transaction.cleanupUnpublished()
        #expect(!FileManager.default.fileExists(atPath: transaction.directory.path))
        try transaction.cleanupUnpublished()
        expectArtifactFailure(containing: "already used") {
            _ = try transaction.publish(ImagePNG.encode(rgb: Self.rgb, width: 2, height: 2), width: 2, height: 2)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test("An existing image.png is neither overwritten nor deleted by cleanup")
    func existingPublishedName() throws {
        let fixture = try ArtifactDirectoryFixture()
        defer { fixture.remove() }
        let transaction = try ImageArtifactTransaction(root: fixture.root, requestID: UUID())
        let image = transaction.directory.appendingPathComponent("image.png")
        let sentinel = Data("host-owned existing image".utf8)
        try sentinel.write(to: image)
        expectArtifactFailure(containing: "without overwriting") {
            _ = try transaction.publish(ImagePNG.encode(rgb: Self.rgb, width: 2, height: 2), width: 2, height: 2)
        }
        #expect(!transaction.published)
        expectArtifactFailure { try transaction.cleanupUnpublished() }
        #expect(try Data(contentsOf: image) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent(".image.partial").path))
    }

    @Test("Failure to create a temporary file preserves the preexisting occupant")
    func existingTemporaryName() throws {
        let fixture = try ArtifactDirectoryFixture()
        defer { fixture.remove() }
        let transaction = try ImageArtifactTransaction(root: fixture.root, requestID: UUID())
        let temporary = transaction.directory.appendingPathComponent(".image.partial")
        let sentinel = Data("not created by this transaction".utf8)
        try sentinel.write(to: temporary)
        expectArtifactFailure(containing: "Create temporary image") {
            _ = try transaction.publish(ImagePNG.encode(rgb: Self.rgb, width: 2, height: 2), width: 2, height: 2)
        }
        expectArtifactFailure { try transaction.cleanupUnpublished() }
        #expect(try Data(contentsOf: temporary) == sentinel)
    }

    @Test("Replaced temporary files and symlinks are not removed", arguments: [false, true])
    func replacedTemporary(symlink: Bool) throws {
        let fixture = try ArtifactDirectoryFixture()
        defer { fixture.remove() }
        let transaction = try ImageArtifactTransaction(root: fixture.root, requestID: UUID())
        expectArtifactFailure { _ = try transaction.publish(Data("invalid PNG".utf8), width: 2, height: 2) }
        let temporary = transaction.directory.appendingPathComponent(".image.partial")
        let original = fixture.base.appendingPathComponent("original-partial")
        try FileManager.default.moveItem(at: temporary, to: original)
        let target = fixture.base.appendingPathComponent("sentinel")
        let sentinel = Data("keep this replacement".utf8)
        try sentinel.write(to: target)
        if symlink {
            try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: target)
        } else {
            try sentinel.write(to: temporary)
        }
        expectArtifactFailure(containing: "replaced temporary") { try transaction.cleanupUnpublished() }
        #expect(try Data(contentsOf: target) == sentinel)
        #expect(try Data(contentsOf: temporary) == sentinel)
        #expect(try Data(contentsOf: original) == Data("invalid PNG".utf8))
        if symlink {
            #expect(try temporary.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        }
    }

    @Test("Replacing a task directory or its parent cannot redirect cleanup", arguments: ["task", "parent", "symlink"])
    func replacedDirectory(kind: String) throws {
        let fixture = try ArtifactDirectoryFixture()
        defer { fixture.remove() }
        let transaction = try ImageArtifactTransaction(root: fixture.root, requestID: UUID())
        expectArtifactFailure { _ = try transaction.publish(Data("invalid PNG".utf8), width: 2, height: 2) }
        let manager = FileManager.default
        let sentinel = Data("unrelated directory contents".utf8)
        let moved = fixture.base.appendingPathComponent("moved")
        let originalTemporary: URL
        let replacement: URL
        if kind == "parent" {
            try manager.moveItem(at: fixture.root, to: moved)
            replacement = transaction.directory
            try manager.createDirectory(at: replacement, withIntermediateDirectories: true)
            originalTemporary = moved.appendingPathComponent(transaction.directory.lastPathComponent).appendingPathComponent(".image.partial")
        } else {
            try manager.moveItem(at: transaction.directory, to: moved)
            originalTemporary = moved.appendingPathComponent(".image.partial")
            if kind == "symlink" {
                replacement = fixture.base.appendingPathComponent("replacement")
                try manager.createDirectory(at: replacement, withIntermediateDirectories: false)
                try manager.createSymbolicLink(at: transaction.directory, withDestinationURL: replacement)
            } else {
                replacement = transaction.directory
                try manager.createDirectory(at: replacement, withIntermediateDirectories: false)
            }
        }
        let sentinelURL = replacement.appendingPathComponent(".image.partial")
        try sentinel.write(to: sentinelURL)
        expectArtifactFailure { try transaction.cleanupUnpublished() }
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(try Data(contentsOf: originalTemporary) == Data("invalid PNG".utf8))
        #expect(FileManager.default.fileExists(atPath: replacement.path))
    }

    @Test("Nonexistent roots, files and symbolic-link roots are rejected", arguments: ["missing", "file", "symlink"])
    func invalidRoot(kind: String) throws {
        let fixture = try ArtifactDirectoryFixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("invalid-root")
        if kind == "file" {
            try Data("keep".utf8).write(to: root)
        } else if kind == "symlink" {
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: fixture.root)
        }
        expectArtifactFailure { try ImageArtifactTransaction.validateRoot(root) }
        expectArtifactFailure { _ = try ImageArtifactTransaction(root: root, requestID: UUID()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        if kind == "missing" { #expect(!FileManager.default.fileExists(atPath: root.path)) }
        if kind == "file" { #expect(try Data(contentsOf: root) == Data("keep".utf8)) }
    }

    @Test("Artifact roots cannot be inside the model installation")
    func modelRootRejected() throws {
        let fixture = try ArtifactDirectoryFixture()
        defer { fixture.remove() }
        expectArtifactFailure { try ImageArtifactTransaction.validateRoot(fixture.root, model: fixture.base) }
        expectArtifactFailure { try ImageArtifactTransaction.validateRoot(fixture.root, model: fixture.root) }
    }

    @Test("Permission-denied writes fail without creating a published image", .enabled(if: geteuid() != 0))
    func writePermissionDenied() throws {
        let fixture = try ArtifactDirectoryFixture()
        defer { fixture.remove() }
        let transaction = try ImageArtifactTransaction(root: fixture.root, requestID: UUID())
        #expect(chmod(transaction.directory.path, 0o500) == 0)
        defer { _ = chmod(transaction.directory.path, 0o700) }
        expectArtifactFailure(containing: "Create temporary image") {
            _ = try transaction.publish(ImagePNG.encode(rgb: Self.rgb, width: 2, height: 2), width: 2, height: 2)
        }
        #expect(!transaction.published)
        #expect(!FileManager.default.fileExists(atPath: transaction.directory.appendingPathComponent("image.png").path))
        #expect(chmod(transaction.directory.path, 0o700) == 0)
        try transaction.cleanupUnpublished()
    }
}

private struct ArtifactDirectoryFixture {
    let base: URL
    let root: URL

    init() throws {
        let parent = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        base = parent.resolvingSymlinksInPath()
            .appendingPathComponent("D-image-artifacts-\(UUID().uuidString)")
        root = base.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

private func decodedPNG(_ data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
}

private func RGBPixels(_ image: CGImage) throws -> [UInt8] {
    var rgb: [UInt8] = []
    for y in 0..<image.height {
        for x in 0..<image.width {
            // Crop individual pixels to avoid CGContext's coordinate orientation
            // becoming part of the expected row ordering in this PNG test.
            let pixel = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            var bytes = [UInt8](repeating: 0, count: 4)
            try bytes.withUnsafeMutableBytes { storage in
                let context = try #require(CGContext(data: storage.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            #expect(bytes[3] == 255)
            rgb.append(contentsOf: bytes.prefix(3))
        }
    }
    return rgb
}

private func expectArtifactFailure(containing text: String? = nil, _ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected image artifact failure")
    } catch let failure as InferenceFailure {
        if let text { #expect(failure.localizedDescription.contains(text)) }
    } catch {
        Issue.record("Expected an InferenceFailure, received \(error)")
    }
}
