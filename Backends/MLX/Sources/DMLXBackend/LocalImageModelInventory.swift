import CryptoKit
import Darwin
import DInference
import Foundation

/// Admission reads metadata and file identities, never MLX weights or network data.
/// Full verification is a separate, cancellable step before any model initialization.
/// The host must keep an installation immutable after verification and while it is in use.
struct LocalImageModelInventory: Sendable {
    static let repository = "mzbac/FLUX.2-klein-4B-q8"
    static let revision = "ef52ee019fd1d0e75ae4deb40476ba65989716d7"

    let directory: URL
    // B1 measured the phased workload; this includes headroom and remains an estimate.
    let estimatedPeakBytes: UInt64 = 8 * 1024 * 1024 * 1024
    let weightBytes: UInt64
    private let manifest: Manifest
    private let identities: [String: FileIdentity]

    /// Internal injection permits small offline fixtures. Production uses only bundled().
    struct Manifest: Decodable, Sendable {
        struct File: Decodable, Sendable {
            let path: String
            let size: UInt64
            let sha256: String
        }

        let schemaVersion: Int
        let repository: String
        let revision: String
        let files: [File]

        static func bundled() throws -> Self {
            guard let url = Bundle.module.url(forResource: "flux2-klein-model", withExtension: "json") else {
                throw InferenceFailure.backendFailed("The bundled FLUX.2 model manifest is missing.")
            }
            do {
                return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            } catch {
                throw InferenceFailure.backendFailed("Cannot decode the bundled FLUX.2 model manifest: \(error.localizedDescription)")
            }
        }

