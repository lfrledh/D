import CryptoKit
import DInference
import Darwin
import Foundation

/// Registration/each admission verify the already installed approved fixture; never download.
public enum FixedTextModel {
    public static let title = "Qwen2.5 0.5B Instruct · 4-bit"
    public static func verify(at directory: URL) async throws -> ModelReference {
        try await Task.detached(priority: .utility) {
            struct Manifest: Decodable {
                struct File: Decodable { let name: String; let size: Int; let algorithm: String; let checksum: String }
                let repository: String; let revision: String; let files: [File]
            }
            guard let resource = Bundle.module.url(forResource: "text-model", withExtension: "json") else {
                throw InferenceFailure.invalidRequest("缺少固定文字模型校验清单。")
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resource))
            let allowed = Set(manifest.files.map(\.name))
            // The existing download-test-model.py owns exactly these two bookkeeping files.
            // They are not inference inputs; never treat them as a weight/provenance authority.
            let bookkeeping: Set<String> = [".download.lock", ".provenance.json"]
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            guard allowed.isSubset(of: names), names.isSubset(of: allowed.union(bookkeeping)) else {
                throw InferenceFailure.invalidRequest("模型目录文件清单不符，请选择已批准的固定文字模型。")
            }
            for name in names.intersection(bookkeeping) {
                let fd = Darwin.open(directory.appendingPathComponent(name).path,
                                     O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw InferenceFailure.invalidRequest("模型管理文件不可读取。") }
                defer { Darwin.close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_size >= 0, info.st_size <= 65_536 else {
                    throw InferenceFailure.invalidRequest("模型管理文件的类型或大小不符。")
                }
            }
            for file in manifest.files {
                guard !file.name.contains("/"), file.name != ".." else { throw InferenceFailure.invalidRequest("校验清单路径无效。") }
                let url = directory.appendingPathComponent(file.name)
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw InferenceFailure.invalidRequest("无法读取模型文件：\(file.name)") }
                defer { Darwin.close(fd) }
                var before = stat()
                guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                      before.st_size == file.size else { throw InferenceFailure.invalidRequest("模型文件类型或大小不符：\(file.name)") }
                var sha = SHA256(); var gitSHA = Insecure.SHA1()
                if file.algorithm == "git-blob-sha1" { gitSHA.update(data: Data("blob \(file.size)\0".utf8)) }
                var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                var total = 0
                while true {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw InferenceFailure.invalidRequest("模型读取失败：\(file.name)") }
                    if count == 0 { break }
                    total += count
                    guard total <= file.size else { throw InferenceFailure.invalidRequest("模型校验期间发生变化。") }
                    let data = Data(buffer.prefix(count))
                    if file.algorithm == "sha256" { sha.update(data: data) } else { gitSHA.update(data: data) }
                }
                var after = stat()
                guard fstat(fd, &after) == 0, total == file.size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw InferenceFailure.invalidRequest("模型校验期间发生变化。") }
                let digest: String
                switch file.algorithm {
                case "sha256": digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
                case "git-blob-sha1": digest = gitSHA.finalize().map { String(format: "%02x", $0) }.joined()
                default: throw InferenceFailure.invalidRequest("不支持的校验清单算法。")
                }
                guard digest == file.checksum else { throw InferenceFailure.invalidRequest("模型内容校验不符：\(file.name)") }
            }
            return ModelReference(directory: directory, revision: manifest.revision)
        }.value
    }
}
