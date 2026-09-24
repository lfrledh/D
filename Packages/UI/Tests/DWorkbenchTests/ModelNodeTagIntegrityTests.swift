import Foundation
import Testing
@testable import DWorkbench

@Suite("Model node tag record integrity", .serialized)
struct ModelNodeTagIntegrityTests {
    @MainActor
    @Test func readStateDistinguishesMissingValidAndCorruptRecordsAcrossReopen() throws {
        let suiteName = "D.ModelNodeTagIntegrityTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let store = ModelNodeTagStore(settings: settings)

        #expect(store.readState(for: "missing") == .missing)
        try store.setTags(["  人声  ", "🎛️", "e\u{301}"], for: "good-model")

        let reopenedSettings = try #require(UserDefaults(suiteName: suiteName))
        let reopenedStore = ModelNodeTagStore(settings: reopenedSettings)
        #expect(reopenedStore.readState(for: "good-model") == .valid(["人声", "🎛️", "e\u{301}"]))

        let wrongType = Data([0x00, 0x01, 0x02])
        reopenedSettings.set(wrongType, forKey: Self.key("wrong-type"))
        #expect(reopenedStore.readState(for: "wrong-type") == .corrupt)
        #expect(reopenedSettings.data(forKey: Self.key("wrong-type")) == wrongType)

        reopenedSettings.set(["可读", 7] as [Any], forKey: Self.key("partly-corrupt-type"))
        #expect(reopenedStore.readState(for: "partly-corrupt-type") == .corrupt)
        let preservedMixed = try #require(reopenedSettings.array(forKey: Self.key("partly-corrupt-type")))
        #expect(preservedMixed.first as? String == "可读")
        #expect(preservedMixed.count == 2)
        #expect(preservedMixed[1] as? Int == 7)

        reopenedSettings.set(["可读", " \n "], forKey: Self.key("partly-corrupt-value"))
        #expect(reopenedStore.readState(for: "partly-corrupt-value") == .corrupt)
        #expect(reopenedSettings.stringArray(forKey: Self.key("partly-corrupt-value")) == ["可读", " \n "])

        #expect(reopenedStore.readState(for: "good-model") == .valid(["人声", "🎛️", "e\u{301}"]))
    }

    @MainActor
    @Test func everyWriteRechecksForExternalCorruptionAndPreservesRawRecord() throws {
        let suiteName = "D.ModelNodeTagIntegrityTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let store = ModelNodeTagStore(settings: settings)

        try store.setTags(["原有"], for: "model")
        try store.setTags(["另一个模型"], for: "other-model")
        #expect(store.readState(for: "model") == .valid(["原有"]))

        let rawCorruptRecord = Data([0xde, 0xad, 0xbe, 0xef])
        settings.set(rawCorruptRecord, forKey: Self.key("model"))
        #expect(store.readState(for: "model") == .corrupt)

        expectTagError(.corruptRecord) {
            try store.setTags(["替换"], for: "model")
        }
        #expect(settings.data(forKey: Self.key("model")) == rawCorruptRecord)

        expectTagError(.corruptRecord) {
            try store.setTags([], for: "model")
        }
        #expect(settings.data(forKey: Self.key("model")) == rawCorruptRecord)

        try store.setTags(["仍然隔离"], for: "other-model")
        #expect(store.readState(for: "other-model") == .valid(["仍然隔离"]))
        #expect(settings.data(forKey: Self.key("model")) == rawCorruptRecord)
    }

    @MainActor
    @Test func validationRemainsAtomicAndUsesSwiftCharacterLimits() throws {
        let suiteName = "D.ModelNodeTagIntegrityTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let store = ModelNodeTagStore(settings: settings)

        try store.setTags(["原有"], for: "model")
        expectTagError(.emptyTag) { try store.setTags([" \n\t "], for: "model") }
        expectTagError(.duplicateTag("重复")) {
            try store.setTags(["重复", " 重复 "], for: "model")
        }
        expectTagError(.tooManyTags(maximum: 24)) {
            try store.setTags((0...24).map(String.init), for: "model")
        }
        let thirtyThree = String(repeating: "界", count: 33)
        expectTagError(.tagTooLong(tag: thirtyThree, maximumCharacters: 32)) {
            try store.setTags([thirtyThree], for: "model")
        }
        #expect(store.readState(for: "model") == .valid(["原有"]))

        let twentyFourTags = (0..<24).map { "标签\($0)" }
        try store.setTags(twentyFourTags, for: "model")
        #expect(store.readState(for: "model") == .valid(twentyFourTags))

        let thirtyTwoEmoji = String(repeating: "🙂", count: 32)
        try store.setTags([thirtyTwoEmoji], for: "model")
        #expect(store.readState(for: "model") == .valid([thirtyTwoEmoji]))
        #expect(settings.stringArray(forKey: Self.key("model")) == [thirtyTwoEmoji])

        try store.setTags([], for: "model")
        #expect(store.readState(for: "model") == .missing)
        #expect(settings.object(forKey: Self.key("model")) == nil)
    }

    private static func key(_ modelID: String) -> String {
        "D.ModelNodeTags.v1." + modelID
    }

    @MainActor
    private func expectTagError(_ expected: ModelNodeTagStoreError, body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected tag write to fail with \(expected.localizedDescription)")
        } catch let error as ModelNodeTagStoreError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected tag write error: \(error)")
        }
    }
}
