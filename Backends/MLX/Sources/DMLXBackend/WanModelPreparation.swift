import Darwin
import DInference
import Foundation
import CoreFoundation

/// Offline conversion of the fixed Wan originals. The caller owns publication of
/// the private destination after this method returns successfully.
public struct WanModelPreparationConfiguration: Sendable {
    public let pythonExecutable: URL
    public let providerScript: URL
    public let accessBootstrapRoot: URL?
    public let timeoutSeconds: Double
    public let cancellationGraceSeconds: Double

    public init(pythonExecutable: URL, providerScript: URL, accessBootstrapRoot: URL? = nil,
                timeoutSeconds: Double = 43_200, cancellationGraceSeconds: Double = 30) {
        self.pythonExecutable = pythonExecutable
        self.providerScript = providerScript
        self.accessBootstrapRoot = accessBootstrapRoot
        self.timeoutSeconds = timeoutSeconds
        self.cancellationGraceSeconds = cancellationGraceSeconds
    }
}

public actor WanModelPreparation {
    private let configuration: WanModelPreparationConfiguration
    private var executing = false
    private var drained = true
    private var permit: UUID?
    private var access: AudioProviderAccess?
    private var scopedURLs: [URL] = []

    public init(configuration: WanModelPreparationConfiguration) throws {
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite, configuration.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest("Wan preparation deadlines must be positive and finite.")
        }
        self.configuration = configuration
    }

    public func prepare(source: URL, destination: URL) async throws {
        guard !executing, permit == nil, drained else {
            throw InferenceFailure.backendFailed("Previous Wan preparation has not fully drained.")
        }
        executing = true
        defer { executing = false }
        do {
            try await prepareOwned(source: source, destination: destination)
        } catch {
            let primary = error
            do { try await finishAfterDrain() }
            catch {
                throw InferenceFailure.backendFailed("Wan preparation failed: \(primary.localizedDescription); access cleanup: \(error.localizedDescription)")
            }
            throw primary
        }
        try await finishAfterDrain()
    }

    private func finishAfterDrain() async throws {
        guard drained else { return } // Quarantine keeps access and process-wide permit.
        var cleanupFailure: Error?
        if let access {
            self.access = nil
            do { try access.finish() }
            catch { cleanupFailure = error } // Retain unknown files, but a drained child owns no GPU work.
        }
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        if let permit {
            self.permit = nil
            await MLXExecutionLease.shared.relinquish(permit)
        }
        if let cleanupFailure { throw cleanupFailure }
    }

    private func prepareOwned(source: URL, destination: URL) async throws {
        try Task.checkCancellation()
        let source = try AudioFileSystem.absoluteLocal(source, label: "Wan original source")
        let destination = try AudioFileSystem.absoluteLocal(destination, label: "Wan private destination")
        let parent = destination.deletingLastPathComponent()
        try AudioFileSystem.validateDirectory(source, label: "Wan original source")
        try AudioFileSystem.validateDirectory(parent, label: "Wan destination parent")
        guard !AudioFileSystem.overlaps(source, destination), destination.lastPathComponent != "." else {
            throw InferenceFailure.invalidRequest("Wan originals and prepared output must be separate.")
        }
        var named = stat()
        if Darwin.lstat(destination.path, &named) == 0 {
            throw InferenceFailure.invalidRequest("Wan preparation never overwrites a destination.")
        }
        guard errno == ENOENT else {
            throw InferenceFailure.backendFailed("Cannot inspect Wan preparation destination.")
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.pythonExecutable.path) else {
            throw InferenceFailure.invalidRequest("Wan preparation Python is unavailable.")
        }
        _ = try AudioFileSystem.readRegularFile(configuration.providerScript,
            label: "Wan preparation provider", maximumBytes: 1_048_576)
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        permit = token
        try Task.checkCancellation()
        for url in [source, parent] where url.startAccessingSecurityScopedResource() {
            scopedURLs.append(url)
        }
        // A private task directory holds Python's cache and temporary files. It
        // stays as diagnostic evidence; it is never mistaken for a prepared pack.
        let run = parent.appendingPathComponent(".wan-prepare-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = run.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var arguments = ["-B", configuration.providerScript.path,
                         "--source", source.path, "--destination", destination.path]
        if let root = configuration.accessBootstrapRoot {
            access = try AudioProviderAccess.prepare(root: root, runID: token, directories: [source, parent])
            arguments += ["--access-manifest", access!.manifest.path,
                          "--access-run-id", token.uuidString.lowercased()]
        }
        let environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                           "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
                           "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                           "HF_HOME": run.appendingPathComponent("cache/hf").path,
                           "XDG_CACHE_HOME": run.appendingPathComponent("cache").path,
                           "TMPDIR": temporary.path, "D_TEST_TEMP_DIR": temporary.path,
                           "PYTHONPYCACHEPREFIX": run.appendingPathComponent("pycache").path]
        let terminal = try await ExternalVideoProcess(executable: configuration.pythonExecutable,
            arguments: arguments, environment: environment, currentDirectory: access?.directory ?? run,
            timeoutSeconds: configuration.timeoutSeconds,
            cancellationGraceSeconds: configuration.cancellationGraceSeconds).run()
        drained = terminal.fullyDrained
        guard drained else {
            throw InferenceFailure.resourceCleanupUnconfirmed(
                "Wan preparation child cleanup is unconfirmed; permit retained. PID \(terminal.processID.map(String.init) ?? "unknown"). \(terminal.stderrTail)")
        }
        switch terminal.reason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw InferenceFailure.backendFailed("Wan preparation timed out. \(terminal.stderrTail)")
        case .cleanupUnconfirmed:
            throw InferenceFailure.backendFailed("Wan preparation child contract failed. \(terminal.stderrTail)")
        case .exited: break
        }
        guard terminal.exitCode == 0 else {
            throw InferenceFailure.backendFailed("Wan preparation failed (exit \(terminal.exitCode.map(String.init) ?? "unknown")). \(terminal.stderrTail)")
        }
        try Task.checkCancellation()
        try Self.validatePreparedContract(source: source, destination: destination)
        try Task.checkCancellation()
    }
}

