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
            $0.value == attempt.systemPrompt
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
