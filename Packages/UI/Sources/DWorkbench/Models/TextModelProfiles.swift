import CryptoKit
import DInference
import Darwin
import Foundation

public struct TextModelProfile: Sendable, Equatable {
    public enum ValidationStatus: Sendable, Equatable {
        case previouslyRealModelVerified
        case registeredAwaitingRealModelValidation
    }

    public let id: String
    public let displayTitle: String
    public let repository: String
    public let revision: String
    public let quantizationBits: Int
    public let validationStatus: ValidationStatus

    init(id: String, displayTitle: String, repository: String, revision: String,
         quantizationBits: Int, validationStatus: ValidationStatus) {
        self.id = id
        self.displayTitle = displayTitle
        self.repository = repository
        self.revision = revision
        self.quantizationBits = quantizationBits
        self.validationStatus = validationStatus
    }
}

struct TextModelManifest: Decodable, Sendable, Equatable {
    struct File: Decodable, Sendable, Equatable {
        let name: String
        let size: UInt64
        let algorithm: String
        let checksum: String

        init(name: String, size: UInt64, algorithm: String, checksum: String) {
            self.name = name
            self.size = size
            self.algorithm = algorithm
            self.checksum = checksum
        }
    }

    let schemaVersion: Int
    let repository: String
    let revision: String
    let directoryName: String
    let source: String
    let files: [File]

    init(schemaVersion: Int, repository: String, revision: String, directoryName: String,
         source: String, files: [File]) {
        self.schemaVersion = schemaVersion
        self.repository = repository
        self.revision = revision
        self.directoryName = directoryName
        self.source = source
        self.files = files
    }
}

struct TextModelRegistration: Sendable, Equatable {
    let profile: TextModelProfile
    let manifest: TextModelManifest

    init(profile: TextModelProfile, manifest: TextModelManifest) {
        self.profile = profile
        self.manifest = manifest
    }
}

struct TextModelVerificationOptions: Sendable {
    let hashChunkSize: Int
    let didHashChunk: (@Sendable () -> Void)?

    init(hashChunkSize: Int = 1024 * 1024,
         didHashChunk: (@Sendable () -> Void)? = nil) {
        self.hashChunkSize = hashChunkSize
        self.didHashChunk = didHashChunk
    }
}

/// The application admits only these bundled, pinned registrations. Verification never downloads.
public enum TextModelProfiles {
    static let originalProfileID = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

    private struct ExpectedSpecification: Sendable {
        let profile: TextModelProfile
        let resourceName: String
        let directoryName: String
    }

    private static let expectedSpecifications: [ExpectedSpecification] = [
        ExpectedSpecification(
            profile: TextModelProfile(
                id: originalProfileID,
                displayTitle: "Qwen2.5 0.5B Instruct · 4-bit",
                repository: originalProfileID,
                revision: "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3",
                quantizationBits: 4,
                validationStatus: .previouslyRealModelVerified),
            resourceName: "text-model",
            directoryName: "Qwen2.5-0.5B-Instruct-4bit"),
        ExpectedSpecification(
            profile: TextModelProfile(
                id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                displayTitle: "Qwen2.5 1.5B Instruct · 4-bit",
                repository: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                revision: "8b403126fc14f14cfc99bb4cfa72ecbc129ea677",
                quantizationBits: 4,
                validationStatus: .registeredAwaitingRealModelValidation),
            resourceName: "text-model-1_5b",
            directoryName: "Qwen2.5-1.5B-Instruct-4bit"),
        ExpectedSpecification(
            profile: TextModelProfile(
                id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
                displayTitle: "Qwen2.5 7B Instruct · 4-bit",
                repository: "mlx-community/Qwen2.5-7B-Instruct-4bit",
                revision: "c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed",
                quantizationBits: 4,
                validationStatus: .registeredAwaitingRealModelValidation),
            resourceName: "text-model-7b",
            directoryName: "Qwen2.5-7B-Instruct-4bit"),
        ExpectedSpecification(
            profile: TextModelProfile(
                id: "mlx-community/Qwen2.5-32B-Instruct-4bit",
                displayTitle: "Qwen2.5 32B Instruct · 4-bit",
                repository: "mlx-community/Qwen2.5-32B-Instruct-4bit",
                revision: "2938092373e5f97b95538884112085364c2da315",
                quantizationBits: 4,
                validationStatus: .registeredAwaitingRealModelValidation),
            resourceName: "text-model-32b",
            directoryName: "Qwen2.5-32B-Instruct-4bit")
    ]