private extension WanModelPreparation {
    static let expectedOriginals: [(role: String, name: String, size: Int64, digest: String)] = [
        ("text", "models_t5_umt5-xxl-enc-bf16.pth", 11_361_920_418, "7cace0da2b446bbbbc57d031ab6cf163a3d59b366da94e5afe36745b746fd81d"),
        ("diffusion", "diffusion_pytorch_model.safetensors", 5_676_070_424, "96b6b242ca1c2f24e9d02cd6596066fab6d310e2d7538f33ae267cb18d957e8f"),
        ("vae", "Wan2.1_VAE.pth", 507_609_880, "38071ab59bd94681c686fa51d75a1968f64e470262043be31f7a094e442fd981")
    ]

    static func invalidMarker() -> InferenceFailure {
        .backendFailed("Wan preparation did not publish a valid prepared contract.")
    }

    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = Int64(number.stringValue), number.stringValue == String(result) else { return nil }
        return result
    }

    static func regularIdentity(_ url: URL, label: String) throws -> AudioFileSystem.Identity {
        try AudioFileSystem.regularFile(url, label: label, maximumBytes: nil)
    }

    static func directoryIdentity(_ url: URL) throws -> AudioFileSystem.Identity {
        try AudioFileSystem.validateDirectory(url, label: "Wan prepared directory")
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw invalidMarker()
        }
        return AudioFileSystem.Identity(value)
    }

    static func preparedDtype(role: String, name: String) -> String {
        let fp32 = role == "vae" || (role == "diffusion" && (
            name.hasPrefix("time_embedding.") || name.hasPrefix("time_projection.") ||
            name.hasPrefix("head.") || name.hasSuffix(".modulation") ||
            name.split(separator: ".").contains { $0.hasPrefix("norm") }))
        return fp32 ? "F32" : "BF16"
    }

    static func validatePreparedContract(source: URL, destination: URL) throws {
        let marker = destination.appendingPathComponent("D-VIDEO-PREPARED.json")
        let (data, markerIdentity) = try AudioFileSystem.readRegularFile(marker,
            label: "Wan completion marker", maximumBytes: 2_097_152)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let complete = object["complete"] as? NSNumber,
              CFGetTypeID(complete) == CFBooleanGetTypeID(), complete.boolValue,
              integer(object["schemaVersion"]) == 1,
              object["repository"] as? String == "Wan-AI/Wan2.1-T2V-1.3B",
              object["revision"] as? String == "37ec512624d61f7aa208f7ea8140a131f93afc9a",
              object["preparation"] as? String == "original-names-tensor-shards-v1",
              let precision = object["precision"] as? [String: String],
              precision == ["text": "BF16", "diffusion": "BF16 with original FP32 time/head/modulation/norm tensors", "vae": "F32"],
              let originals = object["originals"] as? [[String: Any]], originals.count == expectedOriginals.count,
              let rows = object["tensors"] as? [[String: Any]], rows.count == 1_261 else {
            throw invalidMarker()
        }
        var originalIdentities: [(URL, AudioFileSystem.Identity)] = []
        for (index, fixed) in expectedOriginals.enumerated() {
            let row = originals[index]
            guard row["path"] as? String == fixed.name,
                  integer(row["size"]) == fixed.size,
                  row["sha256"] as? String == fixed.digest else { throw invalidMarker() }
            let url = source.appendingPathComponent(fixed.name)
            let identity = try regularIdentity(url, label: "Wan original")
            guard identity.size == fixed.size else { throw invalidMarker() }
            originalIdentities.append((url, identity))
        }
        let rootIdentity = try directoryIdentity(destination)
        var directoryIdentities: [(URL, AudioFileSystem.Identity)] = []
        var counts = ["text": 0, "diffusion": 0, "vae": 0]
        var names = Set<String>()
        var files: [(URL, AudioFileSystem.Identity)] = []
        for row in rows {
            try Task.checkCancellation()
            guard let role = row["role"] as? String, let count = counts[role],
                  let name = row["name"] as? String, !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ (48...57).contains($0.value) ||
                      (65...90).contains($0.value) || (97...122).contains($0.value) ||
                      $0.value == 95 || $0.value == 46 }),
                  names.insert(role + ":" + name).inserted,
                  let relative = row["path"] as? String,
                  relative == String(format: "%@/%04d.safetensors", role, count),
                  row["dtype"] as? String == preparedDtype(role: role, name: name),
                  let shape = row["shape"] as? [Any], (1...5).contains(shape.count),
                  shape.allSatisfy({ (integer($0) ?? 0) > 0 }),
                  let size = integer(row["size"]), size > 0,
                  let digest = row["sha256"] as? String, digest.count == 64,
                  digest.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) else {
                throw invalidMarker()
            }
            let url = destination.appendingPathComponent(relative)
            let identity = try regularIdentity(url, label: "Wan prepared tensor")
            guard identity.size == size else { throw invalidMarker() }
            files.append((url, identity))
            counts[role] = count + 1
        }
        guard counts == ["text": 242, "diffusion": 825, "vae": 194],
              Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)) ==
                Set(["text", "diffusion", "vae", "D-VIDEO-PREPARED.json"]) else { throw invalidMarker() }
        for (role, count) in counts {
            let directory = destination.appendingPathComponent(role)
            let identity = try directoryIdentity(directory)
            let expected = Set((0..<count).map { String(format: "%04d.safetensors", $0) })
            guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == expected else {
                throw invalidMarker()
            }
            directoryIdentities.append((directory, identity))
        }
        guard try regularIdentity(marker, label: "Wan completion marker") == markerIdentity,
              directoryIdentity(destination) == rootIdentity else { throw invalidMarker() }
        for (url, identity) in originalIdentities + files {
            guard try regularIdentity(url, label: "Wan prepared contract resource") == identity else {
                throw invalidMarker()
            }
        }
        for (url, identity) in directoryIdentities {
            guard try directoryIdentity(url) == identity else { throw invalidMarker() }
        }
    }
}
