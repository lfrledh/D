import CryptoKit
import Darwin
import DInference
import Foundation

struct SingingModelInventory: Sendable {
    struct DeclaredFile: Sendable, Equatable {
        let path: String
        let byteCount: UInt64
        let sha256: String
    }

    struct Profile: Sendable {
        let bankArchiveSHA256: String
        let bankTermsSHA256: String
        let bankFiles: [DeclaredFile]
        let vocoderRevision: String
        let vocoderLicenseSHA256: String
        let vocoderFiles: [DeclaredFile]
    }

    let configuration: SingingBackendConfiguration
    let profile: Profile
    let bankDirectory: URL
    let vocoderDirectory: URL
    let protectedInputs: SingingInputSeal
    let estimatedPeakBytes: UInt64

    static func inspect(
        _ request: InferenceRequest, configuration: SingingBackendConfiguration
    ) throws -> Self {
        try Task.checkCancellation()
        try request.validate()
        guard case .singing(let singing) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        guard singing.profileID == SingingBackendConfiguration.profileID,
              request.model.revision == SingingBackendConfiguration.bankArchiveSHA256,
              singing.vocoder.revision == SingingBackendConfiguration.vocoderRevision else {
            throw InferenceFailure.invalidRequest("Singing request does not identify the fixed profile materials.")
        }
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.cancellationGraceSeconds.isFinite,
              configuration.cancellationGraceSeconds > 0 else {
            throw InferenceFailure.invalidRequest("Singing timeout and cancellation grace must be finite and positive.")
        }

        let python = try AudioFileSystem.absoluteLocal(configuration.pythonExecutable, label: "Singing Python executable")
        let provider = try AudioFileSystem.absoluteLocal(configuration.providerScript, label: "Singing provider script")
        let vendor = try AudioFileSystem.absoluteLocal(configuration.vendorDirectory, label: "Singing vendor directory")
        let profileURL = try AudioFileSystem.absoluteLocal(configuration.profileManifest, label: "Singing profile")
        let artifacts = try AudioFileSystem.absoluteLocal(configuration.artifactDirectory, label: "Singing artifact directory")
        let bank = try AudioFileSystem.absoluteLocal(request.model.directory, label: "Singing bank directory")
        let vocoder = try AudioFileSystem.absoluteLocal(singing.vocoder.directory, label: "Singing vocoder directory")
        for (url, label) in [(vendor, "Singing vendor directory"), (artifacts, "Singing artifact directory"),
                             (bank, "Singing bank directory"), (vocoder, "Singing vocoder directory")] {
            try AudioFileSystem.validateDirectory(url, label: label)
        }
        guard [python, provider, vendor, profileURL, bank, vocoder].allSatisfy({
            !AudioFileSystem.overlaps(artifacts, $0)
        }) else {
            throw InferenceFailure.invalidRequest("Singing artifacts must be separate from every execution input.")
        }

        var seal = SingingInputSeal()
        for (url, label) in [(python, "parent of Singing Python executable"),
                             (provider, "parent of Singing provider script"),
                             (profileURL, "parent of Singing profile")] {
            try seal.addDirectory(url.deletingLastPathComponent(), label: label)
        }
        try seal.addDirectory(vendor, label: "Singing vendor directory")
        try seal.addDirectory(bank, label: "Singing bank directory")
        if vocoder != bank { try seal.addDirectory(vocoder, label: "Singing vocoder directory") }
        let pythonRecord = try seal.addFile(python, label: "Singing Python executable", maximumBytes: nil)
        guard Darwin.access(python.path, X_OK) == 0 else {
            throw InferenceFailure.invalidRequest("Singing Python executable is not executable.")
        }
        _ = try seal.addFile(provider, label: "Singing provider script", maximumBytes: 16 * 1024 * 1024)
        let (profileRecord, profileData) = try seal.addSmallFile(
            profileURL, label: "Singing profile", maximumBytes: 2 * 1024 * 1024)
        guard profileRecord.sha256 == SingingBackendConfiguration.profileSHA256 else {
            throw InferenceFailure.invalidRequest("Singing profile trust-anchor SHA-256 mismatch.")
        }
        let parsedProfile = try parseProfile(profileData)
        let q = singing.qualification
        guard q.confirmedApplicable,
              q.bankArchiveSHA256 == parsedProfile.bankArchiveSHA256,
              q.bankTermsSHA256 == parsedProfile.bankTermsSHA256,
              q.vocoderRevision == parsedProfile.vocoderRevision,
              q.vocoderLicenseSHA256 == parsedProfile.vocoderLicenseSHA256 else {
            throw InferenceFailure.invalidRequest("Singing qualification does not match the fixed material identity.")
        }

        let sourceManifestURL = vendor.appendingPathComponent("source-manifest.json")
        let (sourceRecord, sourceData) = try seal.addSmallFile(
            sourceManifestURL, label: "Singing vendor source manifest", maximumBytes: 2 * 1024 * 1024)
        guard sourceRecord.sha256 == SingingBackendConfiguration.vendorManifestSHA256 else {
            throw InferenceFailure.invalidRequest("Singing vendor manifest trust-anchor SHA-256 mismatch.")
        }
        let vendorFiles = try parseSourceManifest(sourceData)
        for file in parsedProfile.bankFiles {
            try Task.checkCancellation()
            _ = try seal.addDeclaredFile(bank.appendingPathComponent(file.path), file: file,
                                         label: "Singing bank file \(file.path)")
        }
        for file in parsedProfile.vocoderFiles {
            try Task.checkCancellation()
            _ = try seal.addDeclaredFile(vocoder.appendingPathComponent(file.path), file: file,
                                         label: "Singing vocoder file \(file.path)")
        }
        let sourceRoot = vendor.appendingPathComponent("bigvgan", isDirectory: true)
        try seal.addDirectory(sourceRoot, label: "Singing BigVGAN source directory")
        for file in vendorFiles {
            try Task.checkCancellation()
            _ = try seal.addDeclaredFile(sourceRoot.appendingPathComponent(file.path), file: file,
                                         label: "Singing vendor file \(file.path)")
        }
        let declaredBytes = try sumBytes(parsedProfile.bankFiles + parsedProfile.vocoderFiles + vendorFiles)
        let peak = try estimate(declaredBytes: declaredBytes, durationTicks: singing.phrase.durationTicks)
        _ = pythonRecord
        return Self(configuration: configuration, profile: parsedProfile, bankDirectory: bank,
                    vocoderDirectory: vocoder, protectedInputs: seal, estimatedPeakBytes: peak)
    }

