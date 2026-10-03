import DInference
import Foundation
import Hub
import Testing
import Tokenizers
@testable import DMLXBackend

@Suite("Finite per-request chat templates")
struct ChatTemplateOverrideTests {
    private let source = """
        {% for message in messages %}<|im_start|>{{ message.role }}\n
        {% if message.role == 'tool' %}<tool_response>\n{% endif %}
        {% for part in message.content %}{% if part.type == 'text' %}{{ part.text }}{% elif part.type == 'image' %}<|vision_start|><|image_pad|><|vision_end|>{% elif part.type == 'video' %}<|vision_start|><|video_pad|><|vision_end|>{% endif %}{% endfor %}
        {% if message.reasoning_content %}{{ message.reasoning_content }}{% endif %}{% if message.tool_calls %}{{ message.tool_calls | tojson }}{% endif %}<|im_end|>\n
        {% endfor %}{% if tools %}{% for tool in tools %}{{ tool | tojson }}{% endfor %}{% endif %}{% if add_generation_prompt %}<|im_start|>assistant\n<think>\n{% if enable_thinking == false %}\n</think>\n\n{% endif %}{% endif %}
        """

    private var config: Config { Config(["chat_template": Config(source)]) }
    private var messages: [[String: any Sendable]] {
        [["role": "system", "content": [["type": "text", "text": "policy"]]],
         ["role": "user", "content": [["type": "text", "text": "question"],
                                      ["type": "image"], ["type": "video"]]],
         ["role": "assistant", "content": [["type": "text", "text": "answer"]]]]
    }

    @Test func defaultAndLiteralAreIdenticalAndInstancesStayIndependent() throws {
        let base = FixtureTokenizer(config: config, source: source)
        let original = LocalTokenizer(base: base, config: config,
                                      sourceTemplate: source, chatTemplateOverride: nil)
        let equal = LocalTokenizer(base: base, config: config,
                                   sourceTemplate: source, chatTemplateOverride: source)
        let editedSource = "edited\n" + source
        let edited = LocalTokenizer(base: base, config: config,
                                    sourceTemplate: source, chatTemplateOverride: editedSource)
        let plain = try original.preview(messages: messages, tools: nil, additionalContext: nil)
        let explicit = try equal.preview(messages: messages, tools: nil, additionalContext: nil)
        let changed = try edited.preview(messages: messages, tools: nil, additionalContext: nil)
        #expect(plain.1 == explicit.1 && plain.2 == explicit.2)
        #expect(changed.1.hasPrefix("edited\n") && changed.2 != plain.2)
        #expect(try original.preview(messages: messages, tools: nil, additionalContext: nil).2 == plain.2)
        #expect(plain.1.contains("<|vision_start|><|image_pad|><|vision_end|>"))
        #expect(plain.1.contains("<|vision_start|><|video_pad|><|vision_end|>"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_TEMPLATE_TOKENIZER_DIR"] != nil))
    func installedTokenizerPreviewAgreesWithIndependentTokenization() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEMPLATE_TOKENIZER_DIR"]))
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        let local = try await LocalTokenizerLoader().loadLocal(from: directory)
        let exact = try await LocalTokenizerLoader(chatTemplateOverride: local.sourceTemplate).loadLocal(from: directory)
        for thinking in [true, false] {
            let context: [String: any Sendable] = ["enable_thinking": thinking]
            let baseline = try upstream.applyChatTemplate(messages: messages, tools: nil, additionalContext: context)
            let preview = try local.preview(messages: messages, tools: nil, additionalContext: context)
            let overridden = try exact.preview(messages: messages, tools: nil, additionalContext: context)
            #expect(!baseline.isEmpty)
            #expect(preview.2 == baseline && overridden.2 == baseline)
            #expect(preview.1 == overridden.1)
            // Compare an actually edited finite template using the real tokenizer too.
            let edited = try await LocalTokenizerLoader(chatTemplateOverride: source).loadLocal(from: directory)
            let editedPreview = try edited.preview(messages: messages, tools: nil, additionalContext: context)
            let independent = try upstream.applyChatTemplate(messages: messages, chatTemplate: .literal(source),
                addGenerationPrompt: true, truncation: false, maxLength: nil, tools: nil, additionalContext: context)
            #expect(editedPreview.2 == independent)
        }
    }

