import Darwin
import Foundation

/// Packages two fixed, conversion-free video recipes. It never loads a model or
/// modifies the raw installation. Wan requires a different numeric conversion.
enum ModelVideoPreparation {
    static func profile(for entry: ModelCatalogEntry) -> String? {
        switch (entry.id, entry.revision) {
        case ("minimax-h3-fl2va-bf16", "42ed227ee7df40d41602854ae760620d6eb651fe"):
            return "minimax-h3-fl2va-bf16-full-v1"
        case ("ltx-2.5-bf16", "e378b7e1b50fcb1795fce74219b40bb0b1ede1e2"):
            return "ltx-2.5-dev-bf16-full-v1"
        default: return nil
        }
    }

    static func prepare(source: ModelDirectory, entry: ModelCatalogEntry, parent: ModelDirectory,
                        name: String, checkpoint: @Sendable (Int) throws -> Void = { _ in }) throws -> URL {
        guard let profile = profile(for: entry), try ModelDirectory.parts(name).count == 1 else {
            throw ModelLibraryError.invalidCatalog("此资源需要尚未接入的转换步骤，不会伪造执行包。")
        }
        let sourcePath = source.url.path + "/", targetPath = parent.url.appendingPathComponent(name).path + "/"
        guard !targetPath.hasPrefix(sourcePath), !sourcePath.hasPrefix(targetPath) else {
            throw ModelLibraryError.unsafePath("执行包位置不能与原始模型目录重叠。")
        }
        try parent.validateLocation()
        var existing = stat()
        guard fstatat(parent.descriptor, name, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw ModelLibraryError.unsafePath("执行包目标已存在；不会覆盖。")
        }
        let requiredPaths = Set(entry.files.map(\.path))
        let before = try source.verifyRequired(entry.files)
        guard Set(before.files.keys) == requiredPaths else {
            throw ModelLibraryError.integrity("原始文件清单不完整。")
        }
        let stageName = ".d-video-preparing-" + UUID().uuidString
        guard mkdirat(parent.descriptor, stageName, 0o700) == 0 else { throw ModelDirectory.failure("创建执行包暂存目录") }
        let stage = try parent.child(stageName)
        do {
            for (index, file) in entry.files.enumerated() {
                try Task.checkCancellation(); try checkpoint(index)
                guard let identity = before.files[file.path], identity.size >= 0, UInt64(identity.size) == file.size else {
                    throw ModelLibraryError.integrity("原始文件大小与固定清单不符。")
                }
                try copy(file.path, from: source, to: "model/" + file.path, in: stage)
            }
            let packaged = entry.files.map { ModelFile(path: "model/" + $0.path, size: $0.size,
                sha256: $0.sha256, digestAlgorithm: $0.digestAlgorithm) }
            let verified = try stage.verify(packaged)
            try Task.checkCancellation(); try checkpoint(entry.files.count)
            guard try source.requiredTree(paths: requiredPaths) == before else {
                throw ModelLibraryError.integrity("准备期间原始模型发生变化；未发布。")
            }
            guard try stage.entries(expectedPaths: Set(verified.keys)) == verified else {
                throw ModelLibraryError.integrity("校验后执行包文件已改变；未发布。")
            }
            let descriptor = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                "profile": profile, "modelRevision": entry.revision], options: [.sortedKeys])
            try stage.atomicWrite(descriptor, to: "D-VIDEO-PACK.json", replace: false)
            var publishedFiles = verified
            publishedFiles["D-VIDEO-PACK.json"] = try stage.fileIdentity("D-VIDEO-PACK.json")
            guard try stage.entries(expectedPaths: Set(publishedFiles.keys)) == publishedFiles else {
                throw ModelLibraryError.integrity("发布前执行包已改变。")
            }
            try source.validateLocation(); try parent.validateLocation(); try stage.validateLocation()
            try Task.checkCancellation()
            guard renameatx_np(parent.descriptor, stageName, parent.descriptor, name, UInt32(RENAME_EXCL)) == 0 else {
                throw ModelDirectory.failure("发布执行包")
            }
            guard fsync(parent.descriptor) == 0 else {
                throw ModelLibraryError.storage("执行包已发布，但目录同步失败；文件保留在 \(parent.url.appendingPathComponent(name).path)。")
            }
            let published = try parent.child(name)
            guard published.identity.sameNode(stage.identity),
                  try published.entries(expectedPaths: Set(publishedFiles.keys)) == publishedFiles else {
                throw ModelLibraryError.integrity("发布后的执行包身份改变；保留文件但拒绝登记。")
            }
            return published.url
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Keep partial output as evidence/recovery material. Never remove a path
            // whose contents may have changed; an unfinished pack is never returned.
            throw ModelLibraryError.storage("执行包未确认完成：\(error.localizedDescription)。已保留本次文件：\(stage.url.path)；原模型未修改。")
        }
    }

    private static func copy(_ path: String, from source: ModelDirectory, to destination: String, in target: ModelDirectory) throws {
        let input = try source.openFile(path); defer { Darwin.close(input) }
        let original = try ModelDirectory.identity(input, regular: true)
        let (parent, name) = try target.parent(destination, create: true); defer { Darwin.close(parent) }
        // APFS clone uses independent inodes, never hard links. Other volumes use
        // a bounded cancellable copy; neither path replaces an existing leaf.
        if fclonefileat(input, parent, name, 0) != 0 {
            guard [EXDEV, ENOTSUP, EINVAL].contains(errno) else { throw ModelDirectory.failure("克隆模型文件") }
            let output = Darwin.openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw ModelDirectory.failure("创建执行包文件") }
            defer { Darwin.close(output) }
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw ModelDirectory.failure("读取原始模型") }
                if count == 0 { break }
                try ModelDirectory.write(Data(buffer.prefix(count)), to: output)
            }
            guard fsync(output) == 0 else { throw ModelDirectory.failure("保存执行包文件") }
        }
        guard try ModelDirectory.identity(input, regular: true) == original,
              try source.fileIdentity(path) == original else { throw ModelLibraryError.integrity("复制期间原始模型改变。") }
        let output = try target.openFile(destination); defer { Darwin.close(output) }
        guard fsync(output) == 0, fsync(parent) == 0 else { throw ModelDirectory.failure("同步执行包文件") }
        let copied = try target.fileIdentity(destination)
        guard !copied.sameNode(original), copied.size == original.size else {
            throw ModelLibraryError.integrity("执行包必须独立保存且保持原文件大小。")
        }
    }
}
