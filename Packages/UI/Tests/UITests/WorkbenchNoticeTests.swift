import CryptoKit
import Foundation
import Testing
@testable import UI

struct WorkbenchNoticeTests {
    @Test func linkedModelAndJSONCopyrightNoticesShipInActualUIResource() throws {
        let notice = try WorkbenchNoticeReader.bundledChatNotice()
        for original in ["Copyright (c) 2023 ml-explore", "Copyright (c) 2024 ml-explore", "Copyright (c) 2013-2022 Niels Lohmann"] {
            #expect(notice.contains(original))
        }
        #expect(notice.contains("Vendor/mlx-swift/LICENSE"))
        #expect(notice.contains("Vendor/mlx-swift-lm/LICENSE"))
        #expect(notice.contains("Vendor/mlx-swift/Source/Cmlx/json/LICENSE.MIT"))
    }

    @Test func noticeTextValidatesDeclaredBytesAndRejectsTraversalAndLinks() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]!).appendingPathComponent("notices-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("Original license 原文".utf8), url = root.appendingPathComponent("LICENSE")
        try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = WorkbenchNoticeFile(group: "fixture", relativePath: "LICENSE", root: root, byteCount: bytes.count, sha256: digest)
        #expect(try WorkbenchNoticeReader.text(file) == "Original license 原文")
        #expect(throws: (any Error).self) { try WorkbenchNoticeReader.location(root: root, relative: "../LICENSE") }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: url)
        #expect(throws: (any Error).self) { try WorkbenchNoticeReader.location(root: root, relative: "link") }
        let linkedRoot = root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        #expect(throws: (any Error).self) { try WorkbenchNoticeReader.location(root: linkedRoot, relative: "LICENSE") }
        try Data("Changed license".utf8).write(to: url)
        #expect(throws: (any Error).self) { try WorkbenchNoticeReader.text(file) }
    }
    @Test func noticeIndexIncludesRealLicenseAndSourceNamingWithoutScanningUnlistedFiles() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]!).appendingPathComponent("notice-index-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ui/Mermaid"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Chat-Third-Party-Notices.txt", "Mermaid/THIRD-PARTY-NOTICES.txt", "Mermaid/LICENSE"] { try Data("notice".utf8).write(to: root.appendingPathComponent("ui/" + path)) }
        let engine = root.appendingPathComponent("Engines/ExternalVideoEngine.dengine")
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        let names = ["Licenses/h3-MIT.txt", "Licenses/libvmaf-BSD-2-Clause-Patent.txt", "Licenses/libvmaf-no-models.json", "tqdm/licenses/LICENCE", "vendor/SOURCE.json", "Licenses/ffmpeg-9.0.1-homebrew.rb"]
        let files = names.map { ["path": $0, "sizeBytes": 6, "sha256": String(repeating: "a", count: 64)] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["files": files]).write(to: engine.appendingPathComponent("engine.json"))
        try Data("unlisted".utf8).write(to: engine.appendingPathComponent("UNLISTED-LICENSE"))
        let index = try WorkbenchNoticeReader.index(engines: root.appendingPathComponent("Engines"), ui: root.appendingPathComponent("ui"))
        #expect(Set(index.filter { $0.group == "ExternalVideoEngine" }.map(\.relativePath)) == Set(names))
    }

}
