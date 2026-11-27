import DInference
import DRuntime
import DMLXBackend
import Foundation
import Testing

extension MLXHardwareTests {
    @Suite("Explicit Qwen official sampling acceptance", .serialized,
           .enabled(if: ProcessInfo.processInfo.environment["D_QWEN_SAMPLING_REQUEST"] != nil || ProcessInfo.processInfo.environment["D_QWEN_SAMPLING_PREPARE"] != nil))
    struct QwenSamplingAcceptanceTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["D_QWEN_SAMPLING_PREPARE"] != nil))
        func prepareBoundedInputs() async throws {
            let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_QWEN_SAMPLING_PREPARE"]))
            let model = try JSONDecoder().decode(ModelReference.self, from: Data(contentsOf: root.appendingPathComponent("model.json")))
            let paragraphs = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("material.json")))
            let task = "Summarize the three most important recurring observations in these studio notes. Cite their observation numbers and suggest one practical next step for each. Keep your answer concise.\n\n"
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for ceiling in [8192, 16384] {
                func input(_ count: Int) -> TextRequest {
                    TextRequest(prompt: task + paragraphs.prefix(count).joined(separator: "\n\n"), maxTokens: 32768,
                        temperature: 1, topP: 0.95,
                        execution: .init(profile: TextExecutionCapability.qwen35VLMProfile, maximumPromptTokens: ceiling),
                        thinking: .init(enableThinking: true), seed: 42,
                        topK: 20, minP: 0, presencePenalty: 1.5, repetitionPenalty: 1)
                }
                var lower = 0, upper = paragraphs.count
                while lower < upper {
                    let middle = (lower + upper + 1) / 2
                    let preview = try await ChatTemplatePreviewProvider.preview(model: model, request: input(middle))
                    if preview.templateTokenIDs.count <= ceiling { lower = middle } else { upper = middle - 1 }
                }
                let request = InferenceRequest(model: model, input: .text(input(lower)), loadingSelection: .automatic)
                let preview = try await ChatTemplatePreviewProvider.preview(model: model, request: input(lower))
                try #require(preview.templateTokenIDs.count > ceiling - 256)
                let folder = root.appendingPathComponent(String(ceiling))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try encoder.encode(request).write(to: folder.appendingPathComponent("request.json"), options: .withoutOverwriting)
                try encoder.encode(preview.templateTokenIDs).write(to: folder.appendingPathComponent("template-token-ids.json"), options: .withoutOverwriting)
                try preview.renderedTemplate.write(to: folder.appendingPathComponent("rendered-template.txt"), atomically: true, encoding: .utf8)
            }
        }

        /// Opt-in only: consumes a frozen, isolated request, never a user's project.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["D_QWEN_SAMPLING_REQUEST"] != nil))
        func recordedRequest() async throws {
            let file = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_QWEN_SAMPLING_REQUEST"]))
            let root = file.deletingLastPathComponent()
            let request = try JSONDecoder().decode(InferenceRequest.self, from: Data(contentsOf: file))
            guard case .text(let input) = request.input else { throw CocoaError(.fileReadCorruptFile) }
            try #require(input.maxTokens == 32768 && input.topK == 20 && input.temperature == 1)
            try #require(input.topP == 0.95 && input.minP == 0 && input.presencePenalty == 1.5)
            try #require(input.repetitionPenalty == 1 && input.seed == 42 && input.thinking?.enableThinking == true)
            let artifacts = root.appendingPathComponent("artifacts")
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
            let backend = try MLXQwenVLMBackend(configuration: .init(artifactDirectory: artifacts,
                maximumPromptTokens: 262144, maximumOutputTokens: 262144))
            let runtime = try InferenceRuntime(backends: [backend],
                configuration: .init(memoryBudgetBytes: 12 * 1024 * 1024 * 1024),
                decideLowMemory: { _ in .allowOnce })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let started = ProcessInfo.processInfo.systemUptime
            let run = try await runtime.submit(request, backendID: backend.descriptor.id)
            var raw = "", reasoning = "", body = ""
            var firstPartial: TimeInterval?, firstBody: TimeInterval?, failure: String?
            do {
                for try await event in run.events {
                    if case .textPartial(let r, let t, let b) = event {
                        if firstPartial == nil { firstPartial = ProcessInfo.processInfo.systemUptime - started }
                        if firstBody == nil && !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { firstBody = ProcessInfo.processInfo.systemUptime - started }
                        raw += r; reasoning += t; body += b
                    }
                }
            } catch { failure = String(describing: error) }
            let outcome = await run.outcome()
            if let record = await run.executionRecord() {
                try encoder.encode(record).write(to: root.appendingPathComponent("execution.json"), options: .withoutOverwriting)
            }
            var summary: [String: Any] = ["elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "level": "controlled real production backend, Release XCTest; not ordinary App",
                "raw": raw, "reasoning": reasoning, "body": body,
                "firstPartialSeconds": firstPartial as Any? ?? NSNull(),
                "firstBodySeconds": firstBody as Any? ?? NSNull(), "failure": failure as Any? ?? NSNull()]
            switch outcome {
            case .completed(let result):
                try encoder.encode(result).write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
                summary["outcome"] = "completed"
                #expect(result.textResponse?.rawText == raw)
                #expect((result.textResponse?.reasoningText ?? "") == reasoning)
                #expect((result.textResponse?.finalText ?? "") == body)
            case .failed(let error): summary["outcome"] = "failed"; summary["error"] = String(describing: error)
            case .cancelled: summary["outcome"] = "cancelled"
            }
            let state = await runtime.snapshot()
            summary["released"] = state.activeRunID == nil && state.reservedBytes == 0
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("observed.json"), options: .withoutOverwriting)
            #expect(state.activeRunID == nil && state.reservedBytes == 0)
            await runtime.shutdown()
            #expect(summary["outcome"] as? String == "completed")
        }
    }
}
