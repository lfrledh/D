import Foundation
import Testing
@testable import UI

@Suite("Chat product error display")
@MainActor struct ChatErrorTextTests {
    @Test func exactChineseAndEnglishCounterpartsUseSameKey() throws {
        let (english, englishSuite) = try language("en")
        defer { englishSuite.cleanup() }
        let (chinese, chineseSuite) = try language("zh-Hans")
        defer { chineseSuite.cleanup() }

        let original = "部分回答须显式采用后才能进入上下文。"
        let instruction = "Use the partial answer explicitly before continuing with it in the context."
        #expect(ChatErrorText.display(original, language: english) == instruction)
        #expect(ChatErrorText.display(instruction, language: chinese) == original)
        #expect(ChatErrorText.display(original, language: nil) == instruction)
        #expect(ChatErrorText.display("聊天记录保存失败，请先重试保存。", language: english)
                == "Saving the chat record failed. Retry the save before continuing.")
        #expect(ChatErrorText.display("已有聊天推理或待保存结果。", language: english)
                == "Chat is generating or has a result awaiting save.")
    }

    @Test func externalPackOverridesTheSameStableKey() throws {
        let (store, suite) = try language("en")
        defer { suite.cleanup() }
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "locale": "fr", "displayName": "Français",
            "strings": ["chat.error.adoptPartial": "Utilisez explicitement la réponse partielle."],
        ])
        #expect(try store.importPack(data: data) == "fr")
        try store.select("fr")
        #expect(ChatErrorText.display("部分回答须显式采用后才能进入上下文。", language: store)
                == "Utilisez explicitement la réponse partielle.")
        #expect(ChatErrorText.display("Use the partial answer explicitly before continuing with it in the context.", language: store)
                == "Utilisez explicitement la réponse partielle.")
    }

    @Test func unknownAndUserTextAreNeverFuzzilyTranslated() throws {
        let (store, suite) = try language("en")
        defer { suite.cleanup() }
        let canary = "用户🧪：部分回答须显式采用后才能进入上下文。 / model `原文`"
        #expect(ChatErrorText.display(canary, language: store) == "Original diagnostic: " + canary)
        let backend = "Backend[β] failed: 保存失败 🧪\nraw=0x00"
        #expect(ChatErrorText.display(backend, language: store) == "Original diagnostic: " + backend)
        let stale = "聊天记录保存失败，请先重试保存。 [revision=42]"
        #expect(ChatErrorText.display(stale, language: store) == "Original diagnostic: " + stale)
        #expect(stale == "聊天记录保存失败，请先重试保存。 [revision=42]")
    }

    @Test func fixedBudgetWrapperPreservesItsNumbersAndRejectsExtraText() throws {
        let (store, suite) = try language("en")
        defer { suite.cleanup() }
        let original = "保守估计输入约1234 token，超过所选上限512；这不是精确分词。请显式排除消息或分叉较短路径。"
        #expect(ChatErrorText.display(original, language: store)
                == "Conservative input estimate: about 1234 tokens, above the selected limit of 512. This is not exact tokenization. Exclude messages explicitly or fork a shorter path.")
        let canary = original + " 用户附言🧪"
        #expect(ChatErrorText.display(canary, language: store) == "Original diagnostic: " + canary)
        #expect(ChatErrorText.display("CSV preview: More than 77 columns.", language: store)
                == "CSV preview: More than 77 columns.")
        #expect(ChatErrorText.display("CSV preview: More than 77 columns. 🧪", language: store)
                == "Original diagnostic: CSV preview: More than 77 columns. 🧪")
    }

    @Test func registryKeysExistInBothResourcesAndContextPlanLiteralsStayCovered() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let en = try strings(at: root.appendingPathComponent("Sources/UI/Resources/Localization/en.json"))
        let zh = try strings(at: root.appendingPathComponent("Sources/UI/Resources/Localization/zh-Hans.json"))
        let keys = ChatErrorText.entries.map(\.key) + [
            "chat.error.originalDiagnostic", "chat.error.contextBudget",
            "chat.error.csvColumnLimit", "chat.error.csvRowLimit",
        ]
        #expect(Set(keys).count == keys.count)
        #expect(Set(ChatErrorText.entries.map(\.original)).count == ChatErrorText.entries.count)
        #expect(Set(ChatErrorText.entries.map(\.english)).count == ChatErrorText.entries.count)
        for entry in ChatErrorText.entries {
            #expect(en[entry.key] == entry.english)
            #expect(zh[entry.key] != nil)
        }
        #expect(en["chat.error.originalDiagnostic"] == "Original diagnostic: ")
        #expect(zh["chat.error.originalDiagnostic"] == "原始诊断：")

        // Only the one owned source is checked. A new static literal there must
        // be registered, while dynamic diagnostics remain explicitly outside it.
        let source = try String(contentsOf: root.appendingPathComponent("Sources/DWorkbench/Chat/ChatContextPlan.swift"), encoding: .utf8)
        let literals = source.components(separatedBy: "\n").compactMap { line -> String? in
            guard let start = line.range(of: "WorkflowIssue(\""),
                  let end = line[start.upperBound...].range(of: "\")") else { return nil }
            return String(line[start.upperBound..<end.lowerBound])
        }
        #expect(Set(literals) == Set(ChatErrorText.entries.prefix(7).map(\.original)))
    }

    private func language(_ locale: String) throws -> (UILanguageStore, SettingsSuite) {
        let name = "D.ChatErrorText.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: name))
        let store = UILanguageStore(settings: settings, preferredLanguages: [locale])
        return (store, SettingsSuite(name: name, settings: settings))
    }

    private func strings(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["strings"] as? [String: String])
    }

    private struct SettingsSuite {
        let name: String
        let settings: UserDefaults
        func cleanup() { settings.removePersistentDomain(forName: name) }
    }
}
