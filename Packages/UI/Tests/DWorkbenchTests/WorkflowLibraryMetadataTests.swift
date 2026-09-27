import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow library and project asset tags")
struct WorkflowLibraryMetadataTests {
    @Test func validationEnforcesBoundsAndPreservesUnicodeBytes() throws {
        let decomposed = "e\u{301} 🎨"
        let result = try LibraryTags.validate(["  \(decomposed)  ", String(repeating: "界", count: 32)])
        #expect(result == [decomposed, String(repeating: "界", count: 32)])
        #expect(Array(result[0].utf8) == Array(decomposed.utf8))
        #expect(Array(result[0].utf8) != Array("é 🎨".utf8))
        #expect(try LibraryTags.validate(["Tag", "tag"]) == ["Tag", "tag"])

        #expect(throws: LibraryTagsError.emptyTag) { try LibraryTags.validate([" \n "]) }
        #expect(throws: LibraryTagsError.duplicateTag("same")) {
            try LibraryTags.validate(["same", " same "])
        }
        #expect(throws: LibraryTagsError.tagTooLong(
            tag: String(repeating: "界", count: 33), maximumCharacters: 32
        )) {
            try LibraryTags.validate([String(repeating: "界", count: 33)])
        }
        #expect(throws: LibraryTagsError.tooManyTags(maximum: 24)) {
            try LibraryTags.validate((0...24).map(String.init))
        }
    }

    @Test func searchRequiresEveryTokenAndEverySystemOrUserTag() {
        #expect(LibrarySearch.matches(
            query: "portrait q8",
            selectedTags: [],
            title: "Camera",
            detail: "",
            systemTags: ["q8"],
            userTags: ["portrait"]
        ))
        #expect(!LibrarySearch.matches(
            query: "portrait absent",
            selectedTags: [],
            title: "Camera",
            detail: "",
            systemTags: ["q8"],
            userTags: ["portrait"]
        ))
        #expect(LibrarySearch.matches(
            query: "QUICK cafe",
            selectedTags: ["ｉｍａｇｅ", "CAFE"],
            title: "Quick study",
            detail: "A café reference",
            systemTags: ["image"],
            userTags: ["café"]
        ))
        #expect(!LibrarySearch.matches(
            query: "quick missing",
            selectedTags: [],
            title: "Quick study",
            detail: "A café reference",
            systemTags: ["image"],
            userTags: ["café"]
        ))
        #expect(!LibrarySearch.matches(
            query: "quick",
            selectedTags: ["image", "missing"],
            title: "Quick study",
            detail: "A café reference",
            systemTags: ["image"],
            userTags: ["café"]
        ))
    }

    @Test func tagsPersistWithoutChangingAssetIdentityMediaOrProvenanceAndNilDiffersFromEmpty() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "标签持久化")
            let (baseline, asset, media, mediaBytes) = try await completedAsset(in: fixture, store: store)
            let decomposed = "e\u{301}"
            let tagged = try await store.updateAsset(id: asset.id, tags: ["  人像  ", decomposed])
            var expectedAsset = asset
            expectedAsset.tags = ["人像", decomposed]
            #expect(tagged.assets.first == expectedAsset)
            #expect(tagged.revision == baseline.revision + 1)
            #expect(try Data(contentsOf: media) == mediaBytes)
            try await store.close()

            let reopened = try await ProjectStore.open(at: fixture.project)
            let persisted = await reopened.snapshot()
            #expect(persisted.assets.first?.tags == ["人像", decomposed])
            #expect(Array(try #require(persisted.assets.first?.tags.last).utf8) == Array(decomposed.utf8))
            let unchanged = try await reopened.updateAsset(id: asset.id, tags: nil)
            #expect(unchanged.revision == persisted.revision)
            #expect(unchanged.assets.first?.tags == ["人像", decomposed])
            let cleared = try await reopened.updateAsset(id: asset.id, tags: [])
            #expect(cleared.revision == persisted.revision + 1)
            #expect(cleared.assets.first?.tags == [])
            try await reopened.close()

            let clearedReopen = try await ProjectStore.open(at: fixture.project)
            #expect(await clearedReopen.snapshot().assets.first?.tags == [])
            #expect(try Data(contentsOf: media) == mediaBytes)
            try await clearedReopen.close()
        }
    }

    @Test func schemaSeventeenMigrationKeepsExactBackupSnapshotAndMedia() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "旧标签格式")
            let (_, _, media, mediaBytes) = try await completedAsset(in: fixture, store: store)
            try await store.close()

            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            var json = try manifestObject(at: file)
            json["schemaVersion"] = 17
            var assets = try #require(json["assets"] as? [[String: Any]])
            for index in assets.indices { assets[index].removeValue(forKey: "tags") }
            json["assets"] = assets
            let legacyBytes = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try legacyBytes.write(to: file)
            var expected = try JSONDecoder().decode(ProjectManifest.self, from: legacyBytes)

            let reopened = try await ProjectStore.open(at: fixture.project)
            let migrated = await reopened.snapshot()
            expected.schemaVersion = ProjectManifest.currentSchemaVersion
            expected.revision += 1
            expected.updatedAt = migrated.updatedAt
            #expect(migrated == expected)
            #expect(migrated.assets.allSatisfy { $0.tags.isEmpty })
            #expect(try Data(contentsOf: fixture.project.appendingPathComponent(
                ProjectStore.versionSeventeenBackupFilename
            )) == legacyBytes)
            #expect(try Data(contentsOf: media) == mediaBytes)
            try await reopened.close()
        }
    }

    @Test func canonicallyEquivalentTagByteChangesCommitInBothDirections() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "标签原字节")
            let (baseline, originalAsset, media, mediaBytes) = try await completedAsset(in: fixture, store: store)
            let nfc = "é"
            let nfd = "e\u{301}"

            let initialNFC = try await store.updateAsset(id: originalAsset.id, tags: [nfc])
            #expect(initialNFC.revision == baseline.revision + 1)
            try await store.close()

            let nfcReopen = try await ProjectStore.open(at: fixture.project)
            let nfcSnapshot = await nfcReopen.snapshot()
            #expect(nfcSnapshot.revision == initialNFC.revision)
            let persistedNFC = try #require(nfcSnapshot.assets.first?.tags.first)
            #expect(Array(persistedNFC.utf8) == Array(nfc.utf8))
            let nfdUpdate = try await nfcReopen.updateAsset(id: originalAsset.id, tags: [nfd])
            #expect(nfdUpdate.revision == initialNFC.revision + 1)
            #expect(Array(try #require(nfdUpdate.assets.first?.tags.first).utf8) == Array(nfd.utf8))
            try await nfcReopen.close()

            let nfdReopen = try await ProjectStore.open(at: fixture.project)
            let nfdSnapshot = await nfdReopen.snapshot()
            #expect(nfdSnapshot.revision == nfdUpdate.revision)
            let persistedNFD = try #require(nfdSnapshot.assets.first?.tags.first)
            #expect(Array(persistedNFD.utf8) == Array(nfd.utf8))
            let reverseNFC = try await nfdReopen.updateAsset(id: originalAsset.id, tags: [nfc])
            #expect(reverseNFC.revision == nfdUpdate.revision + 1)
            #expect(Array(try #require(reverseNFC.assets.first?.tags.first).utf8) == Array(nfc.utf8))
            try await nfdReopen.close()

            let finalReopen = try await ProjectStore.open(at: fixture.project)
            let final = await finalReopen.snapshot()
            #expect(final.revision == reverseNFC.revision)
            let finalAsset = try #require(final.assets.first)
            #expect(Array(try #require(finalAsset.tags.first).utf8) == Array(nfc.utf8))
            var originalWithoutTags = originalAsset
            originalWithoutTags.tags = []
            var finalWithoutTags = finalAsset
            finalWithoutTags.tags = []
            #expect(finalWithoutTags == originalWithoutTags)
            #expect(final.jobs == baseline.jobs)
            #expect(final.documents == baseline.documents)
            #expect(try Data(contentsOf: media) == mediaBytes)
            try await finalReopen.close()
        }
    }

    @Test func presentNullWrongTypeAndInvalidPersistedTagsAreRejectedWithoutRewrite() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "损坏标签")
            _ = try await completedAsset(in: fixture, store: store)
            try await store.close()
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            let clean = try manifestObject(at: file)

            let corruptValues: [Any] = [NSNull(), "not-an-array", [" untrimmed "]]
            for corruptValue in corruptValues {
                var json = clean
                var assets = try #require(json["assets"] as? [[String: Any]])
                assets[0]["tags"] = corruptValue
                json["assets"] = assets
                let corruptBytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
                try corruptBytes.write(to: file)
                await #expect(throws: ProjectStoreError.self) {
                    _ = try await ProjectStore.open(at: fixture.project)
                }
                #expect(try Data(contentsOf: file) == corruptBytes)
            }
        }
    }

    @Test func rejectedAndFailedTagUpdatesKeepOldSnapshotDiskAndMedia() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "标签保存失败")
            let (baseline, asset, media, mediaBytes) = try await completedAsset(in: fixture, store: store)
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            let manifestBytes = try Data(contentsOf: file)

            await #expect(throws: LibraryTagsError.emptyTag) {
                try await store.updateAsset(id: asset.id, tags: ["valid", " "])
            }
            #expect(await store.snapshot() == baseline)
            #expect(try Data(contentsOf: file) == manifestBytes)

            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.project.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.project.path) }
            await #expect(throws: ProjectStoreError.self) {
                try await store.updateAsset(id: asset.id, tags: ["durable-only"])
            }
            #expect(await store.snapshot() == baseline)
            #expect(try Data(contentsOf: file) == manifestBytes)
            #expect(try Data(contentsOf: media) == mediaBytes)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.project.path)
            try await store.close()
        }
    }

    @Test func externallyNormalizedEquivalentTagIsNotOverwritten() async throws {
        try await withFixture { fixture in
            let store = try await ProjectStore.create(at: fixture.project, name: "外部标签编辑")
            let (_, asset, _, _) = try await completedAsset(in: fixture, store: store)
            _ = try await store.updateAsset(id: asset.id, tags: ["é"])
            let file = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
            let originalBytes = try Data(contentsOf: file)
            var json = try manifestObject(at: file)
            var assets = try #require(json["assets"] as? [[String: Any]])
            assets[0]["tags"] = ["e\u{301}"]
            json["assets"] = assets
            let externalBytes = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try externalBytes.write(to: file, options: .atomic)

            await #expect(throws: ProjectStoreError.externalModification) {
                try await store.updateAsset(id: asset.id, note: "must not overwrite")
            }
            #expect(await store.snapshot().assets.first?.tags == ["é"])
            #expect(try Data(contentsOf: file) == externalBytes)

            try originalBytes.write(to: file, options: .atomic)
            try await store.close()
        }
    }
}

private func completedAsset(
    in fixture: ProjectFixture,
    store: ProjectStore
) async throws -> (ProjectManifest, ProjectAsset, URL, Data) {
    let request = fixture.request()
    _ = try await store.enqueue(request: request)
    let media = try fixture.publishPNG(jobID: request.id)
    let mediaBytes = try Data(contentsOf: media)
    let manifest = try await store.complete(
        id: request.id,
        result: .init(artifacts: [.init(url: media, mediaType: "image/png")])
    )
    return (manifest, try #require(manifest.assets.first), media, mediaBytes)
}

private func manifestObject(at file: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
}