    func confirmUnchanged(cancellable: Bool) throws {
        try protectedInputs.confirmUnchanged(cancellable: cancellable)
    }

    static func estimate(declaredBytes: UInt64, durationTicks: Int64) throws -> UInt64 {
        guard declaredBytes > 0, durationTicks > 0 else {
            throw InferenceFailure.invalidRequest("Singing resource estimate inputs are invalid.")
        }
        let framesNumerator = UInt64(durationTicks).multipliedReportingOverflow(by: 44_100)
        guard !framesNumerator.overflow else {
            throw InferenceFailure.invalidRequest("Singing duration estimate overflowed.")
        }
        let samples = framesNumerator.partialValue / 1_000_000 + 1
        let modelFrames = samples / 512 + 18
        let pcm = samples.multipliedReportingOverflow(by: 8)
        let frameWorkspace = modelFrames.multipliedReportingOverflow(by: 128 * 4 * 8)
        let doubled = declaredBytes.multipliedReportingOverflow(by: 2)
        guard !pcm.overflow, !frameWorkspace.overflow, !doubled.overflow else {
            throw InferenceFailure.invalidRequest("Singing resource estimate exceeds UInt64 capacity.")
        }
        let base = doubled.partialValue.addingReportingOverflow(1024 * 1024 * 1024)
        let withPCM = base.partialValue.addingReportingOverflow(pcm.partialValue)
        let total = withPCM.partialValue.addingReportingOverflow(frameWorkspace.partialValue)
        guard !base.overflow, !withPCM.overflow, !total.overflow else {
            throw InferenceFailure.invalidRequest("Singing resource estimate exceeds UInt64 capacity.")
        }
        return total.partialValue
    }

