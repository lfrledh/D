import Darwin
import DInference
import Foundation

public enum AudioBackendProfile: String, CaseIterable, Codable, Sendable {
    case smMusic = "sm-music"
    case smSFX = "sm-sfx"
    case medium
}

/// Explicit host-owned launch configuration. Constructing this value performs no I/O and
/// does not imply that model terms have been accepted.
public struct AudioBackendConfiguration: Sendable {
    public let pythonExecutable: URL
    public let providerScript: URL
    public let vendorDirectory: URL
    public let modelManifest: URL
    public let artifactDirectory: URL
    public let profile: AudioBackendProfile
    public let licenseAcknowledged: Bool
    public let timeoutSeconds: Double
    public let cancellationGraceSeconds: Double

    public init(
        pythonExecutable: URL,
        providerScript: URL,
        vendorDirectory: URL,
        modelManifest: URL,
        artifactDirectory: URL,
        profile: AudioBackendProfile,
        licenseAcknowledged: Bool = false,
        timeoutSeconds: Double = 600,
        cancellationGraceSeconds: Double = 15
    ) {
        self.pythonExecutable = pythonExecutable
        self.providerScript = providerScript
        self.vendorDirectory = vendorDirectory
        self.modelManifest = modelManifest
        self.artifactDirectory = artifactDirectory
        self.profile = profile
        self.licenseAcknowledged = licenseAcknowledged
        self.timeoutSeconds = timeoutSeconds
        self.cancellationGraceSeconds = cancellationGraceSeconds
    }
}

struct ValidatedAudioConfiguration: Sendable {
    let pythonExecutable: URL
    let providerScript: URL
    let vendorDirectory: URL
    let modelManifest: URL
    let artifactDirectory: URL
    let profile: AudioBackendProfile
    let licenseAcknowledged: Bool
    let timeoutSeconds: Double
    let cancellationGraceSeconds: Double
}

enum AudioFileSystem {
    struct Identity: Sendable, Equatable {
        let device: Int64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ value: stat) {
            device = Int64(value.st_dev)
            inode = UInt64(value.st_ino)
            mode = UInt32(value.st_mode)
            size = Int64(value.st_size)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }

    static func validate(_ configuration: AudioBackendConfiguration, modelDirectory: URL,
                         source: URL?) throws -> ValidatedAudioConfiguration {
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite,
              configuration.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest("Audio timeout and cancellation grace must be finite and positive.")
        }

        // The Python executable is the sole path for which a trusted host may supply a
        // system symlink. Resolve it first, then apply the same no-symlink walk.
        let suppliedPython = try absoluteLocal(configuration.pythonExecutable, label: "Python executable")
        let python = suppliedPython.resolvingSymlinksInPath().standardizedFileURL
        _ = try regularFile(python, label: "Python executable", maximumBytes: nil)
        guard Darwin.access(python.path, X_OK) == 0 else {
            throw invalidFile("Python executable is not executable")
        }

        let provider = try absoluteLocal(configuration.providerScript, label: "Audio provider script")
        _ = try regularFile(provider, label: "Audio provider script", maximumBytes: 16 * 1024 * 1024)
        let vendor = try absoluteLocal(configuration.vendorDirectory, label: "Audio vendor directory")
        try validateDirectory(vendor, label: "Audio vendor directory")
        let manifest = try absoluteLocal(configuration.modelManifest, label: "Audio model manifest")
        _ = try regularFile(manifest, label: "Audio model manifest", maximumBytes: 1_048_576)
        let artifacts = try absoluteLocal(configuration.artifactDirectory, label: "Audio artifact directory")
        try validateDirectory(artifacts, label: "Audio artifact directory")
        let model = try absoluteLocal(modelDirectory, label: "Audio model directory")
        try validateDirectory(model, label: "Audio model directory")

        var protectedInputs = [model, vendor, provider, manifest]
        if let source {
            let source = try absoluteLocal(source, label: "Audio source")
            _ = try regularFile(source, label: "Audio source", maximumBytes: 512 * 1024 * 1024)
            protectedInputs.append(source)
            guard !overlaps(source, model), !overlaps(source, vendor) else {
                throw InferenceFailure.invalidRequest("Audio source must be outside model and vendor directories.")
            }
        }
        guard protectedInputs.allSatisfy({ !overlaps(artifacts, $0) }) else {
            throw InferenceFailure.invalidRequest(
                "Audio artifact directory must be separate from model, vendor, manifest, provider, and source paths.")
        }

