import Foundation
import Testing
@testable import DWorkbench

// Synthetic fixture following https://docs.openwebui.com/features/chat-conversations/data-controls/import-export/
// The documented source export is unversioned; version 1 below is D's mapping contract.
@Suite("Open WebUI history import")
struct ChatOpenWebUIImportTests {
    private func node(_ id: String, parent: Any, children: [String], role: String,
                      content: Any, extras: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["id": id, "parentId": parent, "childrenIds": children,
                                    "role": role, "content": content]
        for (key, item) in extras { value[key] = item }
        return value
    }

    private func chat() -> [String: Any] {
        let messages: [String: Any] = [
            "a-user": node("a-user", parent: NSNull(), children: ["b-current", "z-alternate"],
                           role: "user", content: "你好 e\u{301} 👩🏽‍🎨 <b>&</b> https://example.test/a?x=1"),
            "b-current": node("b-current", parent: "a-user", children: [], role: "assistant",
                              content: "Selected answer", extras: ["done": true, "model": "untrusted-model",
                                                                 "timestamp": 123, "citations": ["source"]]),
            "z-alternate": node("z-alternate", parent: "a-user", children: [], role: "assistant",
                                content: "Other answer")
        ]
        return ["title": "Synthetic 👩🏽‍🎨", "models": ["untrusted-model"],
                "history": ["currentId": "b-current", "messages": messages]]
    }

    private func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func standard(_ chat: [String: Any]) -> [String: Any] {
        ["chat": chat, "meta": ["source": "synthetic"], "pinned": true,
         "folder_id": "untrusted-folder", "created_at": 123, "updated_at": 124]
    }

    private func reason(_ data: Data, selection: Int? = nil) -> String {
        do {
            _ = try ChatInterchange.previewImport(data, selectedConversationIndex: selection)
            return "Unexpected success"
        } catch let ChatInterchangeError.invalid(message) { return message }
        catch { return "Unexpected error: \(error)" }
    }

    @Test func duplicateCheckHandlesWideMetadataWithoutCopyingWholeKeySets() throws {
        let metadata = Dictionary(uniqueKeysWithValues: (0..<12_000).map { ("k\($0)", $0) })
        let data = try JSONSerialization.data(withJSONObject: ["metadata": metadata])
        try ChatInterchange.checkJSONDepth(data)
    }

    @Test func duplicateRawJSONMembersAreRejectedBeforeDictionaryConversion() throws {
        let raw = #"{"title":"test","history":{"currentId":"a","messages":{"u":{"id":"u","parentId":null,"childrenIds":["a"],"role":"user","content":"question"},"a":{"id":"a","parentId":"u","childrenIds":[],"role":"assistant","content":"answer","done":false,"done":true}}}}"#
        #expect(throws: (any Error).self) { try ChatInterchange.previewImport(Data(raw.utf8)) }
        let escaped = #"{"format":"openai-messages","version":1,"messages":[{"role":"user","content":"original","\u0063ontent":"replacement"}]}"#
        #expect(throws: (any Error).self) { try ChatInterchange.previewImport(Data(escaped.utf8)) }
        let separate = #"{"format":"openai-messages","version":1,"messages":[{"role":"user","content":"one"},{"role":"assistant","content":"two"}]}"#
        #expect(try ChatInterchange.previewImport(Data(separate.utf8)).messages.count == 2)
    }

