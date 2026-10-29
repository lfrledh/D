import CryptoKit
import DInference
import Foundation
import MLXVLM

/// A bounded seal of files already selected by the backend's model inventory.
/// ModelLibrary's full integrity check remains authoritative. No weight bytes are
/// hashed here, and a directory's unrelated modification time is not model identity.
struct ModelExecutionSeal: Sendable {
    let token: String
    let files: [String: String]
    static func qwen(_ request: InferenceRequest, backend: BackendDescriptor,
                     inventory: QwenVLMModelInventory) throws -> Self {
        let names: [String]
        if let fileSet = inventory.fileSet { names = fileSet.files.keys.sorted() }
        else {
            names = try FileManager.default.contentsOfDirectory(atPath: inventory.directory.path).filter {
                ["json", "safetensors", "jinja", "txt"].contains(URL(fileURLWithPath: $0).pathExtension)
            }.sorted()
        }
        return try capture(request.model, backend: backend, names: names)
    }
    static func capture(_ model: ModelReference, backend: BackendDescriptor, names: [String]) throws -> Self {
        guard !names.isEmpty, names.count <= 4096, Set(names).count == names.count else {
            throw InferenceFailure.invalidRequest("The admitted model file set is not bounded.")
        }
        let root = try AudioFileSystem.directoryIdentity(model.directory, label: "Model execution root")
        var files: [String: String] = [:]
        for name in names.sorted() {
            try Task.checkCancellation()
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), !name.isEmpty else {
                throw InferenceFailure.invalidRequest("Invalid admitted model path.")
            }
            let file = model.directory.appendingPathComponent(name)
            let secureIdentity = try AudioFileSystem.regularFile(file, label: "Admitted model file", maximumBytes: nil)
            files[name] = identityToken(secureIdentity)
            guard try AudioFileSystem.regularFile(file, label: "Admitted model file", maximumBytes: nil) == secureIdentity else {
                throw InferenceFailure.inputIntegrityChanged("Model file changed while sealing.")
            }
        }
        let after = try AudioFileSystem.directoryIdentity(model.directory, label: "Model execution root")
        guard root.device == after.device, root.inode == after.inode, root.mode == after.mode else {
            throw InferenceFailure.inputIntegrityChanged("Model root changed while planning.")
        }
        // A second metadata pass detects a concurrent file replacement during capture.
        for (name, value) in files {
            let current = try AudioFileSystem.regularFile(model.directory.appendingPathComponent(name), label: "Admitted model recheck", maximumBytes: nil)
            guard identityToken(current) == value else {
                throw InferenceFailure.inputIntegrityChanged("Model files changed while planning.")
            }
        }
        struct Payload: Encodable {
            let revision: String?; let backend: BackendDescriptor; let directory: URL
            let device: Int64; let inode: UInt64; let mode: UInt32; let files: [String: String]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(revision: model.revision, backend: backend, directory: model.directory,
            device: root.device, inode: root.inode, mode: root.mode, files: files))
        return Self(token: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), files: files)
    }
    private static func identityToken(_ value: AudioFileSystem.Identity) -> String {
        "\(value.device):\(value.inode):\(value.size):" +
            "\(value.modifiedSeconds):\(value.modifiedNanoseconds):" +
            "\(value.changedSeconds):\(value.changedNanoseconds)"
    }

}