    static func parseProfile(_ data: Data) throws -> Profile {
        let root = try parseObject(data, exactKeys: [
            "schemaVersion", "profileID", "bankArchiveSHA256", "bankTermsSHA256", "bankFiles",
            "vocoderRevision", "vocoderFiles", "vocoderLicenseSHA256", "sampleRate", "hopSize",
            "headFrames", "tailFrames", "pitchSteps", "varianceSteps", "acousticSteps",
            "acousticDepth", "contextTicks", "projection",
        ], context: "singing profile")
        guard try root.int("schemaVersion") == 1,
              try root.string("profileID") == SingingBackendConfiguration.profileID,
              try root.int("sampleRate") == 44_100, try root.int("hopSize") == 512,
              try root.int("headFrames") == 8, try root.int("tailFrames") == 8,
              try root.int("pitchSteps") == 10, try root.int("varianceSteps") == 20,
              try root.int("acousticSteps") == 20, try root.int("contextTicks") == 500_000,
              decimal(root["acousticDepth"]!) == Decimal(string: "0.6", locale: Locale(identifier: "en_US_POSIX")) else {
            throw InferenceFailure.invalidRequest("Singing profile contains unsupported fixed execution values.")
        }
        let bank = try files(root["bankFiles"]!, count: 31, context: "singing bank files")
        let vocoder = try files(root["vocoderFiles"]!, count: 3, context: "singing vocoder files")
        let bankArchive = try root.string("bankArchiveSHA256")
        let terms = try root.string("bankTermsSHA256")
        let revision = try root.string("vocoderRevision")
        let license = try root.string("vocoderLicenseSHA256")
        guard bankArchive == SingingBackendConfiguration.bankArchiveSHA256,
              revision == SingingBackendConfiguration.vocoderRevision,
              [bankArchive, terms, license].allSatisfy(validDigest) else {
            throw InferenceFailure.invalidRequest("Singing profile material identity is unsupported.")
        }
        try validateProjection(root["projection"]!)
        return Profile(bankArchiveSHA256: bankArchive, bankTermsSHA256: terms, bankFiles: bank,
                       vocoderRevision: revision, vocoderLicenseSHA256: license, vocoderFiles: vocoder)
    }

    static func parseSourceManifest(_ data: Data) throws -> [DeclaredFile] {
        let root = try parseObject(data, exactKeys: ["schemaVersion", "modelRevision", "sourceFiles"],
                                   context: "singing vendor manifest")
        guard try root.int("schemaVersion") == 1,
              try root.string("modelRevision") == SingingBackendConfiguration.vocoderRevision else {
            throw InferenceFailure.invalidRequest("Singing vendor manifest revision is unsupported.")
        }
        return try files(root["sourceFiles"]!, count: 18, context: "singing vendor files")
    }

    private static func parseObject(_ data: Data, exactKeys: Set<String>, context: String) throws
        -> [String: AudioJSONValue] {
        do {
            var parser = AudioJSONParser(data: data, maximumDepth: 32)
            return try parser.parse().object(exactKeys: exactKeys, context: context)
        } catch let failure as InferenceFailure { throw failure }
        catch { throw InferenceFailure.invalidRequest("Invalid \(context): \(error.localizedDescription)") }
    }

    private static func files(_ value: AudioJSONValue, count: Int, context: String) throws -> [DeclaredFile] {
        guard case .array(let values) = value, values.count == count else {
            throw InferenceFailure.invalidRequest("\(context) must contain exactly \(count) entries.")
        }
        var seen = Set<String>()
        return try values.map {
            let item = try $0.object(exactKeys: ["path", "byteCount", "sha256"], context: context)
            let path = try item.string("path")
            let bytes = try item["byteCount"]!.requiredUInt64(context: "\(context) byteCount")
            let digest = try item.string("sha256")
            guard bytes > 0, safeRelativePath(path), validDigest(digest), seen.insert(path).inserted else {
                throw InferenceFailure.invalidRequest("\(context) contains an invalid or duplicate entry.")
            }
            return DeclaredFile(path: path, byteCount: bytes, sha256: digest)
        }
    }