    @Test func rejectsUnboundedAndMissingInformation() throws {
        let candidate = "{% for message in messages %}{{ message.role }}{% endfor %}"
        try ChatTemplateOverride.validate(candidate, source: source, messages: messages,
                                          tools: nil, additionalContext: nil)
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validate("{% for x in range(999999999) %}x{% endfor %}",
                source: source, messages: messages, tools: nil, additionalContext: nil)
        }
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validate("{% macro x() %}{{ x() }}{% endmacro %}",
                source: source, messages: messages, tools: nil, additionalContext: nil)
        }
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validate(String(repeating: "x", count: 65_537),
                source: source, messages: messages, tools: nil, additionalContext: nil)
        }
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validateOutput("<|im_start|>assistant\n<think>\n",
                messages: messages, tools: nil)
        }
    }

    @Test func toolAndThinkingContextsArePreserved() throws {
        try ChatTemplateOverride.validateProbe(source, config: config)
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validateProbe(source.replacingOccurrences(
                of: "<|image_pad|>", with: "missing_image"), config: config)
        }
        let tool: [[String: any Sendable]] = [["type": "function", "function": [
            "name": "lookup", "description": "Find a record", "parameters": ["type": "object"]
        ] as [String: any Sendable]]]
        let rendered = try ChatTemplateOverride.render(source, config: config, messages: messages,
                                                       tools: tool, additionalContext: ["enable_thinking": true])
        #expect(rendered.contains("lookup") && rendered.contains("Find a record"))
        #expect(rendered.hasSuffix("<|im_start|>assistant\n<think>\n"))
        try ChatTemplateOverride.validateOutput(rendered, messages: messages, tools: tool)
    }

    @Test func rejectsCollectionReturnedThroughBooleanExpressionBeforeExpansion() throws {
        let largeMessages: [[String: any Sendable]] = (0..<100).map { index in
            ["role": "user", "content": [["type": "text",
                                           "text": "\(index)" + String(repeating: "m", count: 7_700)]]]
        }
        let candidate = "{% for message in messages %}{{ messages or '' }}{% endfor %}"
        // This only calls the preflight. Rendering the candidate could expand tens of MiB.
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validate(candidate, source: source, messages: largeMessages,
                                              tools: nil, additionalContext: nil)
        }
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validate("{{ '' or tools }}", source: source,
                                              messages: messages, tools: [], additionalContext: nil)
        }
    }

    @Test func actualReasoningBranchCannotDropToolArgumentValues() throws {
        let edited = source.replacingOccurrences(of: "{{ message.tool_calls | tojson }}", with:
            "{% if message.reasoning_content == 'drop-arguments' %}lookup location" +
            "{% else %}{{ message.tool_calls | tojson }}{% endif %}")
        // The probe takes the else branch. The actual request must be checked separately.
        try ChatTemplateOverride.validateProbe(edited, config: config)
        let calls: [[String: any Sendable]] = [["id": "call-1", "type": "function", "function": [
            "name": "lookup", "arguments": ["location": "Tokyo"]
        ] as [String: any Sendable]]]
        let actual: [[String: any Sendable]] = [
            ["role": "assistant", "content": [["type": "text", "text": "calling lookup"]],
             "reasoning_content": "drop-arguments", "tool_calls": calls],
            ["role": "tool", "content": [["type": "text", "text": "Tokyo result"]],
             "tool_call_id": "call-1"],
        ]
        let declaration: [[String: any Sendable]] = [["type": "function", "function": [
            "name": "lookup", "description": "Find location", "parameters": [
                "type": "object", "properties": ["location": ["type": "string"]]
            ] as [String: any Sendable]
        ] as [String: any Sendable]]]
        try ChatTemplateOverride.validate(edited, source: source, messages: actual,
                                          tools: declaration, additionalContext: nil)
        let rendered = try ChatTemplateOverride.render(edited, config: config, messages: actual,
                                                       tools: declaration,
                                                       additionalContext: ["enable_thinking": true])
        #expect(rendered.contains("lookup location") && rendered.contains("Tokyo result"))
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validateOutput(rendered, messages: actual, tools: declaration)
        }
    }

    @Test func quotedAssistantCallsDoNotReplaceActualToolCallChannel() throws {
        let calls: [[String: any Sendable]] = [["type": "function", "function": [
            "name": "lookup", "arguments": ["place": "Tokyo"]
        ] as [String: any Sendable]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), as: UTF8.self)
        for quotedReasoning in [false, true] {
            let content = quotedReasoning ? "final answer" : "quoted only: " + json
            let reasoning = quotedReasoning ? "quoted only: " + json : "reasoning"
            let actual: [[String: any Sendable]] = [["role": "assistant",
                "content": [["type": "text", "text": content]],
                "reasoning_content": reasoning, "tool_calls": calls]]
            let body = "<|im_start|>assistant\n" + reasoning + "\n" + content
            let suffix = "<|im_end|>\n<|im_start|>assistant\n<think>\n"
            #expect(throws: (any Error).self) {
                try ChatTemplateOverride.validateOutput(body + suffix, messages: actual, tools: nil)
            }
            try ChatTemplateOverride.validateOutput(body + "\n" + json + suffix, messages: actual, tools: nil)
        }
    }

    @Test func callsMayPrecedeFinalTextThatAlsoAppearsInArguments() throws {
        let calls: [[String: any Sendable]] = [["type": "function", "function": [
            "name": "lookup", "arguments": ["place": "Tokyo"]
        ] as [String: any Sendable]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), as: UTF8.self)
        let actual: [[String: any Sendable]] = [["role": "assistant",
            "content": [["type": "text", "text": "Tokyo"]], "tool_calls": calls]]
        for content in ["Tokyo", "Use ] or } to close. Unfinished [ and { with \"quoted prose"] {
            let request: [[String: any Sendable]] = [["role": "assistant",
                "content": [["type": "text", "text": content]], "tool_calls": calls]]
            for body in [json + "\n" + content, content + "\n" + json] {
                try ChatTemplateOverride.validateOutput("<|im_start|>assistant\n" + body +
                    "<|im_end|>\n<|im_start|>assistant\n<think>\n", messages: request, tools: nil)
            }
        }
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validateOutput("<|im_start|>assistant\n" + json +
                "<|im_end|>\n<|im_start|>assistant\n<think>\n", messages: actual, tools: nil)
        }
    }

    @Test func quotedFieldsCanAppearInEitherOrderWithoutLosingTheirChannel() throws {
        for (reasoning, content) in [("earlier final answer reasoning", "final answer"),
                                     ("reasoning", "quoted reasoning in final"), ("same", "same")] {
            let actual: [[String: any Sendable]] = [["role": "assistant",
                "content": [["type": "text", "text": content]], "reasoning_content": reasoning]]
            for body in [reasoning + "\n" + content, content + "\n" + reasoning] {
                try ChatTemplateOverride.validateOutput("<|im_start|>assistant\n" + body +
                    "<|im_end|>\n<|im_start|>assistant\n<think>\n", messages: actual, tools: nil)
            }
            #expect(throws: (any Error).self) {
                try ChatTemplateOverride.validateOutput("<|im_start|>assistant\n" +
                    (reasoning.count >= content.count ? reasoning : content) +
                    "<|im_end|>\n<|im_start|>assistant\n<think>\n", messages: actual, tools: nil)
            }
        }
    }

    @Test func reasoningBeforeFinalContentRetainsFullToolArguments() throws {
        let beforeFinal = source.replacingOccurrences(
            of: "{% for part in message.content %}",
            with: "{% if message.reasoning_content %}{{ message.reasoning_content }}{% endif %}" +
                  "{% for part in message.content %}")
            .replacingOccurrences(
                of: "{% if message.reasoning_content %}{{ message.reasoning_content }}{% endif %}" +
                    "{% if message.tool_calls %}",
                with: "{% if message.tool_calls %}")
        let calls: [[String: any Sendable]] = [["type": "function", "function": [
            "name": "lookup", "arguments": ["place": "Tokyo"]
        ] as [String: any Sendable]]]
        let actual: [[String: any Sendable]] = [
            ["role": "assistant", "content": [["type": "text", "text": "final answer"]],
             "reasoning_content": "earlier reasoning", "tool_calls": calls],
        ]
        try ChatTemplateOverride.validate(beforeFinal, source: source, messages: actual,
                                          tools: nil, additionalContext: nil)
        let rendered = try ChatTemplateOverride.render(beforeFinal, config: config,
                                                       messages: actual, tools: nil,
                                                       additionalContext: nil)
        let reasoning = try #require(rendered.range(of: "earlier reasoning"))
        let final = try #require(rendered.range(of: "final answer"))
        #expect(reasoning.upperBound <= final.lowerBound) // Adjacent non-overlapping fields preserve order.
        try ChatTemplateOverride.validateOutput(rendered, messages: actual, tools: nil)
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validateOutput(
                rendered.replacingOccurrences(of: "Tokyo", with: "Osaka"),
                messages: actual, tools: nil)
        }
        let malformed: [[String: any Sendable]] = [
            ["role": "assistant", "content": [["type": "text", "text": "final answer"]],
             "tool_calls": "malformed"]
        ]
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validateOutput(rendered, messages: malformed, tools: nil)
        }
    }

    @Test func completeSystemBodyToolsAreAcceptedButUserQuotesAreNot() throws {
        let inSystem = """
            <|im_start|>system\n
            {% for tool in tools %}{{ tool | tojson }}{% endfor %}
            {% for message in messages %}{% if message.role == 'system' %}{% for part in message.content %}{% if part.type == 'text' %}{{ part.text }}{% endif %}{% endfor %}{% endif %}{% endfor %}<|im_end|>\n
            {% for message in messages %}{% if message.role != 'system' %}<|im_start|>{{ message.role }}\n
            {% for part in message.content %}{% if part.type == 'text' %}{{ part.text }}{% endif %}{% endfor %}<|im_end|>\n
            {% endif %}{% endfor %}<|im_start|>assistant\n<think>\n
            """
        let declaration: [[String: any Sendable]] = [["type": "function", "function": [
            "name": "lookup", "description": "Find Tokyo", "parameters": ["type": "object"]
        ] as [String: any Sendable]]]
        let actual: [[String: any Sendable]] = [
            ["role": "system", "content": [["type": "text", "text": "policy"]]],
            ["role": "user", "content": [["type": "text", "text": "question"]]],
        ]
        try ChatTemplateOverride.validate(inSystem, source: source, messages: actual,
                                          tools: declaration, additionalContext: nil)
        let rendered = try ChatTemplateOverride.render(inSystem, config: config,
                                                       messages: actual, tools: declaration,
                                                       additionalContext: nil)
        try ChatTemplateOverride.validateOutput(rendered, messages: actual, tools: declaration)

        let json = try String(decoding: JSONSerialization.data(withJSONObject: declaration[0]),
                              as: UTF8.self)
        let quoted: [[String: any Sendable]] = [
            actual[0],
            ["role": "user", "content": [["type": "text", "text": "quoted: " + json]]],
        ]
        let withoutDeclaration = inSystem.replacingOccurrences(
            of: "{% for tool in tools %}{{ tool | tojson }}{% endfor %}", with: "")
        try ChatTemplateOverride.validate(withoutDeclaration, source: source, messages: quoted,
                                          tools: declaration, additionalContext: nil)
        let onlyQuoted = try ChatTemplateOverride.render(withoutDeclaration, config: config,
                                                         messages: quoted, tools: declaration,
                                                         additionalContext: nil)
        #expect(onlyQuoted.contains(json))
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validateOutput(onlyQuoted, messages: quoted,
                                                    tools: declaration)
        }
        let quotedSystem: [[String: any Sendable]] = [
            ["role": "system", "content": [["type": "text", "text": "quoted: " + json]]],
            actual[1],
        ]
        let systemTextOnly = try ChatTemplateOverride.render(withoutDeclaration, config: config,
                                                             messages: quotedSystem,
                                                             tools: declaration,
                                                             additionalContext: nil)
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validateOutput(systemTextOnly, messages: quotedSystem,
                                                    tools: declaration)
        }
    }

    @Test func toolDeclarationRequiresCompleteNestedValues() throws {
        let declaration: [[String: any Sendable]] = [["type": "function", "function": [
            "name": "lookup", "description": "Find a record", "parameters": [
                "type": "object", "properties": ["location": [
                    "type": "string", "description": "Tokyo place name"
                ]]
            ] as [String: any Sendable]
        ] as [String: any Sendable]]]
        let rendered = try ChatTemplateOverride.render(source, config: config, messages: messages,
                                                       tools: declaration,
                                                       additionalContext: ["enable_thinking": true])
        try ChatTemplateOverride.validateOutput(rendered, messages: messages, tools: declaration)
        #expect(rendered.contains("Tokyo place name"))
        #expect(throws: (any Error).self) {
            try ChatTemplateOverride.validateOutput(
                rendered.replacingOccurrences(of: "Tokyo place name", with: "place name"),
                messages: messages, tools: declaration)
        }
    }
}

