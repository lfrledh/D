import CryptoKit
import Darwin
import Foundation

/// Read-only description of the fixed audio engine bundled with an application.
struct BundledAudioEngine: Sendable {
    enum Family: Sendable {
        case stableAudio, mrt2Music
        var directory: String { self == .stableAudio ? "AudioEngine.dengine" : "MRT2MusicEngine.dengine" }
        var kind: String { self == .stableAudio ? "d-audio-engine" : "d-mrt2-music-engine" }
        var script: String { self == .stableAudio ? "provider/d_audio_backend.py" : "provider/d_audio_mrt2_backend.py" }
        var model: String { self == .stableAudio ? "model-manifests/sm-music.json" : "model-manifests/mrt2-small.json" }
        var required: [String] {
            ["python/bin/python3", script, "provider/d_audio_access.py", "provider/d_audio_contract.py", model] +
                (self == .stableAudio ? ["provider/d_audio_sa3.py"] : ["provider/d_audio_mrt2_contract.py", "provider/d_mrt2_export.py"])
        }
    }
    let family: Family
    let pythonExecutable: URL
    let providerScript: URL
    let vendorDirectory: URL
    let modelManifest: URL

    private let root: URL
    private let manifest: URL
    private let rootEntry: Entry
    private let manifestEntry: Entry
    private let manifestDigest: String
    private let entries: [String: Entry]

    private static let maximumManifestBytes = 4 * 1024 * 1024
    private static let maximumFiles = 10_000
    private static let maximumFileBytes: Int64 = 512 * 1024 * 1024
    private static let maximumAggregateBytes: Int64 = 1024 * 1024 * 1024

    private struct Entry: Sendable, Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private struct DeclaredFile {
        let path: String
        let size: Int64
        let digest: String
        let executable: Bool
    }

    private enum DeploymentError: LocalizedError {
        case invalid(String)

        var errorDescription: String? { "Bundled audio engine deployment error: \(message)" }

        private var message: String {
            switch self { case let .invalid(message): return message }
        }
    }

