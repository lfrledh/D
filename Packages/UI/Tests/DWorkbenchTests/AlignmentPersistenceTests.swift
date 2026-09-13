import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("ALIGN: configuration is durable and independent of recommendations")
struct AlignmentPersistenceTests {
    private enum Interrupted: Error { case backup }

    @Test(arguments: [16, 32, 64, 96, 128, 192])
    func hardwareAdviceNeverDefinesSupportOrChangesSelectedValues(gib: Int) throws {
        let settings = ImageGenerationSettings(width: 512, height: 512)
        let selected = TextGenerationSettings(maximumPromptTokens: 2048, maximumOutputTokens: 256)
        let advice = try #require(ExecutionRecommendations.forMemory(bytes: UInt64(gib) * 1024 * 1024 * 1024))
        #expect(advice.maximumPromptTokens >= 2048)
        #expect(ImageExecutionCapability.scalableKlein4B.maximumWidth == 2048)
        #expect(settings.width == 512 && selected.maximumPromptTokens == 2048)
        #expect(ExecutionRecommendations.forMemory(bytes: 0) == nil)
        #expect(ExecutionRecommendations.forMemory(bytes: UInt64.max)?.imageDimension == 2048)
    }

    @Test func schemaSixBacksUpRawBytesAndDefaultsOnlyMissingFields() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "旧作品 e\u{301} 🎹")
            let manifest = try await store.createTextDocument(text: "中文 e\u{301} 👩🏽‍🎨")
            let id = manifest.activeDocumentID
            try await store.close()
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            json["schemaVersion"] = 6
            var docs = try #require(json["documents"] as? [[String: Any]])
            for i in docs.indices {
                if var draft = docs[i]["draft"] as? [String: Any] {
                    draft.removeValue(forKey: "imageSettings"); docs[i]["draft"] = draft
                }
                if var text = docs[i]["textDraft"] as? [String: Any] {
                    text.removeValue(forKey: "generationSettings"); docs[i]["textDraft"] = text
                }
            }
            json["documents"] = docs
            let raw = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try raw.write(to: file)
            await #expect(throws: Interrupted.self) {
                try await ProjectStore.open(at: fixture.project, migrationCheckpoint: { point in
                    if point == .backupDurable { throw Interrupted.backup }
                })
            }
            #expect(try Data(contentsOf: file) == raw)
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(ProjectStore.versionSixBackupFilename)) == raw)
            let opened = try await ProjectStore.open(at: fixture.project)
            let restored = await opened.snapshot()
            #expect(restored.schemaVersion == 7)
            #expect(restored.activeDocumentID == id)
            #expect(restored.activeDocument?.textDraft?.generationSettings == .legacy)
            #expect(restored.activeDocument?.textDraft?.text == "中文 e\u{301} 👩🏽‍🎨")
            #expect(restored.documents.first?.draft.imageSettings == .legacy)
            try await opened.close()
        }
    }

    @Test func configuredDraftsRoundTripAndSameRevisionCannotChangeOnlyConfiguration() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "实际配置")
            let imageID = await store.snapshot().activeDocumentID
            let image = ProjectDraft(prompt: "image", imageSettings: .init(width: 768, height: 512,
                executionProfile: .init(identifier: "scalableKlein4B")))
            _ = try await store.saveDraft(image, documentID: imageID)
            let manifest = try await store.createTextDocument(text: "原文 👨‍👩‍👧‍👦")
            let original = try #require(manifest.activeDocument?.textDraft)
            let settings = TextGenerationSettings(maximumPromptTokens: 4096, maximumOutputTokens: 512)
            let invalid = try TextDraftDocument(id: original.id, revision: original.revision,
                text: original.text, generationSettings: settings)
            await #expect(throws: ProjectStoreError.self) {
                try await store.saveTextDraft(invalid, documentID: original.id, expectedRevision: original.revision)
            }
            let edited = try TextDraftDocument(id: original.id, text: original.text, generationSettings: settings)
            _ = try await store.saveTextDraft(edited, documentID: original.id, expectedRevision: original.revision)
            try await store.close()
            let reopened = try await ProjectStore.open(at: fixture.project)
            let result = await reopened.snapshot()
            #expect(result.activeDocument?.textDraft == edited)
            #expect(result.documents.first(where: { $0.id == imageID })?.draft == image)
            try await reopened.close()
        }
    }

    @Test func malformedPresentConfigurationDoesNotBecomeLegacy() throws {
        let data = Data(#"{"prompt":"keep","randomSeed":true,"seedText":"0","imageSettings":null}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ProjectDraft.self, from: data) }
        let future = ImageGenerationSettings(width: 1024, height: 512,
            executionProfile: .init(identifier: "future", revision: 77))
        let decoded = try JSONDecoder().decode(ImageGenerationSettings.self, from: JSONEncoder().encode(future))
        #expect(decoded == future)
        #expect(throws: (any Error).self) {
            try decoded.request(prompt: "keep", seed: 42, capability: .scalableKlein4B)
        }
    }
}