/// UTF-8 byte IDs make rendered text equality observable without a model or tokenizer assets.
private struct FixtureTokenizer: Tokenizers.Tokenizer {
    let config: Config
    let source: String
    var hasChatTemplate: Bool { true }
    var bosToken: String? { nil }
    var bosTokenId: Int? { nil }
    var eosToken: String? { nil }
    var eosTokenId: Int? { nil }
    var unknownToken: String? { nil }
    var unknownTokenId: Int? { nil }
    func tokenize(text: String) -> [String] { text.map { String($0) } }
    func encode(text: String) -> [Int] { encode(text: text, addSpecialTokens: true) }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.utf8.map(Int.init) }
    func decode(tokens: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokens.map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]]) throws -> [Int] {
        try applyChatTemplate(messages: messages, tools: nil, additionalContext: nil)
    }
    func applyChatTemplate(messages: [[String: any Sendable]],
                           tools: [[String: any Sendable]]?) throws -> [Int] {
        try applyChatTemplate(messages: messages, tools: tools, additionalContext: nil)
    }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        encode(text: try ChatTemplateOverride.render(source, config: config, messages: messages,
            tools: tools, additionalContext: additionalContext), addSpecialTokens: false)
    }
    func applyChatTemplate(messages: [[String: any Sendable]],
                           chatTemplate: ChatTemplateArgument) throws -> [Int] {
        try applyChatTemplate(messages: messages, chatTemplate: chatTemplate,
            addGenerationPrompt: true, truncation: false, maxLength: nil, tools: nil)
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String) throws -> [Int] {
        try applyChatTemplate(messages: messages, chatTemplate: .literal(chatTemplate))
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: ChatTemplateArgument?,
                           addGenerationPrompt: Bool, truncation: Bool, maxLength: Int?,
                           tools: [[String: any Sendable]]?) throws -> [Int] {
        try applyChatTemplate(messages: messages, chatTemplate: chatTemplate,
            addGenerationPrompt: addGenerationPrompt, truncation: truncation, maxLength: maxLength,
            tools: tools, additionalContext: nil)
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: ChatTemplateArgument?,
                           addGenerationPrompt: Bool, truncation: Bool, maxLength: Int?,
                           tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        let selected: String
        switch chatTemplate {
        case .literal(let value): selected = value
        case .name(_): selected = source
        case nil: selected = source
        }
        return encode(text: try ChatTemplateOverride.render(selected, config: config,
            messages: messages, tools: tools, additionalContext: additionalContext),
            addSpecialTokens: false)
    }
}
