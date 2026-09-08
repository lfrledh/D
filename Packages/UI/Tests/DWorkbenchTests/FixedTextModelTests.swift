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
