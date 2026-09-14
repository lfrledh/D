import Darwin
import Foundation
import Testing
@testable import DWorkbench

@Suite("Bounded text source reading")
struct TextSourceReaderTests {
    @Test func preservesUnicodeBOMCRLFAndSourceWhileAcceptingEmojiZWJFilename() throws {
        try withTextSourceFixture { directory in
            let file = directory.appendingPathComponent("研究 👩‍💻 Notes.MD")
            let decoded = "第一行\r\nCafe e\u{301}\r\n结束"
            var original = Data([0xEF, 0xBB, 0xBF])
            original.append(Data(decoded.utf8))
            try original.write(to: file)
            let permissions = try posixPermissions(at: file)

            let first = try TextSourceReader.read(at: file)
            let second = try TextSourceReader.read(at: file)

            #expect(first.displayName == "研究 👩‍💻 Notes.MD")
            #expect(first.bytes == original)
            #expect(try first.validatedText() == decoded)
            #expect(second.bytes == first.bytes)
            #expect(second.sha256 == first.sha256)
            #expect(second.id != first.id)
            #expect(second.revision != first.revision)
            #expect(try Data(contentsOf: file) == original)
            #expect(try posixPermissions(at: file) == permissions)

            let whole = try TextSourceReader.excerpt(from: first)
            #expect(whole.text == decoded)
            try whole.validate(against: first)

            let emojiRange = try #require(decoded.range(of: "e\u{301}"))
            let excerpt = try TextSourceReader.excerpt(
                from: first,
                range: NSRange(emojiRange, in: decoded)
            )
            #expect(excerpt.text == "e\u{301}")
            try excerpt.validate(against: first)
        }
    }

    @Test func acceptsExactLimitAndRejectsEmptyOversizedInvalidUTF8AndNUL() throws {
        try withTextSourceFixture { directory in
            let maximum = directory.appendingPathComponent("maximum.txt")
            try Data(repeating: 0x61, count: TextSourcesLimits.sourceBytes).write(to: maximum)
            #expect(try TextSourceReader.read(at: maximum).bytes.count == TextSourcesLimits.sourceBytes)

            let empty = directory.appendingPathComponent("empty.md")
            try Data().write(to: empty)
            #expect(throws: TextSourcesError.self) { try TextSourceReader.read(at: empty) }

            let oversized = directory.appendingPathComponent("oversized.markdown")
            try Data(repeating: 0x61, count: TextSourcesLimits.sourceBytes + 1).write(to: oversized)
            #expect(throws: TextSourcesError.self) { try TextSourceReader.read(at: oversized) }

            let invalidUTF8 = directory.appendingPathComponent("invalid.txt")
            try Data([0xC3, 0x28]).write(to: invalidUTF8)
            #expect(throws: TextSourcesError.self) { try TextSourceReader.read(at: invalidUTF8) }

            let nul = directory.appendingPathComponent("nul.md")
            try Data([0x61, 0, 0x62]).write(to: nul)
            #expect(throws: TextSourcesError.self) { try TextSourceReader.read(at: nul) }
        }
    }

    @Test func rejectsNonlocalAmbiguousAndUnsupportedURLs() throws {
        try withTextSourceFixture { directory in
            let unsupported = directory.appendingPathComponent("source.rtf")
            try Data("text".utf8).write(to: unsupported)
            #expect(throws: TextSourcesError.self) { try TextSourceReader.read(at: unsupported) }
            #expect(throws: TextSourcesError.self) {
                try TextSourceReader.read(at: URL(string: "relative.txt")!)
            }
            #expect(throws: TextSourcesError.self) {
                try TextSourceReader.read(at: URL(string: "https://example.invalid/source.txt")!)
            }

            let source = directory.appendingPathComponent("source.txt")
            try Data("text".utf8).write(to: source)
            var query = try #require(URLComponents(url: source, resolvingAgainstBaseURL: false))
            query.query = "revision=1"
            #expect(throws: TextSourcesError.self) {
                try TextSourceReader.read(at: try #require(query.url))
            }
            var fragment = try #require(URLComponents(url: source, resolvingAgainstBaseURL: false))
            fragment.fragment = "selection"
            #expect(throws: TextSourcesError.self) {
                try TextSourceReader.read(at: try #require(fragment.url))
            }
        }
    }

    @Test func rejectsDirectAndAncestorSymlinksDirectoriesAndFIFO() throws {
        try withTextSourceFixture { directory in
            let realDirectory = directory.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
            let original = realDirectory.appendingPathComponent("original.txt")
            try Data("source".utf8).write(to: original)

            let directLink = directory.appendingPathComponent("direct.txt")
            try FileManager.default.createSymbolicLink(at: directLink, withDestinationURL: original)
            #expect(throws: TextSourcesError.self) { try TextSourceReader.read(at: directLink) }

            let ancestorLink = directory.appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: realDirectory)
            #expect(throws: TextSourcesError.self) {
                try TextSourceReader.read(at: ancestorLink.appendingPathComponent("original.txt"))
            }

            let directoryWithExtension = directory.appendingPathComponent("folder.md", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryWithExtension, withIntermediateDirectories: false)
            #expect(throws: TextSourcesError.self) {
                try TextSourceReader.read(at: directoryWithExtension)
            }

            let fifo = directory.appendingPathComponent("pipe.txt")
            try #require(mkfifo(fifo.path, 0o600) == 0)
            #expect(throws: TextSourcesError.self) { try TextSourceReader.read(at: fifo) }
        }
    }

    @Test func excerptRejectsEmptyOutOfBoundsAndNonCharacterAlignedRanges() throws {
        let source = try TextSourceSnapshot(displayName: "selection.txt", bytes: Data("A👩‍💻B".utf8))
        #expect(throws: Error.self) {
            try TextSourceReader.excerpt(from: source, range: NSRange(location: 0, length: 0))
        }
        #expect(throws: Error.self) {
            try TextSourceReader.excerpt(from: source, range: NSRange(location: 0, length: 100))
        }
        #expect(throws: Error.self) {
            try TextSourceReader.excerpt(from: source, range: NSRange(location: 2, length: 1))
        }
    }
}

private func withTextSourceFixture(_ body: (URL) throws -> Void) throws {
    let base = ProcessInfo.processInfo.environment["D_TEST_WORKBENCH_ROOT"]
        ?? ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("D-Workbench-Text-Source-Tests", isDirectory: true).path
    let directory = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory.resolvingSymlinksInPath())
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}