    public static func registered() throws -> [TextModelProfile] {
        try bundledRegistrations().map(\.profile)
    }

    public static func profile(forRevision revision: String?) throws -> TextModelProfile? {
        let profiles = try registered()
        guard let revision else { return nil }
        return profiles.first { $0.revision == revision }
    }

    public static func status(for reference: ModelReference?) throws -> String {
        guard let reference else {
            _ = try registered()
            return "尚未选择文字模型"
        }
        guard let profile = try profile(forRevision: reference.revision) else {
            return "文字模型 · 版本未登记"
        }
        let verified = profile.displayTitle + " · 文件已校验"
        switch profile.validationStatus {
        case .previouslyRealModelVerified:
            return verified
        case .registeredAwaitingRealModelValidation:
            return verified + " · 推理待本机验证"
        }
    }

    public static func verify(at directory: URL) async throws -> ModelReference {
        try await verify(at: directory, registrations: bundledRegistrations())
    }

    static func registrationForTesting(profileID: String,
                                       files: [TextModelManifest.File]) throws -> TextModelRegistration {
        guard let specification = expectedSpecifications.first(where: { $0.profile.id == profileID }) else {
            throw packagingError("测试注入使用了未注册的稳定 ID。")
        }
        return TextModelRegistration(
            profile: specification.profile,
            manifest: TextModelManifest(
                schemaVersion: 1,
                repository: specification.profile.repository,
                revision: specification.profile.revision,
                directoryName: specification.directoryName,
                source: source(for: specification.profile),
                files: files))
    }

    static func verify(at directory: URL,
                       registrations: [TextModelRegistration],
                       options: TextModelVerificationOptions = TextModelVerificationOptions()) async throws -> ModelReference {
        try validate(registrations: registrations, requireCompleteSet: false)
        guard options.hashChunkSize > 0, options.hashChunkSize <= 1024 * 1024 else {
            throw InferenceFailure.invalidRequest("文字模型校验缓冲区大小无效。")
        }
        let worker = Task.detached(priority: .utility) {
            try verifySynchronously(at: directory, registrations: registrations, options: options)
        }
        return try await withTaskCancellationHandler {
            let reference = try await worker.value
            try Task.checkCancellation()
            return reference
        } onCancel: {
            worker.cancel()
        }
    }

    static func verifyOriginalHalfB(at directory: URL,
                                    registration: TextModelRegistration? = nil,
                                    options: TextModelVerificationOptions = TextModelVerificationOptions()) async throws -> ModelReference {
        let selected: TextModelRegistration
        if let registration {
            selected = registration
        } else {
            selected = try loadBundledRegistration(specification: expectedSpecifications[0])
        }
        guard selected.profile.id == originalProfileID else {
            throw InferenceFailure.invalidRequest("所选文字模型不是原有的 Qwen2.5 0.5B 固定模型。")
        }
        return try await verify(at: directory, registrations: [selected], options: options)
    }

    private static func bundledRegistrations() throws -> [TextModelRegistration] {
        let registrations = try expectedSpecifications.map(loadBundledRegistration)
        try validate(registrations: registrations, requireCompleteSet: true)
        return registrations
    }

    private static func loadBundledRegistration(
        specification: ExpectedSpecification
    ) throws -> TextModelRegistration {
        let matchingResources = (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.deletingPathExtension().lastPathComponent == specification.resourceName }
        guard matchingResources.count == 1, let resource = matchingResources.first else {
            throw packagingError("固定清单 \(specification.resourceName).json 必须在包内恰好存在一份。")
        }
        do {
            let data = try Data(contentsOf: resource, options: .mappedIfSafe)
            let manifest = try JSONDecoder().decode(TextModelManifest.self, from: data)
            return TextModelRegistration(profile: specification.profile, manifest: manifest)
        } catch let failure as InferenceFailure {
            throw failure
        } catch {
            throw packagingError("无法解码固定清单 \(specification.resourceName).json。")
        }
    }

