@testable import DMLXBackend
import CryptoKit
import Darwin
import DInference
import Foundation
import Testing

@Suite("Frozen RGB image reference input")
struct ImageReferenceBackendTests {
    @Test("Reads the declared inode once and preserves exact RGB bytes")
    func readsValidInput() throws {
        let fixture = try Fixture()
        let loaded = try ImageReferenceInput.load(fixture.reference)
        #expect(loaded.rgb == fixture.rgb)
        #expect(loaded.sha256 == fixture.digest)
        #expect(loaded.width == 256)
        #expect(loaded.height == 256)
        #expect(loaded.encoding == "rgb8-srgb-v1")
    }

    @Test("Rejects digest mismatch without returning pixels")
    func rejectsDigestMismatch() throws {
        let fixture = try Fixture()
        let reference = ImageReference(url: fixture.file, sha256: String(repeating: "0", count: 64),
                                       byteCount: UInt64(fixture.rgb.count), width: 256, height: 256)
        #expect(throws: InferenceFailure.self) { try ImageReferenceInput.load(reference) }
    }

    @Test("Rejects a regular file whose actual length differs from the frozen declaration")
    func rejectsLengthMismatch() throws {
        let fixture = try Fixture(bytes: Data(repeating: 7, count: 256 * 256 * 3 - 1),
                                  declaredDigestForFullSize: true)
        #expect(throws: InferenceFailure.self) { try ImageReferenceInput.load(fixture.reference) }
    }

    @Test("Rejects a symbolic-link leaf")
    func rejectsSymbolicLink() throws {
        let fixture = try Fixture()
        let link = fixture.root.appendingPathComponent("reference-link.rgb")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)
        let reference = ImageReference(url: link, sha256: fixture.digest,
                                       byteCount: UInt64(fixture.rgb.count), width: 256, height: 256)
        #expect(throws: InferenceFailure.self) { try ImageReferenceInput.load(reference) }
    }

    @Test("Rejects hard-linked substitution")
    func rejectsHardLink() throws {
        let fixture = try Fixture()
        let hardLink = fixture.root.appendingPathComponent("reference-hardlink.rgb")
        try #require(Darwin.link(fixture.file.path, hardLink.path) == 0)
        let reference = ImageReference(url: hardLink, sha256: fixture.digest,
                                       byteCount: UInt64(fixture.rgb.count), width: 256, height: 256)
        #expect(throws: InferenceFailure.self) { try ImageReferenceInput.load(reference) }
    }

    @Test("Rejects a symbolic-link ancestor")
    func rejectsSymbolicLinkAncestor() throws {
        let fixture = try Fixture()
        let linkedDirectory = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("linked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linkedDirectory) }
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: fixture.root)
        let linkedFile = linkedDirectory.appendingPathComponent(fixture.file.lastPathComponent)
        let reference = ImageReference(url: linkedFile, sha256: fixture.digest,
                                       byteCount: UInt64(fixture.rgb.count), width: 256, height: 256)
        #expect(throws: InferenceFailure.self) { try ImageReferenceInput.load(reference) }
    }

    private final class Fixture {
        let root: URL
        let file: URL
        let rgb: Data
        let digest: String
        let reference: ImageReference

        init(bytes: Data = Data((0..<(256 * 256 * 3)).map { UInt8($0 % 251) }),
             declaredDigestForFullSize: Bool = false) throws {
            let parent = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory
            root = parent
                .appendingPathComponent("d-image-reference-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            file = root.appendingPathComponent("reference.rgb")
            try bytes.write(to: file, options: .withoutOverwriting)
            rgb = bytes
            let digestBytes = declaredDigestForFullSize
                ? Data(repeating: 7, count: 256 * 256 * 3) : bytes
            digest = SHA256.hash(data: digestBytes).map { String(format: "%02x", $0) }.joined()
            reference = ImageReference(url: file, sha256: digest,
                                       byteCount: UInt64(256 * 256 * 3), width: 256, height: 256)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }
}