    @Test func documentedStandardBranchPreservesLiteralTextAndRequiresLossApproval() throws {
        let original = try data([standard(chat())]); let copy = original
        let choices = try ChatOpenWebUIImport.conversations(in: original)
        #expect(choices == [.init(index: 0, title: "Synthetic 👩🏽‍🎨")])
        let preview = try ChatInterchange.previewImport(original)
        #expect(preview.format == "open-webui-history" && preview.version == 1)
        #expect(preview.sourceTitle == "Synthetic 👩🏽‍🎨" && preview.conversationIndex == 0)
        #expect(preview.systemPrompt.isEmpty)
        #expect(preview.messages.map(\.role) == [.user, .assistant])
        #expect(preview.messages.map(\.sourceIndex) == [0, 1]) // Sorted map IDs; currentId is not the last key.
        #expect(preview.messages.map(\.text) == ["你好 e\u{301} 👩🏽‍🎨 <b>&</b> https://example.test/a?x=1",
                                                  "Selected answer"])
        #expect(preview.losses.contains { $0.location == "chat.history.messages" && $0.reason.contains("alternate-branch") })
        #expect(preview.losses.contains { $0.location == "chat.history.messages[1].model" })
        #expect(preview.losses.contains { $0.location == "chat.history.messages[1].timestamp" })
        #expect(preview.losses.contains { $0.location == "chat.history.messages[1].citations" })
        #expect(preview.losses.contains { $0.location == "chat.models" && $0.reason.contains("no model") })
        #expect(preview.losses.contains { $0.location == "meta" })
        #expect(throws: (any Error).self) { try preview.accept() }
        let accepted = try preview.accept(allowingLosses: true)
        #expect(accepted.messages == preview.messages && accepted.acknowledgedLosses == preview.losses)
        #expect(original == copy)
    }

    @Test func legacyAndSingleObjectsAreRecognizedOnlyWithHistoryShape() throws {
        let legacy = try data(chat())
        let singleStandard = try data(standard(chat()))
        #expect(try ChatInterchange.previewImport(legacy).messages.map(\.text).last == "Selected answer")
        #expect(try ChatInterchange.previewImport(singleStandard).messages.count == 2)
        #expect(try ChatInterchange.previewImport(data([chat()])).messages.count == 2)
        #expect(reason(try data(["title": "Ordinary JSON", "messages": []])).contains("history"))
    }

    @Test func multipleConversationsNeedSelectionAndPreserveChosenIndex() throws {
        var second = chat(); second["title"] = "Second"
        let archive = try data([standard(chat()), standard(second)])
        #expect(try ChatOpenWebUIImport.conversations(in: archive).map(\.title) == ["Synthetic 👩🏽‍🎨", "Second"])
        #expect(reason(archive).contains("Choose a conversation index"))
        #expect(reason(archive, selection: 2).contains("out of range"))
        #expect(reason(archive, selection: -1).contains("out of range"))
        let preview = try ChatInterchange.previewImport(archive, selectedConversationIndex: 1)
        #expect(preview.conversationIndex == 1 && preview.sourceTitle == "Second")
        #expect(preview.messages.map(\.sourceIndex) == [0, 1])
    }

    @Test func brokenTreeAndUnfinishedBranchesAreRejected() throws {
        var missing = chat()
        var history = missing["history"] as! [String: Any]
        var messages = history["messages"] as! [String: Any]
        var current = messages["b-current"] as! [String: Any]
        current["parentId"] = "absent"; messages["b-current"] = current
        history["messages"] = messages; missing["history"] = history
        #expect(reason(try data(missing)).contains("missing parent"))

        var duplicated = chat()
        history = duplicated["history"] as! [String: Any]
        messages = history["messages"] as! [String: Any]
        var root = messages["a-user"] as! [String: Any]
        root["childrenIds"] = ["b-current", "b-current", "z-alternate"]
        messages["a-user"] = root; history["messages"] = messages; duplicated["history"] = history
        #expect(reason(try data(duplicated)).contains("duplicate"))

        var cycle = chat()
        history = cycle["history"] as! [String: Any]
        messages = history["messages"] as! [String: Any]
        root = messages["a-user"] as! [String: Any]
        root["parentId"] = "z-alternate"; messages["a-user"] = root
        var alternate = messages["z-alternate"] as! [String: Any]
        alternate["childrenIds"] = ["a-user"]; messages["z-alternate"] = alternate
        history["messages"] = messages; cycle["history"] = history
        #expect(reason(try data(cycle)).contains("root"))

        var unknown = chat()
        history = unknown["history"] as! [String: Any]
        messages = history["messages"] as! [String: Any]
        alternate = messages["z-alternate"] as! [String: Any]
        alternate["role"] = "developer"; messages["z-alternate"] = alternate
        history["messages"] = messages; unknown["history"] = history
        #expect(reason(try data(unknown)).contains("supported role"))

        var unfinished = chat()
        history = unfinished["history"] as! [String: Any]
        messages = history["messages"] as! [String: Any]
        alternate = messages["z-alternate"] as! [String: Any]
        alternate["done"] = false; messages["z-alternate"] = alternate
        history["messages"] = messages; unfinished["history"] = history
        #expect(reason(try data(unfinished)).contains("unfinished"))

        var wrongBranch = chat()
        history = wrongBranch["history"] as! [String: Any]
        messages = history["messages"] as! [String: Any]
        alternate = messages["z-alternate"] as! [String: Any]
        alternate["role"] = "user"; messages["z-alternate"] = alternate
        history["messages"] = messages; wrongBranch["history"] = history
        #expect(reason(try data(wrongBranch)).contains("Every history branch"))
    }

    @Test func contentDepthBytesAndArchiveBoundsAreEnforced() throws {
        var media = chat()
        var history = media["history"] as! [String: Any]
        var messages = history["messages"] as! [String: Any]
        var current = messages["b-current"] as! [String: Any]
        current["content"] = [["type": "image_url", "url": "https://example.test/image"]]
        messages["b-current"] = current; history["messages"] = messages; media["history"] = history
        #expect(reason(try data(media)).contains("text content"))

        let deep = "{\"chat\":{\"title\":\"x\",\"history\":{\"currentId\":\"a\",\"messages\":{},\"extra\":" +
            String(repeating: "[", count: ChatInterchange.maximumJSONDepth) + "0" +
            String(repeating: "]", count: ChatInterchange.maximumJSONDepth) + "}}}"
        #expect(reason(Data(deep.utf8)).contains("nesting"))
        #expect(reason(Data(repeating: 0x20, count: ChatInterchange.maximumImportBytes + 1)).contains("2 MiB"))
        #expect(reason(try data(Array(repeating: chat(), count: ChatOpenWebUIImport.maximumConversations + 1))).contains("Archive"))

        var tooMany = chat()
        history = tooMany["history"] as! [String: Any]
        messages = history["messages"] as! [String: Any]
        for index in 0..<ChatInterchange.maximumMessages {
            messages["extra-\(index)"] = node("extra-\(index)", parent: NSNull(), children: [],
                                                role: "user", content: "x")
        }
        history["messages"] = messages; tooMany["history"] = history
        #expect(reason(try data(tooMany)).contains("too many history messages"))

        var tooMuchText = chat()
        history = tooMuchText["history"] as! [String: Any]
        messages = history["messages"] as! [String: Any]
        current = messages["b-current"] as! [String: Any]
        current["content"] = String(repeating: "x", count: ChatInterchange.maximumTextBytes + 1)
        messages["b-current"] = current; history["messages"] = messages; tooMuchText["history"] = history
        #expect(reason(try data(tooMuchText)).contains("Mapped text exceeds 1 MiB"))
    }

    @Test func existingDWrapperStillUsesItsExactParser() throws {
        let wrapper = try data(["format": "openai-messages", "version": 1,
                                "messages": [["role": "user", "content": "Existing wrapper"]]])
        let direct = try ChatInterchange.previewOpenAIMessagesV1(wrapper)
        let automatic = try ChatInterchange.previewImport(wrapper)
        #expect(automatic == direct && automatic.messages.map(\.text) == ["Existing wrapper"])
        #expect(automatic.sourceTitle == nil && automatic.conversationIndex == nil)
        #expect(reason(wrapper, selection: 0).contains("no conversation selection index"))
    }
}
