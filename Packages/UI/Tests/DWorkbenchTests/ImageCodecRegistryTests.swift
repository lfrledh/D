import CoreGraphics
import DWorkbench
import Foundation
import Testing

@Suite("Image codec registry")
struct ImageCodecRegistryTests {
    @Test func standardRegistryPublishesStableFormatIDs() {
        #expect(ImageCodecRegistry.standard.formatIDs == ["png", "jpeg"])
        #expect(ImageCodecRegistry.standard.codec(formatID: "png")?.mediaType == "image/png")
        #expect(ImageCodecRegistry.standard.codec(formatID: "jpeg")?.mediaType == "image/jpeg")
        #expect(ImageCodecRegistry.standard.codec(formatID: "missing") == nil)
    }

    @Test func injectableFixtureCodecCanBeDetectedWithoutClaimingProductionSupport() throws {
        let fixture = FixtureCodec(
            formatID: "fixture",
            typeIdentifier: "org.example.fixture",
            signature: Data([0x44, 0x46, 0x58]))
        let registry = try ImageCodecRegistry(codecs: [fixture])

        #expect(registry.formatIDs == ["fixture"])
        #expect(try registry.codec(detecting: Data([0x44, 0x46, 0x58, 0x01])).formatID
                == "fixture")
        #expect(throws: ImageCodecRegistryError.unsupportedFormat) {
            try registry.codec(detecting: Data([0x00, 0x01]))
        }
    }

    @Test func duplicateFormatIDIsRejected() {
        let first = FixtureCodec(
            formatID: "fixture",
            typeIdentifier: "org.example.fixture-a",
            signature: Data([0x01]))
        let second = FixtureCodec(
            formatID: "fixture",
            typeIdentifier: "org.example.fixture-b",
            signature: Data([0x02]))

        #expect(throws: ImageCodecRegistryError.duplicateFormatID("fixture")) {
            try ImageCodecRegistry(codecs: [first, second])
        }
    }

    @Test func duplicateTypeIdentifierIsRejectedCaseInsensitively() {
        let first = FixtureCodec(
            formatID: "fixture-a",
            typeIdentifier: "org.example.Fixture",
            signature: Data([0x01]))
        let second = FixtureCodec(
            formatID: "fixture-b",
            typeIdentifier: "org.example.fixture",
            signature: Data([0x02]))

        #expect(throws: ImageCodecRegistryError.duplicateTypeIdentifier("org.example.fixture")) {
            try ImageCodecRegistry(codecs: [first, second])
        }
    }

    @Test func ambiguousSignatureIsRejectedWithDeterministicIDs() throws {
        let first = FixtureCodec(
            formatID: "fixture-z",
            typeIdentifier: "org.example.fixture-z",
            signature: Data([0x44, 0x46]))
        let second = FixtureCodec(
            formatID: "fixture-a",
            typeIdentifier: "org.example.fixture-a",
            signature: Data([0x44]))
        let registry = try ImageCodecRegistry(codecs: [first, second])

        #expect(throws: ImageCodecRegistryError.ambiguousSignature(
            ["fixture-a", "fixture-z"])) {
            try registry.codec(detecting: Data([0x44, 0x46, 0x01]))
        }
    }
}

private struct FixtureCodec: ImageCodec {
    let formatID: String
    let mediaType = "application/x-fixture"
    let typeIdentifier: String
    let alphaPolicy = ImageCodecAlphaPolicy.preserve
    let signature: Data

    func matchesSignature(_ data: Data) -> Bool {
        data.starts(with: signature)
    }

    func encodingOptions(
        quality: WorkflowScalar?,
        background: WorkflowScalar?
    ) throws -> ImageCodecEncodingOptions {
        ImageCodecEncodingOptions(quality: nil, background: nil)
    }

    func encode(_ image: CGImage, options: ImageCodecEncodingOptions) throws -> Data {
        throw FixtureError.encodingIsNotPartOfThisFixture
    }

    private enum FixtureError: Error {
        case encodingIsNotPartOfThisFixture
    }
}