    private static func validateProjection(_ value: AudioJSONValue) throws {
        let p = try value.object(exactKeys: [
            "kind", "sourceFmin", "sourceFmax", "targetFmin", "targetFmax", "nFFT", "melBands",
            "norm", "logBase", "nnlsBlockFrames", "nnlsHistory", "nnlsMaxIterations",
            "maximumRelativeResidual",
        ], context: "singing projection")
        guard try p.string("kind") == "approximate-nonnegative-amplitude-reprojection",
              try p.int("sourceFmin") == 40, try p.int("sourceFmax") == 16_000,
              try p.int("targetFmin") == 0, try p.int("targetFmax") == 22_050,
              try p.int("nFFT") == 2048, try p.int("melBands") == 128,
              try p.string("norm") == "slaney", try p.string("logBase") == "e",
              try p.int("nnlsBlockFrames") == 32, try p.int("nnlsHistory") == 10,
              try p.int("nnlsMaxIterations") == 200,
              decimal(p["maximumRelativeResidual"]!) == Decimal(string: "0.1", locale: Locale(identifier: "en_US_POSIX")) else {
            throw InferenceFailure.invalidRequest("Singing projection profile is unsupported.")
        }
    }

    private static func decimal(_ value: AudioJSONValue) -> Decimal? {
        switch value {
        case .integer(let number): return Decimal(number)
        case .unsignedInteger(let number):
            return Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX"))
        case .number(let number): return number
        default: return nil
        }
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\0") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sumBytes(_ files: [DeclaredFile]) throws -> UInt64 {
        try files.reduce(0) { total, file in
            let result = total.addingReportingOverflow(file.byteCount)
            guard !result.overflow else {
                throw InferenceFailure.invalidRequest("Singing declared material sizes overflow UInt64.")
            }
            return result.partialValue
        }
    }
}

struct SingingInputSeal: Sendable {
    private var directories: [(url: URL, label: String, identity: AudioFileSystem.Identity)] = []
    private var files: [SingingSealedFile] = []

    init() {}

    mutating func addDirectory(_ url: URL, label: String) throws {
        let fd = try AudioFileSystem.openDirectory(url, label: label)
        defer { Darwin.close(fd) }
        var value = stat()
        guard Darwin.fstat(fd, &value) == 0 else {
            throw InferenceFailure.invalidRequest("Cannot identify \(label).")
        }
        directories.append((url, label, AudioFileSystem.Identity(value)))
    }

    @discardableResult
    mutating func addFile(_ url: URL, label: String, maximumBytes: UInt64?) throws -> SingingSealedFile {
        let record = try SingingSealedFile.capture(url, label: label, maximumBytes: maximumBytes,
                                                   cancellable: true)
        files.append(record)
        return record
    }

    mutating func addSmallFile(
        _ url: URL, label: String, maximumBytes: UInt64
    ) throws -> (SingingSealedFile, Data) {
        let pair = try SingingSealedFile.captureData(
            url, label: label, maximumBytes: maximumBytes, cancellable: true)
        files.append(pair.0)
        return pair
    }

    @discardableResult
    mutating func addDeclaredFile(
        _ url: URL, file: SingingModelInventory.DeclaredFile, label: String
    ) throws -> SingingSealedFile {
        let record = try addFile(url, label: label, maximumBytes: file.byteCount)
        guard record.identity.size >= 0, UInt64(record.identity.size) == file.byteCount,
              record.sha256 == file.sha256 else {
            throw InferenceFailure.invalidRequest("Size or SHA-256 mismatch for \(label).")
        }
        return record
    }

