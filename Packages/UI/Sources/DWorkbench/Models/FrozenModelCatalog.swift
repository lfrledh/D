import Foundation

/// One bundled, normalized frozen catalog. Missing or damaged resources fail closed.
enum FrozenModelCatalog {
    private struct Document: Decodable { let schemaVersion: Int; let entries: [ModelCatalogEntry] }
    private static let loaded: Result<[ModelCatalogEntry], any Error> = Result { try load() }

    static func entries() throws -> [ModelCatalogEntry] { try loaded.get() }

    private static func load() throws -> [ModelCatalogEntry] {
        guard let url = Bundle.module.url(forResource: "release-model-catalog", withExtension: "json") else {
            throw ModelLibraryError.invalidCatalog("缺少固定模型目录资源 release-model-catalog.json。")
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        } catch {
            throw ModelLibraryError.invalidCatalog("固定模型目录资源无法读取或格式无效：\(error.localizedDescription)")
        }
        guard document.schemaVersion == 1, document.entries.count == 12,
              Set(document.entries.map(\.id)).count == document.entries.count else {
            throw ModelLibraryError.invalidCatalog("固定目录版本、条目数或身份无效。")
        }
        return document.entries
    }
}
