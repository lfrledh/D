import Foundation
import Testing
@testable import DWorkbench

@Suite("Fixed text model registration rejection")
struct FixedTextModelTests {
    @Test func missingAndExtraFilesNeverRegisterAsTheApprovedModel() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let folder = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: (any Error).self) { try await FixedTextModel.verify(at: folder) }
        let marker = folder.appendingPathComponent("不能当权重.txt")
        let bytes = Data("不修改输入".utf8)
        try bytes.write(to: marker)
        await #expect(throws: (any Error).self) { try await FixedTextModel.verify(at: folder) }
        #expect(try Data(contentsOf: marker) == bytes)
    }
}

@Suite("Explicit existing text weights: CPU checksums, no inference")
struct ExistingTextModelChecksumTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_TEST_TEXT_MODEL"] != nil))
    func approvedInstalledWeightsRemainUnchanged() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["D_TEST_TEXT_MODEL"])
        let directory = URL(fileURLWithPath: path)
        let names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        func snapshot() throws -> [String] {
            try names.map { name in
                let info = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
                return "\(name):\(info[.size]!):\(info[.modificationDate]!)"
            }
        }
        let before = try snapshot()
        let reference = try await FixedTextModel.verify(at: directory)
        #expect(reference.revision == "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3")
        #expect(reference.directory == directory)
        #expect(try snapshot() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path).sorted() == names)
    }
}