    func confirmUnchanged(cancellable: Bool) throws {
        for directory in directories {
            if cancellable { try Task.checkCancellation() }
            do {
                let fd = try AudioFileSystem.openDirectory(directory.url, label: directory.label)
                defer { Darwin.close(fd) }
                var value = stat()
                guard Darwin.fstat(fd, &value) == 0,
                      AudioFileSystem.Identity(value) == directory.identity else {
                    throw InferenceFailure.inputIntegrityChanged(
                        "Protected \(directory.label) changed during singing execution.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as InferenceFailure {
                if case .inputIntegrityChanged = failure { throw failure }
                throw InferenceFailure.backendFailed(
                    "Cannot complete post-drain protection verification for \(directory.label): "
                        + failure.localizedDescription)
            } catch {
                throw InferenceFailure.backendFailed(
                    "Cannot complete post-drain protection verification for \(directory.label): "
                        + error.localizedDescription)
            }
        }
        for file in files {
            if cancellable { try Task.checkCancellation() }
            do { try file.confirmUnchanged(cancellable: cancellable) }
            catch is CancellationError { throw CancellationError() }
            catch let failure as InferenceFailure {
                if case .inputIntegrityChanged = failure { throw failure }
                throw InferenceFailure.backendFailed(
                    "Cannot complete post-drain protection verification for \(file.label): "
                        + failure.localizedDescription)
            }
            catch {
                throw InferenceFailure.backendFailed(
                    "Cannot complete post-drain protection verification for \(file.label): "
                        + error.localizedDescription)
            }
        }
    }
}

struct SingingSealedFile: Sendable {
    let url: URL
    let label: String
    let identity: AudioFileSystem.Identity
    let sha256: String

    static func capture(
        _ url: URL, label: String, maximumBytes: UInt64?, cancellable: Bool
    ) throws -> Self {
        try captureData(url, label: label, maximumBytes: maximumBytes,
                        cancellable: cancellable, retainData: false).0
    }

    static func captureData(
        _ url: URL, label: String, maximumBytes: UInt64, cancellable: Bool
    ) throws -> (Self, Data) {
        try captureData(url, label: label, maximumBytes: maximumBytes,
                        cancellable: cancellable, retainData: true)
    }

    private static func captureData(
        _ url: URL, label: String, maximumBytes: UInt64?, cancellable: Bool, retainData: Bool
    ) throws -> (Self, Data) {
        let absolute = try AudioFileSystem.absoluteLocal(url, label: label)
        let components = absolute.path.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw InferenceFailure.invalidRequest("\(label) must name a regular file.")
        }
        let parentURL = URL(fileURLWithPath: "/" + components.dropLast().joined(separator: "/"), isDirectory: true)
        let parent = try AudioFileSystem.openDirectory(parentURL, label: "parent of \(label)")
        defer { Darwin.close(parent) }
        let fd = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw fileFailure("Cannot open \(label)") }
        defer { Darwin.close(fd) }
        var beforeValue = stat()
        guard Darwin.fstat(fd, &beforeValue) == 0, beforeValue.st_mode & S_IFMT == S_IFREG else {
            throw InferenceFailure.invalidRequest("\(label) must be a regular nonsymlink file.")
        }
        let before = AudioFileSystem.Identity(beforeValue)
        guard before.size >= 0, maximumBytes.map({ UInt64(before.size) <= $0 }) ?? true else {
            throw InferenceFailure.invalidRequest("\(label) exceeds its bounded size.")
        }
        var hash = SHA256()
        var retained = Data()
        if retainData { retained.reserveCapacity(Int(before.size)) }
        var remaining = before.size
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while remaining > 0 {
            if cancellable { try Task.checkCancellation() }
            let requested = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, requested) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw fileFailure("Cannot read complete \(label)") }
            let chunk = Data(buffer.prefix(count))
            hash.update(data: chunk)
            if retainData { retained.append(chunk) }
            remaining -= Int64(count)
        }
        var extra: UInt8 = 0
        var trailing: Int
        repeat { trailing = Darwin.read(fd, &extra, 1) } while trailing < 0 && errno == EINTR
        guard trailing == 0 else {
            throw InferenceFailure.invalidRequest("\(label) grew while being sealed.")
        }
        var afterValue = stat()
        guard Darwin.fstat(fd, &afterValue) == 0, AudioFileSystem.Identity(afterValue) == before else {
            throw InferenceFailure.invalidRequest("\(label) changed while being sealed.")
        }
        return (Self(url: absolute, label: label, identity: before,
                     sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()), retained)
    }

    func confirmUnchanged(cancellable: Bool) throws {
        let current = try Self.capture(url, label: label, maximumBytes: UInt64(identity.size),
                                       cancellable: cancellable)
        guard current.identity == identity, current.sha256 == sha256 else {
            throw InferenceFailure.inputIntegrityChanged("\(label) identity or content changed.")
        }
    }

    private static func fileFailure(_ message: String) -> InferenceFailure {
        .invalidRequest("\(message): \(String(cString: strerror(errno)))")
    }
}

private extension Dictionary where Key == String, Value == AudioJSONValue {
    func string(_ key: String) throws -> String {
        guard let value = self[key] else { throw InferenceFailure.invalidRequest("Missing \(key).") }
        return try value.requiredString(context: key)
    }

    func int(_ key: String) throws -> Int64 {
        guard let value = self[key] else { throw InferenceFailure.invalidRequest("Missing \(key).") }
        return try value.requiredInteger(context: key)
    }
}