    static func resolve(resourceDirectory: URL, family: Family = .stableAudio) throws -> BundledAudioEngine? {
        let root = resourceDirectory.appendingPathComponent(family.directory, isDirectory: true)
        var rootStatus = stat()
        if Darwin.lstat(root.path, &rootStatus) != 0 {
            if errno == ENOENT { return nil }
            throw DeploymentError.invalid("cannot inspect AudioEngine.dengine")
        }
        let initialRoot = try entry(at: root)
        guard initialRoot.isDirectory else { throw DeploymentError.invalid("AudioEngine.dengine is not a directory") }
        let manifest = root.appendingPathComponent("engine.json", isDirectory: false)
        let initialManifestEntry = try entry(at: manifest)
        guard !initialManifestEntry.isDirectory else { throw DeploymentError.invalid("engine.json is not a regular file") }
        guard initialManifestEntry.metadata.size <= Int64(maximumManifestBytes) else {
            throw DeploymentError.invalid("engine.json exceeds the 4 MiB limit")
        }
        let manifestData = try boundedData(manifest, expected: initialManifestEntry.metadata, limit: maximumManifestBytes)
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
                throw DeploymentError.invalid("engine.json root must be an object")
            }
            object = value
        } catch let error as DeploymentError {
            throw error
        } catch {
            throw DeploymentError.invalid("engine.json is malformed")
        }
        try requireExact(object, key: "schemaVersion", integer: 1)
        try requireExact(object, key: "kind", string: family.kind)
        try requireExact(object, key: "pythonABI", string: "3.12")
        try requireExact(object, key: "pythonExecutable", string: "python/bin/python3")
        try requireExact(object, key: "providerScript", string: family.script)
        try requireExact(object, key: "vendorDirectory", string: "vendor")
        try requireExact(object, key: "modelManifestsDirectory", string: "model-manifests")
        guard let values = object["files"] as? [Any], values.count <= maximumFiles else {
            throw DeploymentError.invalid("files list is missing or exceeds the limit")
        }

        var declared: [String: DeclaredFile] = [:]
        var aggregate: Int64 = 0
        for value in values {
            guard let file = value as? [String: Any], let path = file["path"] as? String,
                  let size = strictInteger(file["sizeBytes"]), let digest = file["sha256"] as? String,
                  let executable = strictBoolean(file["executable"]) else {
                throw DeploymentError.invalid("a files entry has invalid types")
            }
            guard normalized(path), path != "engine.json", size >= 0, size <= maximumFileBytes,
                  digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  declared[path] == nil else {
                throw DeploymentError.invalid("a files entry is invalid, duplicate, or unsafe")
            }
            guard aggregate <= maximumAggregateBytes - size else {
                throw DeploymentError.invalid("declared files exceed the aggregate limit")
            }
            aggregate += size
            declared[path] = DeclaredFile(path: path, size: size, digest: digest, executable: executable)
        }

        let required = family.required
        for path in required where declared[path] == nil {
            throw DeploymentError.invalid("required engine file is absent from engine.json: \(path)")
        }
        let vendor = root.appendingPathComponent("vendor", isDirectory: true)
        guard try entry(at: vendor).isDirectory else { throw DeploymentError.invalid("vendor is not a directory") }

        let actual = try treeEntries(root: root)
        guard Set(actual.keys) == Set(declared.keys) else {
            throw DeploymentError.invalid("engine contains missing or undeclared regular files")
        }
        for (path, declaration) in declared {
            guard let metadata = actual[path], metadata.size == declaration.size else {
                throw DeploymentError.invalid("size differs for \(path)")
            }
            guard executable(metadata.mode) == declaration.executable else {
                throw DeploymentError.invalid("executable mode differs for \(path)")
            }
            guard try sha256(root.appendingPathComponent(path, isDirectory: false), expected: metadata) == declaration.digest else {
                throw DeploymentError.invalid("SHA-256 differs for \(path)")
            }
        }
        let finalEntries = try treeEntries(root: root)
        guard finalEntries == actual else { throw DeploymentError.invalid("engine changed while being resolved") }
        let finalRoot = try entry(at: root)
        let finalManifest = try entry(at: manifest)
        guard finalRoot == initialRoot, finalManifest == initialManifestEntry else {
            throw DeploymentError.invalid("engine changed while being resolved")
        }
        return BundledAudioEngine(family: family, pythonExecutable: root.appendingPathComponent("python/bin/python3"),
                                  providerScript: root.appendingPathComponent(family.script),
                                  vendorDirectory: vendor,
                                  modelManifest: root.appendingPathComponent(family.model),
                                  root: root, manifest: manifest, rootEntry: finalRoot.metadata, manifestEntry: finalManifest.metadata,
                                  manifestDigest: try sha256(manifest, expected: finalManifest.metadata),
                                  entries: finalEntries)
    }

    func confirmUnchanged() throws {
        guard try Self.entry(at: root).metadata == rootEntry else {
            throw DeploymentError.invalid("engine root changed after resolution")
        }
        let current = try Self.treeEntries(root: root)
        guard current == entries else { throw DeploymentError.invalid("engine file tree changed after resolution") }
        let currentManifest = try Self.entry(at: manifest)
        guard currentManifest.metadata == manifestEntry,
              try Self.sha256(manifest, expected: currentManifest.metadata) == manifestDigest else {
            throw DeploymentError.invalid("engine.json contents changed after resolution")
        }
    }

    private static func requireExact(_ object: [String: Any], key: String, string: String) throws {
        guard object[key] as? String == string else { throw DeploymentError.invalid("\(key) is not \(string)") }
    }

    private static func requireExact(_ object: [String: Any], key: String, integer: Int64) throws {
        guard strictInteger(object[key]) == integer else { throw DeploymentError.invalid("\(key) is not \(integer)") }
    }

    private static func strictInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let type = String(cString: number.objCType)
        guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else { return nil }
        let result = number.int64Value
        return NSNumber(value: result) == number ? result : nil
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func normalized(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private static func executable(_ mode: UInt16) -> Bool { mode & 0o111 != 0 }

    private static func entry(at url: URL) throws -> (metadata: Entry, isDirectory: Bool) {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else { throw DeploymentError.invalid("unreadable path: \(url.lastPathComponent)") }
        guard value.st_mode & S_IFMT != S_IFLNK else { throw DeploymentError.invalid("symbolic link is not allowed: \(url.lastPathComponent)") }
        let kind = value.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else { throw DeploymentError.invalid("special file is not allowed: \(url.lastPathComponent)") }
        return (Entry(device: Int64(value.st_dev), inode: UInt64(value.st_ino), size: Int64(value.st_size),
                      mode: UInt16(value.st_mode & 0o7777), modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
                      modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec), changedSeconds: Int64(value.st_ctimespec.tv_sec),
                      changedNanoseconds: Int64(value.st_ctimespec.tv_nsec)), kind == S_IFDIR)
    }

    private static func treeEntries(root: URL) throws -> [String: Entry] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else {
            throw DeploymentError.invalid("cannot enumerate engine")
        }
        var result: [String: Entry] = [:]
        while let url = enumerator.nextObject() as? URL {
            let path = url.path
            guard path.hasPrefix(root.path + "/") else { throw DeploymentError.invalid("engine enumeration escaped root") }
            let relative = String(path.dropFirst(root.path.count + 1))
            let item = try entry(at: url)
            if !item.isDirectory {
                guard relative != "engine.json" else { continue }
                guard result.count < maximumFiles else { throw DeploymentError.invalid("engine has more than 10000 regular files") }
                result[relative] = item.metadata
            }
        }
        if enumerationError != nil { throw DeploymentError.invalid("cannot completely enumerate engine") }
        return result
    }

    private static func openRegularFile(_ url: URL, expected: Entry, limit: Int64) throws -> FileHandle {
        guard expected.size >= 0 && expected.size <= limit else { throw DeploymentError.invalid("file size is outside deployment limit") }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DeploymentError.invalid("cannot safely open \(url.lastPathComponent)") }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            Darwin.close(descriptor)
            throw DeploymentError.invalid("cannot inspect opened \(url.lastPathComponent)")
        }
        let kind = status.st_mode & S_IFMT
        guard kind == S_IFREG else {
            Darwin.close(descriptor)
            throw DeploymentError.invalid("opened path is not a regular file: \(url.lastPathComponent)")
        }
        let actual = Entry(device: Int64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size),
                           mode: UInt16(status.st_mode & 0o7777), modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
                           modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec), changedSeconds: Int64(status.st_ctimespec.tv_sec),
                           changedNanoseconds: Int64(status.st_ctimespec.tv_nsec))
        guard actual == expected else {
            Darwin.close(descriptor)
            throw DeploymentError.invalid("file changed before it could be read: \(url.lastPathComponent)")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func boundedData(_ url: URL, expected: Entry, limit: Int) throws -> Data {
        let handle = try openRegularFile(url, expected: expected, limit: Int64(limit))
        defer { try? handle.close() }
        var result = Data()
        while true {
            let block = try handle.read(upToCount: min(1024 * 1024, limit + 1)) ?? Data()
            if block.isEmpty { break }
            guard result.count <= limit - block.count else { throw DeploymentError.invalid("\(url.lastPathComponent) exceeds its size limit") }
            result.append(block)
        }
        return result
    }

    private static func sha256(_ url: URL, expected: Entry) throws -> String {
        let handle = try openRegularFile(url, expected: expected, limit: maximumFileBytes)
        defer { try? handle.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while true {
            let block = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if block.isEmpty { break }
            guard count <= expected.size - Int64(block.count) else { throw DeploymentError.invalid("file grew while hashing") }
            count += Int64(block.count)
            digest.update(data: block)
        }
        guard count == expected.size else { throw DeploymentError.invalid("file size changed while hashing") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
