import Foundation
import Testing
@testable import DWorkbench

@Suite("Model node descriptive catalog", .serialized)
struct ModelNodeCatalogTests {
    private func node(_ id: String) throws -> ModelNodeDescriptor {
        try #require(ModelNodeCatalog.entries.first { $0.id == id })
    }

    private func operation(_ id: String, in node: ModelNodeDescriptor) throws -> ModelNodeOperation {
        try #require(node.operations.first { $0.id == id })
    }

    @Test func catalogHasFrozenIdentityCoverageAndUniqueNestedIDs() {
        let entries = ModelNodeCatalog.entries
        #expect(entries.count == 12)
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.map(\.id) == [
            "flux2-klein-4b-q8",
            "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            "mlx-community/Qwen2.5-7B-Instruct-4bit",
            "mlx-community/Qwen2.5-32B-Instruct-4bit",
            "sm-music", "sm-sfx", "medium",
            "mrt2-small-export-v1", "swift-f0-0.1.2-cpu-v1",
            "audio.singing.qixuan", "wan21-t2v-1.3b-bf16-v1"
        ])

        let grouped = Dictionary(grouping: entries, by: \.modality).mapValues(\.count)
        #expect(grouped == [.image: 1, .text: 4, .audio: 6, .video: 1])
        #expect(entries.allSatisfy { !$0.operations.isEmpty && !$0.evidencePaths.isEmpty })
        #expect(entries.allSatisfy { node in Set(node.operations.map(\.id)).count == node.operations.count })
        #expect(entries.allSatisfy { node in
            node.operations.allSatisfy { operation in
                Set(operation.inputs.map(\.id)).count == operation.inputs.count
                    && Set(operation.outputs.map(\.id)).count == operation.outputs.count
                    && Set(operation.parameters.map(\.id)).count == operation.parameters.count
            }
        })
        #expect(entries.flatMap(\.evidencePaths).allSatisfy { !$0.hasPrefix("/") && !$0.contains("..") })
    }

    @Test func textEntriesMatchSourceRegistryAndDoNotInventA512TokenLimit() throws {
        let registered = try TextModelProfiles.registered()
        let qwen = ModelNodeCatalog.entries.filter { $0.modality == .text }
        #expect(qwen.map(\.id) == registered.map(\.id))
        #expect(qwen.map(\.revision) == registered.map(\.revision))
        #expect(qwen.allSatisfy { $0.availability == .workbench })

        let generation = try operation("text.generate/1", in: try node("mlx-community/Qwen2.5-0.5B-Instruct-4bit"))
        let prompt = try #require(generation.inputs.first { $0.id == "prompt" })
        #expect(prompt.requirement == .required)
        #expect(prompt.detail.contains("裸 MLX 后端允许空字符串"))
        let textLimitProjection = ([prompt.detail] + generation.parameters.flatMap {
            [$0.defaultValue, $0.acceptedValues, $0.detail]
        }).joined(separator: " ")
        #expect(!textLimitProjection.contains("512"))

        let temperature = try #require(generation.parameters.first { $0.id == "temperature" })
        #expect(temperature.acceptedValues.contains("没有 2.0 上限"))
        #expect(generation.parameters.contains { $0.id == "maximumPromptTokens" && $0.isAdjustable })
        #expect(generation.parameters.contains { $0.id == "maximumOutputTokens" && $0.acceptedValues.contains("max_position_embeddings") })
        #expect(!generation.parameters.contains { $0.id.lowercased().contains("seed") })
        #expect(generation.inputs.map(\.id) == ["prompt"])
        #expect(generation.outputs.map(\.id) == ["textDelta"])
        #expect(qwen.allSatisfy { $0.notes.contains { $0.contains("approximate") } })
        #expect(qwen.allSatisfy { $0.evidencePaths.contains("Sources/DInference/TextExecutionCapability.swift") })
    }

    @Test func fluxIsOneModelWithThreeProfilesAndFrozenRecipes() throws {
        let flux = try node("flux2-klein-4b-q8")
        #expect(flux.operations.map(\.id) == ["verified512/1", "scalableKlein4B/1", "referenceKlein4B/1"])
        #expect(flux.operations.filter { $0.inputs.contains { $0.id == "referenceImage" } }.map(\.id) == ["referenceKlein4B/1"])

        for operation in flux.operations {
            #expect(operation.parameters.contains { $0.id == "steps" && !$0.isAdjustable && $0.defaultValue == "4" })
            #expect(operation.parameters.contains { $0.id == "guidance" && !$0.isAdjustable && $0.defaultValue == "1" })
            #expect(operation.parameters.contains { $0.id == "conditioningLength" && !$0.isAdjustable })
            #expect(!operation.parameters.contains { ["strength", "negativePrompt", "mask"].contains($0.id) })
        }
        let reference = try operation("referenceKlein4B/1", in: flux)
        let referenceInput = try #require(reference.inputs.first { $0.id == "referenceImage" })
        #expect(referenceInput.requirement == .required)
        #expect(referenceInput.dataType.contains("frozen ImageReference"))
        #expect(referenceInput.detail.contains("256…2048"))
        #expect(referenceInput.detail.contains("32 的倍数"))
        #expect(referenceInput.detail.contains("不必匹配输出尺寸"))
        #expect(reference.outputs.first?.dataType.contains("DeviceRGB") == true)
        #expect(flux.notes.contains { $0.contains("控制保真度") && $0.contains("approximate") })
        #expect(flux.notes.contains { $0.contains("不保证未提及区域像素保持不变") })
        #expect(flux.evidencePaths.contains("Sources/DInference/ImageReference.swift"))
        #expect(flux.evidencePaths.contains("Packages/UI/Sources/DWorkbench/Media/ImageReferencePixels.swift"))
    }

    @Test func audioEntriesPreserveOperationAndPortSemantics() throws {
        for id in ["sm-music", "sm-sfx", "medium"] {
            let stableAudio = try node(id)
            #expect(stableAudio.device.contains("MLX 默认 GPU 策略"))
            #expect(stableAudio.device.contains("不是逐次运行"))
            #expect(stableAudio.operations.map(\.id) == [
                "audio.sa3.diffusion.generate",
                "audio.sa3.diffusion.variation",
                "audio.sa3.diffusion.inpaint"
            ])
            let generate = try operation("audio.sa3.diffusion.generate", in: stableAudio)
            #expect(!generate.inputs.contains { $0.id == "referenceAudio" || $0.id == "editRegion" })
            let variation = try operation("audio.sa3.diffusion.variation", in: stableAudio)
            #expect(variation.inputs.first { $0.id == "referenceAudio" }?.requirement == .required)
            #expect(!variation.inputs.contains { $0.id == "editRegion" })
            let inpaint = try operation("audio.sa3.diffusion.inpaint", in: stableAudio)
            #expect(inpaint.inputs.first { $0.id == "referenceAudio" }?.requirement == .required)
            #expect(inpaint.inputs.first { $0.id == "editRegion" }?.requirement == .required)
        }

        let mrt2Operation = try #require((try node("mrt2-small-export-v1")).operations.first)
        let sequence = try #require(mrt2Operation.inputs.first { $0.id == "noteSequence" })
        #expect(sequence.requirement == .required)
        #expect(sequence.detail.contains("notes 缺席"))
        #expect(sequence.detail.contains("notes=[]"))
        #expect(mrt2Operation.parameters.contains {
            $0.id == "durationFrames" && $0.defaultValue.contains("工作台新建默认 150 帧（6 秒）")
        })
        #expect((try node("mrt2-small-export-v1")).device.contains("MLX 默认 GPU 策略"))

        let analysis = try node("swift-f0-0.1.2-cpu-v1")
        #expect(analysis.operations.map(\.id) == ["audio.pitch.analyze"])
        #expect(analysis.summary.contains("不生成声音"))
        #expect(analysis.engine.hasPrefix("cpu.pitch.swift-f0"))
        #expect(!analysis.engine.contains("backendcpu"))
        #expect(analysis.operations[0].inputs[0].detail.contains("原始来源须为 mono"))
        #expect(analysis.operations[0].inputs[0].detail.contains("派生 16 kHz 样本"))
        #expect(analysis.operations[0].outputs.first { $0.id == "analysis" }?.requirement == .required)
        #expect(analysis.operations[0].outputs.first { $0.id == "interpretation" }?.requirement == .optional)
        #expect(analysis.operations[0].outputs.first { $0.id == "interpretation" }?.detail.contains("宿主程序派生") == true)

        let singing = try node("audio.singing.qixuan")
        #expect(singing.availability == .backend)
        #expect(singing.device.contains("Qixuan original ONNX 固定 CPU"))
        #expect(singing.device.contains("MPS"))
        #expect(singing.device.contains("不自动回退"))
        #expect(!singing.device.contains("优先"))
        #expect(!singing.operations[0].parameters.contains { $0.id == "seed" })
        #expect(singing.operations[0].inputs.map(\.id) == ["phrase", "pronunciations", "vowelIndices"])
        #expect(singing.operations[0].inputs.first { $0.id == "pronunciations" }?.detail.contains("[\"SP\"]") == true)
        #expect(singing.operations[0].inputs.first { $0.id == "vowelIndices" }?.requirement == .required)
        #expect(singing.operations[0].outputs.map(\.id) == ["audio"])
        let profile = try #require(singing.operations[0].parameters.first { $0.id == "executionProfile" })
        #expect(profile.defaultValue.contains("须显式选择"))
        #expect(!profile.defaultValue.contains("优先"))
        #expect(profile.detail.contains("不做自动回退"))
    }

    @Test func videoEntryIsWan21TextToVideoOnlyWithJointGeometryLimit() throws {
        let wan = try node("wan21-t2v-1.3b-bf16-v1")
        let generation = try #require(wan.operations.first)
        #expect(generation.inputs.map(\.id) == ["positivePrompt", "negativePrompt"])
        #expect(generation.inputs[0].requirement == .required)
        #expect(generation.inputs[1].requirement == .optional)
        #expect(generation.outputs.map(\.id) == ["video"])
        #expect(!generation.inputs.contains { ["firstFrame", "referenceImage", "audio", "mask", "timeline"].contains($0.id) })
        #expect(generation.parameters.first { $0.id == "geometry" }?.acceptedValues.contains("≤ 1024") == true)
        #expect(wan.notes.contains { $0.contains("没有 I2V") })
        #expect(wan.notes.contains { $0.contains("Wan 2.2") && $0.contains("不列为可运行节点") })
        #expect(wan.notes.contains { $0.contains("frames.rgb") && $0.contains("不是公开节点输出端口") })
        #expect(wan.device.contains("MLX 默认 GPU 策略"))
        #expect(wan.device.contains("不是逐次运行"))
    }

    @MainActor
    @Test func inMemoryTagsTrimSupportUnicodeAndStayIsolatedWithoutGlobalWrites() throws {
        let modelID = "fixture-\(UUID().uuidString)"
        let standardKey = "D.ModelNodeTags.v1.\(modelID)"
        #expect(UserDefaults.standard.object(forKey: standardKey) == nil)

        let store = ModelNodeTagStore()
        #expect(store.tags(for: modelID).isEmpty)
        try store.setTags(["  人声  ", "🎛️", "e\u{301}"], for: modelID)
        #expect(store.tags(for: modelID) == ["人声", "🎛️", "e\u{301}"])
        #expect(store.tags(for: "another-model").isEmpty)
        #expect(UserDefaults.standard.object(forKey: standardKey) == nil)
    }

    @MainActor
    @Test func tagValidationIsAtomicAndCountsSwiftCharacters() throws {
        let store = ModelNodeTagStore()
        try store.setTags(["原有"], for: "model")

        expectTagError(.emptyTag) { try store.setTags([" \n\t "], for: "model") }
        expectTagError(.duplicateTag("重复")) { try store.setTags(["重复", " 重复 "], for: "model") }
        expectTagError(.tooManyTags(maximum: 24)) {
            try store.setTags((0...24).map(String.init), for: "model")
        }
        let thirtyThree = String(repeating: "界", count: 33)
        expectTagError(.tagTooLong(tag: thirtyThree, maximumCharacters: 32)) {
            try store.setTags([thirtyThree], for: "model")
        }
        #expect(store.tags(for: "model") == ["原有"])

        let thirtyTwoEmoji = String(repeating: "🙂", count: 32)
        try store.setTags([thirtyTwoEmoji], for: "model")
        #expect(store.tags(for: "model") == [thirtyTwoEmoji])
    }

    @MainActor
    @Test func injectedSuitePersistsAndCorruptOneModelDoesNotEraseAnother() throws {
        let suiteName = "D.ModelNodeCatalogTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }

        let writer = ModelNodeTagStore(settings: settings)
        try writer.setTags(["  持久标签  ", "🎵"], for: "good-model")
        let reopenedSettings = try #require(UserDefaults(suiteName: suiteName))
        let reader = ModelNodeTagStore(settings: reopenedSettings)
        #expect(reader.tags(for: "good-model") == ["持久标签", "🎵"])

        reopenedSettings.set(Data([0x00, 0x01]), forKey: "D.ModelNodeTags.v1.corrupt-model")
        #expect(reader.tags(for: "corrupt-model").isEmpty)
        #expect(reader.tags(for: "good-model") == ["持久标签", "🎵"])
        #expect(reopenedSettings.data(forKey: "D.ModelNodeTags.v1.corrupt-model") == Data([0x00, 0x01]))

        try reader.setTags([], for: "good-model")
        #expect(reader.tags(for: "good-model").isEmpty)
        #expect(reopenedSettings.object(forKey: "D.ModelNodeTags.v1.good-model") == nil)
    }

    @MainActor
    private func expectTagError(_ expected: ModelNodeTagStoreError, body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected tag validation to fail with \(expected.localizedDescription)")
        } catch let error as ModelNodeTagStoreError {
            #expect(error == expected)
            #expect(!error.localizedDescription.isEmpty)
        } catch {
            Issue.record("Unexpected tag validation error: \(error)")
        }
    }
}