        fileprivate func validate() throws {
            guard schemaVersion == 1,
                  repository == LocalImageModelInventory.repository,
                  revision == LocalImageModelInventory.revision,
                  files.count == LocalImageModelInventory.requiredPaths.count,
                  Set(files.map(\.path)) == LocalImageModelInventory.requiredPaths else {
                throw InferenceFailure.invalidRequest("The image manifest must describe the complete pinned FLUX.2 Klein installation.")
            }
            for file in files {
                guard file.size > 0, file.size <= 16 * 1024 * 1024 * 1024,
                      file.sha256.utf8.count == 64,
                      file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw InferenceFailure.invalidRequest("Invalid image manifest size or SHA-256: \(file.path)")
                }
            }
        }
    }

    private static let requiredPaths: Set<String> = [
        "model_index.json", "quantization.json", "scheduler/scheduler_config.json",
        "text_encoder/config.json", "text_encoder/generation_config.json",
        "text_encoder/model-00001-of-00002.safetensors", "text_encoder/model-00002-of-00002.safetensors",
        "tokenizer/added_tokens.json", "tokenizer/chat_template.jinja", "tokenizer/merges.txt",
        "tokenizer/special_tokens_map.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json",
        "tokenizer/vocab.json", "transformer/config.json", "transformer/diffusion_pytorch_model.safetensors",
        "vae/config.json", "vae/diffusion_pytorch_model.safetensors",
    ]

    static func inspect(_ request: InferenceRequest) throws -> Self {
        try inspect(request, manifest: Manifest.bundled())
    }

    static func inspect(_ request: InferenceRequest, manifest: Manifest) throws -> Self {
        try Task.checkCancellation()
        try request.validate()
        guard case .image(let image) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        guard image.width == 512, image.height == 512, image.steps == 4, image.guidanceScale == 1 else {
            throw InferenceFailure.invalidRequest("This image backend supports only 512 x 512, 4 steps, guidance 1.")
        }
        guard image.prompt.utf8.count <= 1_048_576,
              !image.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferenceFailure.invalidRequest("Image prompt must be nonempty and no larger than 1 MiB of UTF-8.")
        }
        guard request.model.revision == nil || request.model.revision == revision else {
            throw InferenceFailure.invalidRequest("Unsupported image model revision; use the pinned FLUX.2 Klein snapshot.")
        }
        guard request.model.directory.host == nil || request.model.directory.host == ""
                || request.model.directory.host == "localhost" else {
            throw InferenceFailure.invalidRequest("Image model directory must be a local file URL.")
        }
        try manifest.validate()
        let directory = request.model.directory.standardizedFileURL
        let identities = try withRoot(directory) { root in
            let initial = try snapshot(root: root, manifest: manifest)
            for file in manifest.files where !file.path.hasSuffix(".safetensors") {
                try verify(file, root: root, identities: initial)
            }
            guard try snapshot(root: root, manifest: manifest) == initial else {
                throw InferenceFailure.invalidRequest("Image model installation changed while inspecting metadata.")
            }
            return initial
        }
        // Reopen the absolute location as well, so replacing the root during inspection
        // cannot make an open descriptor silently validate the former installation.
        try withRoot(directory) { root in
            guard try snapshot(root: root, manifest: manifest) == identities else {
                throw InferenceFailure.invalidRequest("Image model location changed during inspection.")
            }
        }
        let weightBytes = manifest.files.filter { $0.path.hasSuffix(".safetensors") }.reduce(UInt64(0)) { $0 + $1.size }
        return Self(directory: directory, weightBytes: weightBytes, manifest: manifest, identities: identities)
    }

    /// Rehash every manifest file, including all four weight files, using bounded memory.
    /// Saved stat identities reject replacements or edits since admission; fstat before
    /// and after each read plus a final tree check also detect changes during verification.
    func verifyContents() throws {
        try Task.checkCancellation()
        try Self.withRoot(directory) { root in
            guard try Self.snapshot(root: root, manifest: manifest) == identities else {
                throw InferenceFailure.invalidRequest("Image model installation changed after admission.")
            }
            for file in manifest.files {
                try Self.verify(file, root: root, identities: identities)
            }
            guard try Self.snapshot(root: root, manifest: manifest) == identities else {
                throw InferenceFailure.invalidRequest("Image model installation changed during SHA-256 verification.")
            }
        }
        try Self.withRoot(directory) { root in
            guard try Self.snapshot(root: root, manifest: manifest) == identities else {
                throw InferenceFailure.invalidRequest("Image model location changed during SHA-256 verification.")
            }
        }
        try Task.checkCancellation()
    }

    private struct FileIdentity: Sendable, Equatable {
        let device: Int64
        let inode: UInt64
        let mode: UInt32
        let links: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ value: stat) {
            device = Int64(value.st_dev)
            inode = UInt64(value.st_ino)
            mode = UInt32(value.st_mode)
            links = UInt64(value.st_nlink)
            size = Int64(value.st_size)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK

    /// Open each path component relative to its parent; O_NOFOLLOW on the final
    /// component alone would still follow symbolic links in ancestor directories.
    private static func withRoot<T>(_ directory: URL, body: (Int32) throws -> T) throws -> T {
        var descriptor = Darwin.open("/", directoryFlags)
        guard descriptor >= 0 else { throw fileError("Cannot open filesystem root") }
        defer { Darwin.close(descriptor) }
        for component in directory.pathComponents where component != "/" {
            try Task.checkCancellation()
            let next = Darwin.openat(descriptor, component, directoryFlags)
            guard next >= 0 else { throw fileError("Cannot open image directory component \(component); symbolic links are not allowed") }
            Darwin.close(descriptor)
            descriptor = next
        }
        return try body(descriptor)
    }

    private static func identity(of descriptor: Int32) throws -> FileIdentity {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { throw fileError("Cannot inspect opened model entry") }
        return FileIdentity(value)
    }

    /// Strict installation policy: only manifest files and their parent directories.
    /// Download state, extra config/weights, symlinks, devices, sockets and FIFOs fail.
    private static func snapshot(root: Int32, manifest: Manifest) throws -> [String: FileIdentity] {
        let files = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        let directories = Set(manifest.files.flatMap { file -> [String] in
            let parts = file.path.split(separator: "/")
            return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        })
        var found: [String: FileIdentity] = ["": try identity(of: root)]

        func walk(_ descriptor: Int32, prefix: String) throws {
            // A dup shares the directory offset and would make a later snapshot
            // start at EOF. Opening "." creates an independent enumeration cursor.
            let duplicate = Darwin.openat(descriptor, ".", directoryFlags)
            guard duplicate >= 0 else { throw fileError("Cannot open model directory enumeration cursor") }
            guard let listing = fdopendir(duplicate) else {
                Darwin.close(duplicate)
                throw fileError("Cannot enumerate image model directory")
            }
            defer { closedir(listing) }
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = readdir(listing) else {
                    if errno != 0 { throw fileError("Cannot finish enumerating image model directory") }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                var value = stat()
                guard Darwin.fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw fileError("Cannot inspect image model entry \(path)")
                }
                let record = FileIdentity(value)
                switch value.st_mode & S_IFMT {
                case S_IFREG:
                    guard let file = files[path], value.st_size >= 0, UInt64(value.st_size) == file.size else {
                        throw InferenceFailure.invalidRequest("Unlisted image file or incorrect file size: \(path)")
                    }
                case S_IFDIR:
                    guard directories.contains(path) else {
                        throw InferenceFailure.invalidRequest("Unlisted image model directory or incomplete download state: \(path)")
                    }
                    let child = Darwin.openat(descriptor, name, directoryFlags)
                    guard child >= 0 else { throw fileError("Cannot open image model subdirectory \(path)") }
                    defer { Darwin.close(child) }
                    guard try identity(of: child) == record else {
                        throw InferenceFailure.invalidRequest("Image model directory changed while opening: \(path)")
                    }
                    try walk(child, prefix: path)
                default:
                    throw InferenceFailure.invalidRequest("Image model entries must be regular files/directories, without symbolic links: \(path)")
                }
                found[path] = record
            }
        }
        try walk(root, prefix: "")
        guard Set(found.keys) == Set(files.keys).union(directories).union([""]) else {
            throw InferenceFailure.invalidRequest("The image model installation is missing manifest files or directories.")
        }
        return found
    }

    private static func verify(_ file: Manifest.File, root: Int32, identities: [String: FileIdentity]) throws {
        try Task.checkCancellation()
        var parent = Darwin.dup(root)
        guard parent >= 0 else { throw fileError("Cannot duplicate image model descriptor") }
        defer { Darwin.close(parent) }
        let components = file.path.split(separator: "/").map(String.init)
        var prefix = ""
        for component in components.dropLast() {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            let next = Darwin.openat(parent, component, directoryFlags)
            guard next >= 0 else { throw fileError("Cannot open image model parent \(prefix)") }
            Darwin.close(parent)
            parent = next
            guard try identity(of: parent) == identities[prefix] else {
                throw InferenceFailure.invalidRequest("Image model parent changed before reading: \(prefix)")
            }
        }
        let descriptor = Darwin.openat(parent, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileError("Cannot open image model file \(file.path)") }
        defer { Darwin.close(descriptor) }
        let before = try identity(of: descriptor)
        guard before.mode & UInt32(S_IFMT) == UInt32(S_IFREG), before == identities[file.path] else {
            throw InferenceFailure.invalidRequest("Image model file changed before SHA-256 verification: \(file.path)")
        }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var total: UInt64 = 0
        while total < file.size {
            try Task.checkCancellation()
            let length = Int(min(UInt64(buffer.count), file.size - total))
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, length)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw fileError("Cannot read image model file \(file.path)")
            }
            guard count > 0 else {
                throw InferenceFailure.invalidRequest("Image model file was truncated during verification: \(file.path)")
            }
            digest.update(data: Data(buffer.prefix(count)))
            total += UInt64(count)
        }
        try Task.checkCancellation()
        var extra: UInt8 = 0
        var trailing: Int
        repeat {
            try Task.checkCancellation()
            trailing = Darwin.read(descriptor, &extra, 1)
        } while trailing < 0 && errno == EINTR
        guard trailing == 0, try identity(of: descriptor) == before else {
            throw InferenceFailure.invalidRequest("Image model file changed during SHA-256 verification: \(file.path)")
        }
        let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == file.sha256 else {
            throw InferenceFailure.invalidRequest("Image model SHA-256 mismatch: \(file.path)")
        }
    }

    private static func fileError(_ description: String) -> InferenceFailure {
        .invalidRequest("\(description): \(String(cString: strerror(errno)))")
    }
}
