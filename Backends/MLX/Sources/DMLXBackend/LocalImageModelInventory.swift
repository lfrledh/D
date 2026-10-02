import CryptoKit
import Darwin
import DInference
import Foundation
import Flux2
import MLX

/// Admission reads metadata and file identities, never MLX weights or network data.
/// Full verification is a separate, cancellable step before any model initialization.
/// The host must keep an installation immutable after verification and while it is in use.
struct LocalImageModelInventory: Sendable {
    static let repository = "mzbac/FLUX.2-klein-4B-q8"
    static let revision = "ef52ee019fd1d0e75ae4deb40476ba65989716d7"

    static let fullRepository = "black-forest-labs/FLUX.2-klein-4B"
    static let fullRevision = "e7b7dc27f91deacad38e78976d1f2b499d76a294"
    var modelRepository: String { manifest.repository }
    var modelRevision: String { manifest.revision }
    let directory: URL
    let estimatedPeakBytes: UInt64
    let weightBytes: UInt64
    let executionProfile: ExecutionProfileReference
    var fileSet: Flux2FileSet { get throws { try Flux2FileSet(paths: Set(manifest.files.map(\.path))) } }
    private let manifest: Manifest
    private let identities: [String: FileIdentity]

    /// Internal injection permits small offline fixtures. Production uses only bundled().
    struct Manifest: Decodable, Sendable {
        struct File: Decodable, Sendable {
            let path: String
            let size: UInt64
            let sha256: String
            let algorithm: String?
            init(path: String, size: UInt64, sha256: String, algorithm: String? = nil) {
                self.path = path; self.size = size; self.sha256 = sha256; self.algorithm = algorithm
            }
        }

        let schemaVersion: Int
        let repository: String
        let revision: String
        let files: [File]

        static func bundled(revision: String? = nil) throws -> Self {
            guard revision == nil || revision == LocalImageModelInventory.revision || revision == LocalImageModelInventory.fullRevision else {
                throw InferenceFailure.invalidRequest("Unsupported image model revision.")
            }
            let resource = revision == LocalImageModelInventory.fullRevision ? "flux2-klein-bf16-model" : "flux2-klein-model"
            guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
                throw InferenceFailure.backendFailed("The bundled FLUX.2 model manifest is missing.")
            }
            do {
                return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            } catch {
                throw InferenceFailure.backendFailed("Cannot decode the bundled FLUX.2 model manifest: \(error.localizedDescription)")
            }
        }