    private static func validate(registrations: [TextModelRegistration],
                                 requireCompleteSet: Bool) throws {
        guard !registrations.isEmpty else { throw packagingError("固定注册表为空。") }
        if requireCompleteSet {
            guard registrations.count == expectedSpecifications.count else {
                throw packagingError("固定注册表数量不符。")
            }
            guard registrations.map(\.profile.id) == expectedSpecifications.map(\.profile.id) else {
                throw packagingError("固定注册表顺序或身份不符。")
            }
        }

        var profileIDs = Set<String>()
        var revisions = Set<String>()
        var manifestIdentities = Set<String>()
        for registration in registrations {
            guard let expected = expectedSpecifications.first(where: { $0.profile.id == registration.profile.id }),
                  registration.profile == expected.profile else {
                throw packagingError("注册描述符不是预定义的稳定文字模型。")
            }
            guard profileIDs.insert(registration.profile.id).inserted,
                  revisions.insert(registration.profile.revision).inserted else {
                throw packagingError("文字模型注册表含有重复 ID 或 revision。")
            }

            let manifest = registration.manifest
            guard manifest.schemaVersion == 1,
                  manifest.repository == registration.profile.repository,
                  manifest.revision == registration.profile.revision,
                  manifest.directoryName == expected.directoryName,
                  manifest.source == source(for: registration.profile),
                  !manifest.files.isEmpty else {
                throw packagingError("文字模型清单元数据与固定注册不符。")
            }

            var names = Set<String>()
            for file in manifest.files {
                guard isValidFileName(file.name), names.insert(file.name).inserted,
                      file.name != ".download.lock", file.name != ".provenance.json",
                      file.size > 0, Int(exactly: file.size) != nil, off_t(exactly: file.size) != nil else {
                    throw packagingError("文字模型清单文件路径、大小或重复状态无效。")
                }
                let digestLength: Int
                switch file.algorithm {
                case "sha256": digestLength = 64
                case "git-blob-sha1": digestLength = 40
                default: throw packagingError("文字模型清单含有不支持的摘要算法。")
                }
                guard file.checksum.count == digestLength,
                      file.checksum.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
                    throw packagingError("文字模型清单摘要格式无效。")
                }
            }
            let identity = manifest.files.sorted { $0.name < $1.name }
                .map { "\($0.name)\u{1f}\($0.size)\u{1f}\($0.algorithm)\u{1f}\($0.checksum)" }
                .joined(separator: "\u{1e}")
            guard manifestIdentities.insert(identity).inserted else {
                throw packagingError("两个文字模型清单声称了同一组文件身份。")
            }
        }
    }

    private static func verifySynchronously(
        at directory: URL,
        registrations: [TextModelRegistration],
        options: TextModelVerificationOptions
    ) throws -> ModelReference {
        try Task.checkCancellation()
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw InferenceFailure.invalidRequest("文字模型目录必须是本地绝对路径。")
        }
        let normalized = directory.standardizedFileURL
        guard normalized.resolvingSymlinksInPath().path == normalized.path else {
            throw InferenceFailure.invalidRequest("文字模型根目录不能通过符号链接间接引用。")
        }

        var pathBefore = stat()
        guard lstat(normalized.path, &pathBefore) == 0,
              pathBefore.st_mode & S_IFMT == S_IFDIR else {
            throw InferenceFailure.invalidRequest("无法打开文字模型根目录。")
        }
        let rootFD = Darwin.open(normalized.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw InferenceFailure.invalidRequest("无法安全打开文字模型根目录。")
        }
        defer { Darwin.close(rootFD) }
        var rootBefore = stat()
        guard fstat(rootFD, &rootBefore) == 0, sameIdentity(pathBefore, rootBefore) else {
            throw InferenceFailure.invalidRequest("文字模型根目录在打开期间发生变化。")
        }

        let names = try directoryEntries(rootFD: rootFD)
        let bookkeeping: Set<String> = [".download.lock", ".provenance.json"]
        var sizes: [String: UInt64] = [:]
        for name in names {
            try Task.checkCancellation()
            let fd = Darwin.openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                throw InferenceFailure.invalidRequest("文字模型目录含有无法安全读取的项目。")
            }
            var info = stat()
            let status = fstat(fd, &info)
            Darwin.close(fd)
            guard status == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
                throw InferenceFailure.invalidRequest("文字模型目录仅允许预定义的普通文件。")
            }
            if bookkeeping.contains(name) {
                guard info.st_size <= 65_536 else {
                    throw InferenceFailure.invalidRequest("模型管理文件的类型或大小不符。")
                }
            } else {
                sizes[name] = UInt64(info.st_size)
            }
        }

        let candidates = registrations.filter { registration in
            let expected = Dictionary(uniqueKeysWithValues: registration.manifest.files.map { ($0.name, $0.size) })
            return expected == sizes
        }
        guard !candidates.isEmpty else {
            throw InferenceFailure.invalidRequest("模型目录文件清单或大小与已注册文字模型不符。")
        }

        var matches: [TextModelRegistration] = []
        for candidate in candidates {
            do {
                for file in candidate.manifest.files {
                    try verify(file: file, rootFD: rootFD, options: options)
                }
                matches.append(candidate)
            } catch VerificationMismatch.digest {
                continue
            }
        }
        try verifyRootUnchanged(path: normalized.path, rootFD: rootFD,
                                pathBefore: pathBefore, rootBefore: rootBefore)
        guard matches.count == 1, let match = matches.first else {
            if matches.isEmpty {
                throw InferenceFailure.invalidRequest("文字模型全部文件摘要与已注册身份不符。")
            }
            throw InferenceFailure.invalidRequest("文字模型目录不能唯一解析为一个已注册身份。")
        }
        try Task.checkCancellation()
        return ModelReference(directory: directory, revision: match.profile.revision)
    }

    private enum VerificationMismatch: Error { case digest }

    private static func verify(file: TextModelManifest.File, rootFD: Int32,
                               options: TextModelVerificationOptions) throws {
        try Task.checkCancellation()
        let fd = Darwin.openat(rootFD, file.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw InferenceFailure.invalidRequest("无法读取文字模型文件：\(file.name)")
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, UInt64(before.st_size) == file.size else {
            throw InferenceFailure.invalidRequest("文字模型文件类型或大小不符：\(file.name)")
        }

        var sha256 = SHA256()
        var gitSHA1 = Insecure.SHA1()
        if file.algorithm == "git-blob-sha1" {
            gitSHA1.update(data: Data("blob \(file.size)\0".utf8))
        }
        var buffer = [UInt8](repeating: 0, count: options.hashChunkSize)
        var total: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw InferenceFailure.invalidRequest("文字模型文件读取失败：\(file.name)")
            }
            if count == 0 { break }
            let addition = total.addingReportingOverflow(UInt64(count))
            guard !addition.overflow, addition.partialValue <= file.size else {
                throw InferenceFailure.invalidRequest("文字模型文件在校验期间发生变化。")
            }
            total = addition.partialValue
            let data = Data(buffer.prefix(count))
            if file.algorithm == "sha256" {
                sha256.update(data: data)
            } else {
                gitSHA1.update(data: data)
            }
            options.didHashChunk?()
            try Task.checkCancellation()
        }

        var after = stat()
        var pathAfter = stat()
        guard fstat(fd, &after) == 0,
              fstatat(rootFD, file.name, &pathAfter, AT_SYMLINK_NOFOLLOW) == 0,
              total == file.size, sameStableFile(before, after), sameStableFile(before, pathAfter) else {
            throw InferenceFailure.invalidRequest("文字模型文件在校验期间发生变化：\(file.name)")
        }
        let digest: String
        if file.algorithm == "sha256" {
            digest = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        } else {
            digest = gitSHA1.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard digest == file.checksum else { throw VerificationMismatch.digest }
    }

    private static func directoryEntries(rootFD: Int32) throws -> Set<String> {
        let copiedFD = Darwin.dup(rootFD)
        guard copiedFD >= 0 else {
            throw InferenceFailure.invalidRequest("无法枚举文字模型目录。")
        }
        guard let stream = fdopendir(copiedFD) else {
            Darwin.close(copiedFD)
            throw InferenceFailure.invalidRequest("无法枚举文字模型目录。")
        }
        defer { closedir(stream) }
        var names = Set<String>()
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.insert(name) }
            errno = 0
        }
        guard errno == 0 else {
            throw InferenceFailure.invalidRequest("文字模型目录枚举失败。")
        }
        return names
    }

    private static func verifyRootUnchanged(path: String, rootFD: Int32,
                                            pathBefore: stat, rootBefore: stat) throws {
        var pathAfter = stat()
        var rootAfter = stat()
        guard lstat(path, &pathAfter) == 0, fstat(rootFD, &rootAfter) == 0,
              sameStableDirectory(pathBefore, pathAfter),
              sameStableDirectory(rootBefore, rootAfter),
              sameIdentity(pathAfter, rootAfter) else {
            throw InferenceFailure.invalidRequest("文字模型根目录在校验期间发生变化。")
        }
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
            (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    private static func sameStableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) && lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func sameStableDirectory(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\0")
    }

    private static func source(for profile: TextModelProfile) -> String {
        "https://huggingface.co/\(profile.repository)/tree/\(profile.revision)"
    }

    private static func packagingError(_ detail: String) -> InferenceFailure {
        .invalidRequest("文字模型注册清单打包错误：\(detail)")
    }
}