        return ValidatedAudioConfiguration(
            pythonExecutable: python, providerScript: provider, vendorDirectory: vendor,
            modelManifest: manifest, artifactDirectory: artifacts, profile: configuration.profile,
            licenseAcknowledged: configuration.licenseAcknowledged,
            timeoutSeconds: configuration.timeoutSeconds,
            cancellationGraceSeconds: configuration.cancellationGraceSeconds)
    }

    static func absoluteLocal(_ url: URL, label: String) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              url.host == nil || url.host == "" || url.host == "localhost" else {
            throw InferenceFailure.invalidRequest("\(label) must be an absolute local path.")
        }
        return url.standardizedFileURL
    }

    static func validateDirectory(_ url: URL, label: String) throws {
        let descriptor = try openDirectory(url, label: label)
        Darwin.close(descriptor)
    }

    static func openDirectory(_ url: URL, label: String) throws -> Int32 {
        let path = try absoluteLocal(url, label: label).path
        let components = path.split(separator: "/").map(String.init)
        let traversalFlags = O_SEARCH | O_NOFOLLOW | O_CLOEXEC
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var descriptor = Darwin.open("/", components.isEmpty ? directoryFlags : traversalFlags)
        guard descriptor >= 0 else { throw invalidFile("Cannot open filesystem root for \(label)") }
        for (index, component) in components.enumerated() {
            let next = Darwin.openat(descriptor, component,
                                     index == components.count - 1 ? directoryFlags : traversalFlags)
            Darwin.close(descriptor)
            guard next >= 0 else {
                throw invalidFile("Cannot open \(label) component \(component); symbolic links are not allowed")
            }
            descriptor = next
        }
        return descriptor
    }

    static func regularFile(_ url: URL, label: String, maximumBytes: UInt64?) throws -> Identity {
        let (descriptor, identity) = try openRegularFile(url, label: label)
        defer { Darwin.close(descriptor) }
        if let maximumBytes {
            guard identity.size >= 0, UInt64(identity.size) <= maximumBytes else {
                throw InferenceFailure.invalidRequest("\(label) exceeds its bounded size.")
            }
        }
        return identity
    }

    static func readRegularFile(_ url: URL, label: String, maximumBytes: UInt64) throws -> (Data, Identity) {
        let (descriptor, before) = try openRegularFile(url, label: label)
        defer { Darwin.close(descriptor) }
        guard before.size >= 0, UInt64(before.size) <= maximumBytes else {
            throw InferenceFailure.invalidRequest("\(label) exceeds its bounded size.")
        }
        var data = Data()
        data.reserveCapacity(Int(before.size))
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while data.count < Int(before.size) {
            try Task.checkCancellation()
            let requested = min(buffer.count, Int(before.size) - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, requested) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw invalidFile("Cannot read complete \(label)") }
            data.append(contentsOf: buffer.prefix(count))
        }
        var extra: UInt8 = 0
        var trailing: Int
        repeat { trailing = Darwin.read(descriptor, &extra, 1) } while trailing < 0 && errno == EINTR
        guard trailing == 0 else { throw InferenceFailure.invalidRequest("\(label) grew while being read.") }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0, Identity(value) == before else {
            throw InferenceFailure.invalidRequest("\(label) changed while being read.")
        }
        return (data, before)
    }

    static func writeExclusive(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw backendFile("Cannot create \(url.lastPathComponent)") }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw backendFile("Cannot write \(url.lastPathComponent)") }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw backendFile("Cannot flush \(url.lastPathComponent)") }
    }

    static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        let a = lhs.standardizedFileURL.path
        let b = rhs.standardizedFileURL.path
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    static func contains(_ directory: URL, _ item: URL) -> Bool {
        let parent = directory.standardizedFileURL.path
        let child = item.standardizedFileURL.path
        return child == parent || child.hasPrefix(parent + "/")
    }

    private static func openRegularFile(_ url: URL, label: String) throws -> (Int32, Identity) {
        let path = try absoluteLocal(url, label: label).path
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last else {
            throw InferenceFailure.invalidRequest("\(label) must name a regular file.")
        }
        let parentURL = URL(fileURLWithPath: "/" + components.dropLast().joined(separator: "/"), isDirectory: true)
        let parent = try openDirectory(parentURL, label: "parent of \(label)")
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(parent, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw invalidFile("Cannot open \(label)") }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw InferenceFailure.invalidRequest("\(label) must be a regular nonsymlink file.")
        }
        return (descriptor, Identity(value))
    }

    private static func invalidFile(_ action: String) -> InferenceFailure {
        .invalidRequest("\(action): \(String(cString: strerror(errno)))")
    }

    private static func backendFile(_ action: String) -> InferenceFailure {
        .backendFailed("\(action): \(String(cString: strerror(errno)))")
    }
}
