import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Frozen chat request inspection")
struct ChatRequestInspectionTests {
    @Test func frozenSectionsStayReadableAndExportOmitsSecrets() throws {
        var node = WorkflowNode(operationID: WorkflowModelRoutes.qwen35, definitionVersion: 2, title: "chat")
        node.parameters["seed"] = .text("42")
        node.parameters["temperature"] = .decimal(0.7)
        node.parameters["thinking"] = .text("on")
        node.parameters["modelID"] = .text("/private/model-secret")
        node.parameters["authorizationHeader"] = .text("Bearer secret-token")
        node.parameters["accessToken"] = .text("private access credential")
        node.parameters["messagesJSON"] = .text("personal original")
        node.parameters["customPrompt"] = .text("local free text")
        let reference = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .image,
                                                sha256: String(repeating: "a", count: 64))
        let attempt = ChatAttempt(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(),
                                  node: node, messagesJSON: "private messages /Users/person/file.txt",
                                  inputs: ["images": .asset(reference)], systemPrompt: "system secret", status: .completed)
        let inspection = ChatRequestInspection(attempt: attempt)
        #expect(inspection.sections.first?.fields.contains { $0.value == attempt.id.uuidString } == true)
        #expect(inspection.sections.first { $0.id == "input" }?.fields.contains {
            $0.id == "system" && $0.value == "system secret"
        } == true)
        #expect(inspection.sections.first { $0.id == "seed" }?.fields.contains {
            $0.id == "seed" && $0.value == "42"
        } == true)
        #expect(inspection.sections.first { $0.id == "parameters" }?.fields.contains {
            $0.id == "customPrompt" && $0.value == "local free text"
        } == true)
        #expect(inspection.sections.first { $0.id == "parameters" }?.fields.contains {
            $0.id == "authorizationHeader" && $0.value == "[redacted]"
        } == true)
        #expect(inspection.sections.first { $0.id == "parameters" }?.fields.contains {
            $0.id == "accessToken" && $0.value == "[redacted]"
        } == true)
        let exported = inspection.redactedJSON
        #expect(exported.contains("\"seed\":\"42\""))
        #expect(exported.contains(reference.sha256))
        #expect(exported.contains(attempt.id.uuidString))
        for secret in ["system secret", "private messages", "/Users/person", "/private/model-secret",
                       "Bearer secret-token", "private access credential", "personal original", "local free text"] {
            #expect(!exported.contains(secret))
        }
        let record = try #require(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        #expect(record["definitionVersion"] as? Int == 2)
        #expect(record["operationID"] as? String == WorkflowModelRoutes.qwen35)
        #expect(attempt.systemPrompt == "system secret")
    }

    @Test func realLanguageNodeParametersRemainVisibleAndExportable() throws {
        for route in [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38] {
            let definition = try #require(WorkflowLanguageOperations.operations
                .first(where: { $0.definition.id == route })?.definition)
            var node = definition.makeNode()
            let numericIDs = ["maximumPromptTokens", "maximumOutputTokens"]
            let choiceIDs = ["loadingStrategy", "preserveThinking", "reasoningEffort"]
            for key in numericIDs {
                let declared = try #require(definition.fields.first(where: { $0.id == key }))
                guard case .integer(let number) = declared.defaultValue else {
                    Issue.record("Expected a declared integer default for \(key)")
                    continue
                }
                let inspection = inspection(node: node)
                let parameters = try exportedParameters(inspection)
                #expect(parameters[key] == String(number))
                #expect(inspection.sections.first { $0.id == "parameters" }?.fields.contains {
                    $0.id == key && $0.value == String(number)
                } == true)
            }
            for key in choiceIDs {
                let declared = try #require(definition.fields.first(where: { $0.id == key }))
                guard case .choice(let choices) = declared.kind else {
                    Issue.record("Expected declared choices for \(key)")
                    continue
                }
                for choice in choices {
                    node.parameters[key] = .text(choice)
                    let inspection = inspection(node: node)
                    let parameters = try exportedParameters(inspection)
                    #expect(parameters[key] == choice)
                    #expect(inspection.sections.first { $0.id == "parameters" }?.fields.contains {
                        $0.id == key && $0.value == choice
                    } == true)
                }
                node.parameters[key] = .text("unknown-custom")
                let invalidInspection = inspection(node: node)
                let invalidParameters = try exportedParameters(invalidInspection)
                #expect(invalidParameters[key] == nil)
                #expect(invalidInspection.sections.first { $0.id == "parameters" }?.fields.contains {
                    $0.id == key && $0.value == "unknown-custom"
                } == true)
                node.parameters[key] = declared.defaultValue
            }
        }
    }

    @Test func storedMessagesMemoryMediaAndResponseAreReadFromAttempt() throws {
        var node = WorkflowNode(operationID: WorkflowModelRoutes.qwen35, definitionVersion: 2, title: "chat")
        node.parameters["maximumPromptTokens"] = .integer(4096)
        node.parameters["minimumPixels"] = .integer(1024)
        node.parameters["maximumVideoFrames"] = .integer(16)
        node.parameters["chatTemplateOverride"] = .text("frozen template")
        node.parameters["toolsJSON"] = .text("[{\"name\":\"calculator\",\"description\":\"Local arithmetic\",\"parameters\":{\"type\":\"object\"}}]")
        let image = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .image,
                                           sha256: String(repeating: "b", count: 64))
        let video = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .video,
                                           sha256: String(repeating: "c", count: 64))
        let messages = """
        [{"role":"system","parts":[{"type":"text","text":"Old rule"}]},
         {"role":"user","parts":[{"type":"text","text":"Frozen question"},{"type":"image","index":0},{"type":"video","index":0}]},
         {"role":"assistant","parts":[{"type":"text","text":"Calling"}],"toolCalls":[{"id":"call_1","name":"calculator","arguments":{"api_key":"tool-canary"}}]},
         {"role":"tool","parts":[{"type":"text","text":"4"}],"toolCallID":"call_1"}]
        """
        var attempt = ChatAttempt(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(), node: node,
                                  messagesJSON: messages, inputs: ["images": .asset(image), "video": .asset(video)],
                                  systemPrompt: "Old rule", status: .completed)
        let memory = try ChatMemoryEntry.manual(text: "frozen memory", scope: .personal)
        attempt.memoryUses = [ChatMemoryUse(memory)]
        attempt.response = .init(rawText: "answer", finalText: "answer", finishReason: .length)
        let inspection = ChatRequestInspection(attempt: attempt)
        let ordered = try #require(inspection.sections.first { $0.id == "messages" })
        #expect(ordered.fields.count == 5)
        #expect(ordered.fields[1].label == "1. system")
        #expect(ordered.fields[2].value.contains("Frozen question"))
        #expect(ordered.fields[2].value.contains("image [0] · asset \(image.assetID.uuidString)"))
        #expect(ordered.fields[2].value.contains("video [0] · asset \(video.assetID.uuidString)"))
        #expect(ordered.fields[3].value.contains("Tool call 1: calculator"))
        #expect(ordered.fields[3].value.contains("execution not recorded here"))
        #expect(!ordered.fields[3].value.contains("tool-canary"))
        #expect(ordered.fields[4].label == "4. tool")
        #expect(inspection.sections.first { $0.id == "memory" }?.fields.contains {
            $0.value.contains(memory.id.uuidString) && $0.value.contains("revision 1")
        } == true)
        #expect(inspection.sections.first { $0.id == "memory" }?.fields.first?.value.contains("Not recorded") == true)
        #expect(inspection.sections.first { $0.id == "template" }?.fields.first?.value.contains("Frozen custom override") == true)
        #expect(inspection.sections.first { $0.id == "tools" }?.fields.contains {
            $0.id == "tool.0" && $0.value == "calculator"
        } == true)
        let response = try #require(inspection.sections.first { $0.id == "response" })
        #expect(response.fields.contains { $0.id == "actualTokens" && $0.value.contains("Not recorded") })
        #expect(response.fields.contains { $0.id == "estimatedTokens" && $0.value.contains("Approximately") })
        #expect(response.fields.contains { $0.id == "finish" && $0.value == "length" })
        #expect(!inspection.redactedJSON.contains("tool-canary"))
        node.parameters["maximumPromptTokens"] = .integer(128)
        let later = ChatRequestInspection(attempt: .init(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(),
            node: node, messagesJSON: "[]", inputs: [:], systemPrompt: "New rule", status: .running))
        #expect(inspection.sections.first { $0.id == "parameters" }?.fields.contains {
            $0.id == "maximumPromptTokens" && $0.value == "4096"
        } == true)
        #expect(later.sections.first { $0.id == "parameters" }?.fields.contains {
            $0.id == "maximumPromptTokens" && $0.value == "128"
        } == true)
    }

    @Test func malformedSourceIsVisibleWithoutInventedMessagesOrCredentialExport() throws {
        var node = WorkflowNode(operationID: WorkflowModelRoutes.qwen35, definitionVersion: 2, title: "chat")
        node.parameters["chatTemplateOverride"] = .text("Authorization: Bearer template-canary")
        node.parameters["extraURL"] = .text("https://private.example/secret")
        node.parameters["api_key"] = .text("key-canary")
        let malformed = "Authorization: Bearer credential-canary\n[{\"role\":\"user\",\"parts\":[{\"type\":\"image\",\"index\":8}]}]"
        let attempt = ChatAttempt(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(), node: node,
                                  messagesJSON: malformed, inputs: [:], systemPrompt: "password: system-canary", status: .failed)
        let inspection = ChatRequestInspection(attempt: attempt)
        let ordered = try #require(inspection.sections.first { $0.id == "messages" })
        #expect(ordered.fields.count == 2)
        #expect(ordered.fields[0].value.contains("could not be decoded"))
        #expect(ordered.fields[1].value == "[withheld: invalid stored message JSON]")
        #expect(!ordered.fields[1].value.contains("credential-canary"))
        #expect(inspection.sections.first { $0.id == "response" }?.fields.contains {
            $0.id == "estimatedTokens" && $0.value.contains("Unavailable")
        } == true)
        for canary in ["credential-canary", "system-canary", "template-canary", "key-canary", "private.example", "https://"] {
            #expect(!inspection.redactedJSON.contains(canary))
        }
        #expect(inspection.sections.first { $0.id == "parameters" }?.fields.contains {
            $0.id == "api_key" && $0.value == "[redacted]"
        } == true)
        let invalidIndex = ChatRequestInspection(attempt: .init(sessionID: UUID(), userMessageID: UUID(),
            assistantMessageID: UUID(), node: node,
            messagesJSON: "[{\"role\":\"user\",\"parts\":[{\"type\":\"image\",\"index\":8}]}]",
            inputs: [:], systemPrompt: "", status: .failed))
        #expect(invalidIndex.sections.first { $0.id == "messages" }?.fields.first?.value.contains("could not be decoded") == true)
    }

    @Test func storedMessageValidationMatchesProductionForm() throws {
        let node = WorkflowNode(operationID: WorkflowModelRoutes.qwen35, definitionVersion: 2, title: "chat")
        let image = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .image,
                                           sha256: String(repeating: "a", count: 64))
        let cases: [(String, [String: WorkflowValue])] = [
            (#"[{"role":"user","content":"unknown-canary","parts":[{"type":"text","text":"hello"}]}]"#, [:]),
            (#"[{"role":"user","authorizati\u006fn":"escaped-field-canary","parts":[{"type":"text","text":"hello"}]}]"#, [:]),
            (#"[{"role":"user","parts":[{"type":"text","text":"hello"}]}]"#, ["images": .asset(image)]),
            (#"[{"role":"user","parts":[{"type":"image","index":0,"text":"image-text-canary"}]}]"#, ["images": .asset(image)])
        ]
        for (json, inputs) in cases {
            let attempt = ChatAttempt(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(),
                                      node: node, messagesJSON: json, inputs: inputs,
                                      systemPrompt: "Ordinary rule", status: .failed)
            let inspection = ChatRequestInspection(attempt: attempt)
            let ordered = try #require(inspection.sections.first { $0.id == "messages" })
            #expect(ordered.fields.count == 2)
            #expect(ordered.fields[0].value.contains("could not be decoded"))
            #expect(ordered.fields[1].value == "[withheld: invalid stored message JSON]")
            #expect(!inspection.sections.flatMap(\.fields).map(\.value).joined().contains("escaped-field-canary"))
            #expect(inspection.sections.first { $0.id == "response" }?.fields.contains {
                $0.id == "estimatedTokens" && $0.value.contains("Unavailable")
            } == true)
        }
    }

    @Test func localInspectionKeepsProseAndRedactsCredentialValuesAfterJSONDecoding() throws {
        var node = WorkflowNode(operationID: WorkflowModelRoutes.qwen35, definitionVersion: 2, title: "chat")
        node.parameters["seed"] = .text("Authorization:\nseed-canary")
        node.parameters["minimumPixels"] = .text("Bearer\nmedia-canary")
        node.parameters["customPrompt"] = .text("Explain token budgets and key differences; api_key = parameter-canary; keep keyframe readable")
        node.parameters["monkey"] = .text("ordinary value")
        node.parameters["tokenizer"] = .text("ordinary value")
        node.parameters["keyframe"] = .text("ordinary value")
        let messages = #"[{"role":"user","parts":[{"type":"text","text":"Ordinary input: monkey keyboard, tokenizer, keyframe"},{"type":"text","text":"Authorization: Bearer line-canary; continue the explanation"},{"type":"text","text":"authorizati\u006fn: unicode-canary"},{"type":"text","text":"settings {\"api_key\":\"json-canary\"}; discuss token budgets"}]}]"#
        let attempt = ChatAttempt(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(),
                                  node: node, messagesJSON: messages, inputs: [:],
                                  systemPrompt: "Explain token budgets and key differences. password: system-canary; keep the explanation", status: .completed)
        let inspection = ChatRequestInspection(attempt: attempt)
        let ordered = try #require(inspection.sections.first { $0.id == "messages" })
        #expect(ordered.fields[0].value.contains("Decoded 1"))
        #expect(ordered.fields[1].value.contains("Ordinary input: monkey keyboard, tokenizer, keyframe"))
        #expect(ordered.fields[1].value.contains("continue the explanation"))
        #expect(ordered.fields[1].value.contains("discuss token budgets"))
        let visible = inspection.sections.flatMap(\.fields).map(\.value).joined(separator: "\n")
        #expect(visible.contains("Explain token budgets and key differences"))
        #expect(visible.contains("keep keyframe readable"))
        #expect(visible.contains("keep the explanation"))
        let parameters = try #require(inspection.sections.first { $0.id == "parameters" })
        for key in ["monkey", "tokenizer", "keyframe"] {
            #expect(parameters.fields.contains { $0.id == key && $0.label == key && $0.value == "ordinary value" })
        }
        for canary in ["line-canary", "unicode-canary", "json-canary", "system-canary", "seed-canary", "media-canary", "parameter-canary"] {
            #expect(!visible.contains(canary))
            #expect(!inspection.redactedJSON.contains(canary))
        }
        #expect(inspection.sections.first { $0.id == "seed" }?.fields.first?.value.contains("[redacted]") == true)
        #expect(inspection.sections.first { $0.id == "media" }?.fields.contains {
            $0.id == "minimumPixels" && $0.value.contains("[redacted]")
        } == true)
        #expect(!inspection.redactedJSON.contains("Explain token budgets"))
    }

    @Test func concreteTokenPatternsAreRedactedWithinOrdinaryText() throws {
        let node = WorkflowNode(operationID: WorkflowModelRoutes.qwen35, definitionVersion: 2, title: "chat")
        let attempt = ChatAttempt(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(),
                                  node: node, messagesJSON: "[]", inputs: [:],
                                  systemPrompt: "Compare tokenizer and keyframe; sk-local-canary, ghp_local_canary; then explain monkey keyboard",
                                  status: .completed)
        let inspection = ChatRequestInspection(attempt: attempt)
        let system = try #require(inspection.sections.first { $0.id == "input" }?.fields.first { $0.id == "system" }?.value)
        #expect(system.contains("Compare tokenizer and keyframe"))
        #expect(system.contains("then explain monkey keyboard"))
        #expect(!system.contains("sk-local-canary"))
        #expect(!system.contains("ghp_local_canary"))
        #expect(!inspection.redactedJSON.contains("Compare tokenizer"))
    }

    @Test func explicitCredentialAssignmentsAreRedactedWithoutHidingDefinitions() throws {
        let node = WorkflowNode(operationID: WorkflowModelRoutes.qwen35, definitionVersion: 2, title: "chat")
        let source = "{'password':'quoted-canary'}; refresh_token: refresh-canary; authToken: auth-canary; " +
            "apiKey = api-canary; access_token: access-canary; " +
            "token: the smallest unit of text; key: primary identifier"
        let attempt = ChatAttempt(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(),
                                  node: node, messagesJSON: "[]", inputs: [:],
                                  systemPrompt: source, status: .completed)
        let inspection = ChatRequestInspection(attempt: attempt)
        let system = try #require(inspection.sections.first { $0.id == "input" }?.fields.first { $0.id == "system" }?.value)
        #expect(system.contains("'password':[redacted]"))
        #expect(system.contains("refresh_token: [redacted]"))
        #expect(system.contains("authToken: [redacted]"))
        #expect(system.contains("apiKey = [redacted]"))
        #expect(system.contains("access_token: [redacted]"))
        #expect(system.contains("token: the smallest unit of text; key: primary identifier"))
        for canary in ["quoted-canary", "refresh-canary", "auth-canary", "api-canary", "access-canary"] {
            #expect(!system.contains(canary))
            #expect(!inspection.redactedJSON.contains(canary))
        }
    }

    @Test func credentialMarkersInVisibleIdentifiersAreWithheld() throws {
        var node = WorkflowNode(operationID: WorkflowModelRoutes.qwen35, definitionVersion: 2, title: "chat")
        node.parameters["maximumPromptTokens"] = .integer(4096)
        node.parameters["maximumOutputTokens"] = .integer(256)
        node.parameters["minimumPixels"] = .integer(1024)
        node.parameters["ghp_parameter_canary"] = .text("ordinary value")
        node.parameters["toolsJSON"] = .text(#"[{"name":"ghp_review_canary","description":"Local tool","parameters":{"type":"object"}},{"name":"calculator","description":"Arithmetic","parameters":{"type":"object"}}]"#)
        let messages = #"[{"role":"assistant","parts":[{"type":"text","text":"Calling"}],"toolCalls":[{"id":"sk-review-canary","name":"ghp_review_canary","arguments":{}}]},{"role":"tool","parts":[{"type":"text","text":"Done"}],"toolCallID":"sk-review-canary"}]"#
        let attempt = ChatAttempt(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(),
                                  node: node, messagesJSON: messages, inputs: [:],
                                  systemPrompt: "Ordinary rule", status: .completed)
        let inspection = ChatRequestInspection(attempt: attempt)
        let ordered = try #require(inspection.sections.first { $0.id == "messages" })
        #expect(ordered.fields.first?.value == "Decoded 2 stored messages")
        #expect(ordered.fields[1].value.contains("Tool call 1: [withheld]"))
        #expect(ordered.fields[2].value.contains("Tool result for call: [withheld]"))
        let declarations = try #require(inspection.sections.first { $0.id == "tools" })
        #expect(declarations.fields.contains { $0.id == "tool.0" && $0.value == "[withheld]" })
        #expect(declarations.fields.contains { $0.id == "tool.1" && $0.value == "calculator" })
        let parameters = try #require(inspection.sections.first { $0.id == "parameters" })
        #expect(parameters.fields.contains { $0.id == "ghp_parameter_canary" && $0.label == "[withheld]" && $0.value == "[redacted]" })
        for (key, value) in [("maximumPromptTokens", "4096"), ("maximumOutputTokens", "256"), ("minimumPixels", "1024")] {
            #expect(parameters.fields.contains { $0.id == key && $0.label == key && $0.value == value })
        }
        let visible = inspection.sections.flatMap(\.fields).flatMap { [$0.label, $0.value] }.joined(separator: "\n")
        for canary in ["sk-review-canary", "ghp_review_canary", "ghp_parameter_canary"] {
            #expect(!visible.contains(canary))
            #expect(!inspection.redactedJSON.contains(canary))
        }
    }

    @Test func malformedJSONWithholdsEntireSourceEvenWhenCanaryHasNoIndicator() throws {
        var node = WorkflowNode(operationID: WorkflowModelRoutes.qwen35, definitionVersion: 2, title: "chat")
        node.parameters["toolsJSON"] = .text(#"[{"name":"tool","parameters": malformed-tool-canary"#)
        let attempt = ChatAttempt(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(),
                                  node: node, messagesJSON: #"[{"role":"user","parts": [ malformed-source-canary"#,
                                  inputs: [:], systemPrompt: "Readable ordinary rule", status: .failed)
        let inspection = ChatRequestInspection(attempt: attempt)
        let visible = inspection.sections.flatMap(\.fields).map(\.value).joined(separator: "\n")
        #expect(visible.contains("could not be decoded"))
        #expect(visible.contains("Readable ordinary rule"))
        #expect(!visible.contains("malformed-source-canary"))
        #expect(inspection.sections.first { $0.id == "tools" }?.fields.first?.value.contains("could not be decoded") == true)
        #expect(!visible.contains("malformed-tool-canary"))
    }

    private func inspection(node: WorkflowNode) -> ChatRequestInspection {
        ChatRequestInspection(attempt: .init(sessionID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(),
                                              node: node, messagesJSON: "[]", inputs: [:], systemPrompt: "",
                                              status: .completed))
    }

    private func exportedParameters(_ inspection: ChatRequestInspection) throws -> [String: String] {
        let report = try #require(JSONSerialization.jsonObject(with: Data(inspection.redactedJSON.utf8)) as? [String: Any])
        return try #require(report["parameters"] as? [String: String])
    }
}
