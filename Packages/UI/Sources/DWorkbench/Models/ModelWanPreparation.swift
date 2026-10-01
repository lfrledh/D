import CryptoKit
import Darwin
import DInference
import Foundation

/// The App supplies the bounded converter; this layer retains installation and
/// destination ownership and publishes only a separately verified completed pack.
enum ModelWanPreparation {
    static let revision = "37ec512624d61f7aa208f7ea8140a131f93afc9a"
    static func supports(_ entry: ModelCatalogEntry) -> Bool {
        entry.id == "wan21-t2v-1.3b-bf16" && entry.revision == revision
    }
    static func allowsExternalRawProjection(_ entry: ModelCatalogEntry) -> Bool {
        supports(entry) && entry.repository == "Wan-AI/Wan2.1-T2V-1.3B" && entry.preparation == .required
    }
    typealias Converter = @Sendable (URL, URL) async throws -> Void
    private struct Manifest: Decodable {
        var schemaVersion: Int
        var complete: Bool
        var repository: String
        var revision: String
        var preparation: String
        var precision: [String: String]
        var tensors: [Tensor]
        var originals: [Original]
    }
    private struct Tensor: Decodable {
        var role: String; var name: String; var path: String
        var shape: [Int]; var dtype: String; var size: UInt64; var sha256: String
    }
    private struct Original: Decodable { var path: String; var size: UInt64; var sha256: String }

    static func verifiedFiles(in stage: ModelDirectory, entry: ModelCatalogEntry) throws -> [String: ModelFileIdentity] {
        let marker = "D-VIDEO-PREPARED.json"
        let data = try stage.read(marker, maximum: 2 * 1024 * 1024)
        let value = try JSONDecoder().decode(Manifest.self, from: data)
        guard supports(entry), value.schemaVersion == 1, value.complete,
              value.revision == revision, value.repository == "Wan-AI/Wan2.1-T2V-1.3B",
              value.preparation == "original-names-tensor-shards-v1",
              value.precision == ["text": "BF16", "diffusion": "BF16 with original FP32 time/head/modulation/norm tensors", "vae": "F32"],
              value.tensors.count == 1261,
              Set(value.originals.map(\.path)).count == value.originals.count,
              Set(value.originals.map(\.path)) == Set(entry.files.map(\.path)),
              value.originals.allSatisfy({ original in entry.files.contains { $0.path == original.path && $0.size == original.size && $0.sha256 == original.sha256 && $0.digestAlgorithm == .sha256 } }) else {
            throw ModelLibraryError.integrity("Wan 执行包清单与固定原始模型或精度不一致。")
        }
        var counts: [String: Int] = [:], names = Set<String>(), paths = Set<String>()
        let files = try value.tensors.map { row -> ModelFile in
            let index = counts[row.role, default: 0]
            guard ["text", "diffusion", "vae"].contains(row.role),
                  row.path == String(format: "%@/%04d.safetensors", row.role, index),
                  !row.name.isEmpty, row.name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 46 }),
                  names.insert(row.role + ":" + row.name).inserted, paths.insert(row.path).inserted,
                  !row.shape.isEmpty, row.shape.count <= 5, row.shape.allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }),
                  row.size > 0, row.sha256.count == 64, row.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ModelLibraryError.integrity("Wan 执行包张量清单无效。")
            }
            let fp32 = row.role == "vae" || (row.role == "diffusion" &&
                (["time_embedding.", "time_projection.", "head."].contains(where: row.name.hasPrefix) || row.name.hasSuffix(".modulation") || row.name.split(separator: ".").contains(where: { $0.hasPrefix("norm") })))
            guard row.dtype == (fp32 ? "F32" : "BF16") else { throw ModelLibraryError.integrity("Wan 张量精度与既定转换不一致。") }
            counts[row.role] = index + 1
            return .init(path: row.path, size: row.size, sha256: row.sha256)
        }
        guard counts == ["text": 242, "diffusion": 825, "vae": 194] else { throw ModelLibraryError.integrity("Wan 模型张量不完整。") }
        let markerFile = ModelFile(path: marker, size: UInt64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        return try stage.verify(files + [markerFile])
    }

    static func prepare(source: ModelDirectory, entry: ModelCatalogEntry, parent: ModelDirectory,
                        name: String, externalRawProjection: Bool = false, converter: Converter) async throws -> URL {
        guard supports(entry), try ModelDirectory.parts(name).count == 1 else { throw ModelLibraryError.invalidCatalog("此资源不是固定 Wan 转换配方。") }
        guard !externalRawProjection || allowsExternalRawProjection(entry) else {
            throw ModelLibraryError.invalidCatalog("原始目录投影仅适用于固定 Wan 外部仓。")
        }
        let sourcePath = source.url.path + "/", targetPath = parent.url.appendingPathComponent(name).path + "/"
        guard !targetPath.hasPrefix(sourcePath), !sourcePath.hasPrefix(targetPath) else { throw ModelLibraryError.unsafePath("执行包位置不能与原始模型重叠。") }
        try parent.validateLocation()
        var existing = stat()
        guard fstatat(parent.descriptor, name, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ModelLibraryError.unsafePath("执行包目标已存在；不会覆盖。") }
        let requiredPaths = Set(entry.files.map(\.path))
        let before = externalRawProjection ? try source.verifyRequired(entry.files) :
            ModelRequiredTree(files: try source.entries(expectedPaths: requiredPaths), directories: [:])
        guard Set(before.files.keys) == requiredPaths else { throw ModelLibraryError.integrity("原始模型清单不完整。") }
        let stageName = ".d-wan-preparing-" + UUID().uuidString
        let stageURL = parent.url.appendingPathComponent(stageName, isDirectory: true)
        do {
            try Task.checkCancellation()
            try await converter(source.url, stageURL)
            try Task.checkCancellation()
            let stage = try parent.child(stageName)
            let verified = try verifiedFiles(in: stage, entry: entry)
            let after = externalRawProjection ? try source.verifyRequired(entry.files) :
                ModelRequiredTree(files: try source.entries(expectedPaths: requiredPaths), directories: [:])
            guard after == before,
                  try stage.entries(expectedPaths: Set(verified.keys)) == verified else { throw ModelLibraryError.integrity("准备期间原件或执行包发生变化；未发布。") }
            try source.validateLocation(); try parent.validateLocation(); try stage.validateLocation()
            try Task.checkCancellation()
            guard renameatx_np(parent.descriptor, stageName, parent.descriptor, name, UInt32(RENAME_EXCL)) == 0 else { throw ModelDirectory.failure("发布 Wan 执行包") }
            guard fsync(parent.descriptor) == 0 else { throw ModelLibraryError.storage("Wan 执行包已发布但目录同步失败，文件保留。") }
            let published = try parent.child(name)
            guard published.identity.sameNode(stage.identity), try published.entries(expectedPaths: Set(verified.keys)) == verified else { throw ModelLibraryError.integrity("发布后身份改变，保留文件但拒绝登记。") }
            return published.url
        } catch is CancellationError { throw CancellationError() }
        catch {
            if case .resourceCleanupUnconfirmed = error as? InferenceFailure { throw error }
            throw ModelLibraryError.storage("Wan 准备未完成：\(error.localizedDescription)。本次暂存保留在 \(stageURL.path)；原件未修改。")
        }
    }
}