        fileprivate func validate() throws {
            let full = repository == LocalImageModelInventory.fullRepository && revision == LocalImageModelInventory.fullRevision
            let required = full ? LocalImageModelInventory.fullRequiredPaths : LocalImageModelInventory.requiredPaths
            guard schemaVersion == 1,
                  full || (repository == LocalImageModelInventory.repository && revision == LocalImageModelInventory.revision),
                  files.count == required.count, Set(files.map(\.path)) == required else {
                throw InferenceFailure.invalidRequest("The image manifest must describe the complete pinned FLUX.2 Klein installation.")
            }
            for file in files {
                guard file.size > 0, file.size <= 16 * 1024 * 1024 * 1024,
                      [nil, "sha256", "git-blob-sha1"].contains(file.algorithm),
                      file.sha256.utf8.count == (file.algorithm == "git-blob-sha1" ? 40 : 64),
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

    private static var fullRequiredPaths: Set<String> {
        requiredPaths.subtracting(["quantization.json"]).union(["text_encoder/model.safetensors.index.json"])
    }

    static func inspect(_ request: InferenceRequest,
                        profile: ImageExecutionProfile = .verified512) throws -> Self {
        try requireKleinProfile(profile)
        return try inspect(request, manifest: Manifest.bundled(revision: request.model.revision), profile: profile)
    }

    static func inspect(_ request: InferenceRequest, manifest: Manifest,
                        profile: ImageExecutionProfile = .verified512) throws -> Self {
        try requireKleinProfile(profile)
        try Task.checkCancellation()
        try request.validate()
        guard case .image(let image) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        let resolvedCapability = try profile.resolvedCapability(for: image)
        let estimatedPeakBytes = try resolvedCapability.estimatedPeakBytes(for: image)
        guard image.loadingStrategy != .ssdLayered || manifest.revision == fullRevision else {
            throw InferenceFailure.invalidRequest("SSD layered image loading requires the original pinned Klein BF16 installation.")
        }
        guard image.prompt.utf8.count <= 1_048_576,
              !image.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferenceFailure.invalidRequest("Image prompt must be nonempty and no larger than 1 MiB of UTF-8.")
        }
        guard request.model.revision == nil || request.model.revision == manifest.revision else {
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
        let weightBytes = try manifest.files.filter { $0.path.hasSuffix(".safetensors") }.reduce(UInt64(0)) { total, file in
            let (next, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow else { throw InferenceFailure.invalidRequest("Image weight size exceeds UInt64 capacity.") }
            return next
        }
        let peak: UInt64
        if image.loadingStrategy == .ssdLayered {
            let stage = try layeredStageWeightBytes(directory: directory, manifest: manifest,
                                                    identities: identities)
            peak = try layeredPeak(stageBytes: stage.bytes, transformerWidth: stage.transformerWidth,
                                   textWidth: stage.textWidth, image: image,
                                   textTokens: resolvedCapability.maximumTextTokens)
        } else if manifest.revision == fullRevision {
            let (resident, overflow) = weightBytes.addingReportingOverflow(8 * 1024 * 1024 * 1024)
            guard !overflow else { throw InferenceFailure.invalidRequest("Image estimate exceeds UInt64 capacity.") }
            peak = max(estimatedPeakBytes, resident)
        } else {
            peak = estimatedPeakBytes
        }
        return Self(directory: directory, estimatedPeakBytes: peak,
                    weightBytes: weightBytes, executionProfile: resolvedCapability.profile,
                    manifest: manifest, identities: identities)
    }

    /// Safetensors headers provide exact stored BF16 tensor bytes without loading arrays.
    /// A stage retains its shared weights and at most one decoder/transformer block.
    private static func layeredStageWeightBytes(directory: URL, manifest: Manifest,
                                                identities: [String: FileIdentity]) throws ->
        (bytes: UInt64, transformerWidth: UInt64, textWidth: UInt64) {
        guard manifest.revision == fullRevision else {
            throw InferenceFailure.invalidRequest("Layered Klein loading requires original BF16 weights.")
        }
        var textBase: UInt64 = 0
        var transformerBase: UInt64 = 0
        var vae: UInt64 = 0
        var vaeBF16Count = 0
        var vaeScalarCount = 0
        var textBlocks: [Int: UInt64] = [:]
        var doubleBlocks: [Int: UInt64] = [:]
        var singleBlocks: [Int: UInt64] = [:]
        func add(_ value: UInt64, to total: inout UInt64) throws {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw InferenceFailure.invalidRequest("Image tensor sizes exceed UInt64 capacity.") }
            total = sum
        }
        func blockIndex(_ name: String, prefix: String) -> Int? {
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count).split(separator: ".", maxSplits: 1).first ?? "")
        }
        for file in manifest.files where file.path.hasSuffix(".safetensors") {
            try Task.checkCancellation()
            // The header is read before the full digest. Match the admitted file
            // identity around each bounded parse, including path replacement.
            try withRoot(directory) { root in
                guard try snapshot(root: root, manifest: manifest) == identities else {
                    throw InferenceFailure.invalidRequest("Image model changed before layered header inspection.")
                }
            }
            let reader: SafeTensorsReader
            do { reader = try SafeTensorsReader(fileURL: directory.appendingPathComponent(file.path)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw InferenceFailure.invalidRequest("Invalid layered safetensors header: \(file.path): \(error)") }
            let metadata = reader.allMetadata()
            let firstDataOffset = metadata.map(\.dataOffset).min() ?? 0
            for tensor in metadata {
                guard validLayeredTensor(tensor, component: file.path,
                                         firstDataOffset: firstDataOffset) else {
                    throw InferenceFailure.invalidRequest("Layered Klein requires original BF16 tensors: \(file.path)/\(tensor.name)")
                }
                let bytes = UInt64(tensor.byteCount)
                if file.path.hasPrefix("text_encoder/") {
                    if let index = blockIndex(tensor.name, prefix: "model.layers.") {
                        var current = textBlocks[index, default: 0]
                        try add(bytes, to: &current)
                        textBlocks[index] = current
                    } else { try add(bytes, to: &textBase) }
                } else if file.path.hasPrefix("transformer/") {
                    if let index = blockIndex(tensor.name, prefix: "transformer_blocks.") {
                        var current = doubleBlocks[index, default: 0]
                        try add(bytes, to: &current)
                        doubleBlocks[index] = current
                    } else if let index = blockIndex(tensor.name, prefix: "single_transformer_blocks.") {
                        var current = singleBlocks[index, default: 0]
                        try add(bytes, to: &current)
                        singleBlocks[index] = current
                    } else { try add(bytes, to: &transformerBase) }
                } else if file.path.hasPrefix("vae/") {
                    if tensor.dtype == .bfloat16 { vaeBF16Count += 1 }
                    else { vaeScalarCount += 1 }
                    try add(bytes, to: &vae)
                }
            }
            try withRoot(directory) { root in
                guard try snapshot(root: root, manifest: manifest) == identities else {
                    throw InferenceFailure.invalidRequest("Image model changed during layered header inspection.")
                }
            }
        }
        let textConfig = try JSONDecoder().decode(Flux2Qwen3Configuration.self,
            from: Data(contentsOf: directory.appendingPathComponent("text_encoder/config.json")))
        let transformerConfig = try JSONDecoder().decode(Flux2TransformerConfiguration.self,
            from: Data(contentsOf: directory.appendingPathComponent("transformer/config.json")))
        try withRoot(directory) { root in
            guard try snapshot(root: root, manifest: manifest) == identities else {
                throw InferenceFailure.invalidRequest("Image model changed during layered config inspection.")
            }
        }
        let (transformerWidth, widthOverflow) = transformerConfig.numAttentionHeads
            .multipliedReportingOverflow(by: transformerConfig.attentionHeadDim)
        guard textConfig.hiddenLayers > 0, transformerConfig.numLayers > 0,
              transformerConfig.numSingleLayers > 0,
              textConfig.hiddenSize > 0, transformerConfig.numAttentionHeads > 0,
              transformerConfig.attentionHeadDim > 0, !widthOverflow, transformerWidth > 0,
              Set(textBlocks.keys) == Set(0..<textConfig.hiddenLayers),
              Set(doubleBlocks.keys) == Set(0..<transformerConfig.numLayers),
              Set(singleBlocks.keys) == Set(0..<transformerConfig.numSingleLayers),
              textBase > 0, transformerBase > 0, vae > 0,
              vaeBF16Count == 250, vaeScalarCount == 1 else {
            throw InferenceFailure.invalidRequest("Layered Klein weights do not cover every original block.")
        }
        guard let textMaximum = textBlocks.values.max(), let doubleMaximum = doubleBlocks.values.max(),
              let singleMaximum = singleBlocks.values.max() else {
            throw InferenceFailure.invalidRequest("Layered Klein block inventory is empty.")
        }
        let (textStage, textOverflow) = textBase.addingReportingOverflow(textMaximum)
        let (doubleStage, doubleOverflow) = transformerBase.addingReportingOverflow(doubleMaximum)
        let (singleStage, singleOverflow) = transformerBase.addingReportingOverflow(singleMaximum)
        guard !textOverflow, !doubleOverflow, !singleOverflow else {
            throw InferenceFailure.invalidRequest("Layered image stage size exceeds UInt64 capacity.")
        }
        return (max(textStage, doubleStage, singleStage, vae),
                UInt64(transformerWidth), UInt64(textConfig.hiddenSize))
    }

    static func validLayeredTensor(_ tensor: SafeTensorMetadata, component: String,
                                   firstDataOffset: Int) -> Bool {
        if tensor.dtype == .bfloat16 { return tensor.byteCount > 0 }
        // The pinned original VAE has one non-floating BatchNorm counter. It is
        // an 8-byte scalar and must remain I64; no general dtype conversion.
        return component == "vae/diffusion_pytorch_model.safetensors" &&
            tensor.name == "bn.num_batches_tracked" && tensor.dtype == .int64 &&
            tensor.shape.isEmpty && tensor.byteCount == 8 &&
            tensor.dataOffset == firstDataOffset
    }

    private static func layeredPeak(stageBytes: UInt64, transformerWidth: UInt64,
                                    textWidth: UInt64, image: ImageRequest,
                                    textTokens: Int) throws -> UInt64 {
        func product(_ values: UInt64...) throws -> UInt64 {
            var result: UInt64 = 1
            for value in values {
                let (next, overflow) = result.multipliedReportingOverflow(by: value)
                guard !overflow else { throw InferenceFailure.invalidRequest("Layered workspace exceeds UInt64 capacity.") }
                result = next
            }
            return result
        }
        func sum(_ values: UInt64...) throws -> UInt64 {
            var result: UInt64 = 0
            for value in values {
                let (next, overflow) = result.addingReportingOverflow(value)
                guard !overflow else { throw InferenceFailure.invalidRequest("Layered workspace exceeds UInt64 capacity.") }
                result = next
            }
            return result
        }
        func tokens(width: Int, height: Int) throws -> UInt64 {
            // VAE downsamples by 8; 2x2 packing yields one token per 16x16 pixels.
            try product(UInt64(width / 16), UInt64(height / 16))
        }
        var referenceTokens: UInt64 = 0
        var referencePixels: UInt64 = 0
        for reference in try image.resolvedReferences() {
            try Task.checkCancellation()
            referenceTokens = try sum(referenceTokens, tokens(width: reference.width, height: reference.height))
            referencePixels = try sum(referencePixels, try product(UInt64(reference.width), UInt64(reference.height)))
        }
        let outputTokens = try tokens(width: image.width, height: image.height)
        let spatialTokens = try sum(outputTokens, referenceTokens)
        let allTokens = try sum(spatialTokens, UInt64(textTokens))
        let outputPixels = try product(UInt64(image.width), UInt64(image.height))
        // One loaded BF16 block may coexist with its source/read buffer and MLX
        // evaluated buffers. Workspace covers Q/K/V, MLP and residual intermediates
        // at 64 bytes per token/channel, a materialized attention matrix at 16
        // bytes per token pair, text states/cache, and VAE/ref image intermediates
        // at 64 bytes per pixel. These are conservative admission assumptions.
        let weightCopies = try product(stageBytes, 2)
        let activations = try product(allTokens, transformerWidth, 64)
        let attention = try product(allTokens, allTokens, 16)
        let textCache = try product(UInt64(textTokens), textWidth, 64)
        let imageCache = try product(try sum(outputPixels, referencePixels), 64)
        return try sum(weightCopies, activations, attention, textCache, imageCache)
    }

    private static func requireKleinProfile(_ profile: ImageExecutionProfile) throws {
        guard profile != .flux2Dev else {
            throw InferenceFailure.invalidRequest("The FLUX.2 Dev profile is incompatible with the Klein image inventory.")
        }
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
        let components = directory.pathComponents.filter { $0 != "/" }
        // The application grants access to the model, not enumeration of every
        // directory leading to it. Only the selected root needs a readable cursor.
        let traversalFlags = O_SEARCH | O_NOFOLLOW | O_CLOEXEC
        var descriptor = Darwin.open("/", components.isEmpty ? directoryFlags : traversalFlags)
        guard descriptor >= 0 else { throw fileError("Cannot open filesystem root") }
        defer { Darwin.close(descriptor) }
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            let next = Darwin.openat(descriptor, component,
                                    index == components.count - 1 ? directoryFlags : traversalFlags)
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
        var gitDigest = Insecure.SHA1()
        gitDigest.update(data: Data("blob \(file.size)\0".utf8))
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
            let chunk = Data(buffer.prefix(count))
            if file.algorithm == "git-blob-sha1" { gitDigest.update(data: chunk) } else { digest.update(data: chunk) }
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
        let checksum = file.algorithm == "git-blob-sha1"
            ? gitDigest.finalize().map { String(format: "%02x", $0) }.joined()
            : digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == file.sha256 else {
            throw InferenceFailure.invalidRequest("Image model SHA-256 mismatch: \(file.path)")
        }
    }

    private static func fileError(_ description: String) -> InferenceFailure {
        .invalidRequest("\(description): \(String(cString: strerror(errno)))")
    }
}
