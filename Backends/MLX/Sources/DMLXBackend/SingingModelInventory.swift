import CryptoKit
import Darwin
import DInference
import Foundation

struct SingingModelInventory: Sendable {
    static let requiredProviderHelpers = [
        "d_audio_contract.py", "d_singing_prepare.py", "d_singing_timing.py", "d_singing_qixuan.py",
    ]
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
        let protectedLocations = [python, provider, vendor, profileURL, bank, vocoder,
                                  python.deletingLastPathComponent(),
                                  provider.deletingLastPathComponent(),
                                  profileURL.deletingLastPathComponent()]
        guard protectedLocations.allSatisfy({
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
        for helper in requiredProviderHelpers {
            _ = try seal.addFile(provider.deletingLastPathComponent().appendingPathComponent(helper),
                                 label: "Singing provider helper \(helper)",
                                 maximumBytes: 16 * 1024 * 1024)
        }
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
        let validatedConfiguration = SingingBackendConfiguration(
            pythonExecutable: python, providerScript: provider, vendorDirectory: vendor,
            profileManifest: profileURL, artifactDirectory: artifacts,
            timeoutSeconds: configuration.timeoutSeconds,
            cancellationGraceSeconds: configuration.cancellationGraceSeconds)
        return Self(configuration: validatedConfiguration, profile: parsedProfile, bankDirectory: bank,
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
    private var directories: [SingingSealedDirectory] = []
    private var files: [SingingSealedFile] = []
    private var verificationChecks: [@Sendable (Bool) throws -> Void] = []

    init() {}

    mutating func addDirectory(_ url: URL, label: String) throws {
        directories.append(try SingingSealedDirectory.capture(url, label: label))
    }

    mutating func addVerification(_ check: @escaping @Sendable (Bool) throws -> Void) {
        verificationChecks.append(check)
    }

    @discardableResult
    mutating func addFile(_ url: URL, label: String, maximumBytes: UInt64?) throws -> SingingSealedFile {
        let value = try SingingSealedFile.capture(url, label: label, maximumBytes: maximumBytes,
                                                  cancellable: true)
        files.append(value)
        return value
    }

    mutating func addSmallFile(
        _ url: URL, label: String, maximumBytes: UInt64
    ) throws -> (SingingSealedFile, Data) {
        let value = try SingingSealedFile.captureData(
            url, label: label, maximumBytes: maximumBytes, cancellable: true)
        files.append(value.0)
        return value
    }

    @discardableResult
    mutating func addDeclaredFile(
        _ url: URL, file: SingingModelInventory.DeclaredFile, label: String
    ) throws -> SingingSealedFile {
        let value = try addFile(url, label: label, maximumBytes: file.byteCount)
        guard value.identity.size >= 0, UInt64(value.identity.size) == file.byteCount,
              value.sha256 == file.sha256 else {
            throw InferenceFailure.invalidRequest("Size or SHA-256 mismatch for \(label).")
        }
        return value
    }

    func confirmUnchanged(cancellable: Bool) throws {
        var observedIntegrityFailure: InferenceFailure?
        var firstUnknownFailure: Error?
        for directory in directories {
            if cancellable { try Task.checkCancellation() }
            do { try directory.confirmUnchanged() }
            catch let failure as InferenceFailure {
                if case .inputIntegrityChanged = failure, observedIntegrityFailure == nil {
                    observedIntegrityFailure = failure
                } else if firstUnknownFailure == nil { firstUnknownFailure = failure }
            } catch { if firstUnknownFailure == nil { firstUnknownFailure = error } }
        }
        for file in files {
            if cancellable { try Task.checkCancellation() }
            do { try file.confirmUnchanged(cancellable: cancellable) }
            catch let failure as InferenceFailure {
                if case .inputIntegrityChanged = failure, observedIntegrityFailure == nil {
                    observedIntegrityFailure = failure
                } else if firstUnknownFailure == nil { firstUnknownFailure = failure }
            } catch { if firstUnknownFailure == nil { firstUnknownFailure = error } }
        }
        for check in verificationChecks {
            if cancellable { try Task.checkCancellation() }
            do { try check(cancellable) }
            catch let failure as InferenceFailure {
                if case .inputIntegrityChanged = failure, observedIntegrityFailure == nil {
                    observedIntegrityFailure = failure
                } else if firstUnknownFailure == nil { firstUnknownFailure = failure }
            } catch { if firstUnknownFailure == nil { firstUnknownFailure = error } }
        }
        if let observedIntegrityFailure { throw observedIntegrityFailure }
        if let firstUnknownFailure { throw firstUnknownFailure }
    }
}

struct SingingStableIdentity: Sendable, Equatable {
    let device: Int64
    let inode: UInt64
    let fileType: UInt32

    init(_ identity: AudioFileSystem.Identity) {
        device = identity.device
        inode = identity.inode
        fileType = identity.mode & UInt32(S_IFMT)
    }
}

private struct SingingSealedDirectory: Sendable {
    let url: URL
    let label: String
    let identity: SingingStableIdentity

    static func capture(_ url: URL, label: String) throws -> Self {
        let absolute = try AudioFileSystem.absoluteLocal(url, label: label)
        let first = try directoryIdentity(absolute, label: label)
        let second = try directoryIdentity(absolute, label: label)
        guard first == second else {
            throw InferenceFailure.invalidRequest("\(label) changed while its named directory was sealed.")
        }
        return Self(url: absolute, label: label, identity: first)
    }

    func confirmUnchanged() throws {
        do {
            let current = try Self.directoryIdentity(url, label: label)
            guard current == identity else {
                throw InferenceFailure.inputIntegrityChanged("Protected \(label) identity changed.")
            }
        } catch let failure as InferenceFailure {
            if case .inputIntegrityChanged = failure { throw failure }
            if SingingSealedFile.observedUnsafePath(url, finalType: UInt32(S_IFDIR)) {
                throw InferenceFailure.inputIntegrityChanged("Protected \(label) disappeared or became unsafe.")
            }
            throw InferenceFailure.backendFailed(
                "Cannot complete post-drain directory verification for \(label): \(failure.localizedDescription)")
        }
    }

    private static func directoryIdentity(_ url: URL, label: String) throws -> SingingStableIdentity {
        let descriptor = try AudioFileSystem.openDirectory(url, label: label)
        var value = stat()
        let status = Darwin.fstat(descriptor, &value)
        let closeStatus = Darwin.close(descriptor)
        guard status == 0, closeStatus == 0 else {
            throw InferenceFailure.invalidRequest("Cannot identify or close \(label).")
        }
        return SingingStableIdentity(AudioFileSystem.Identity(value))
    }
}

struct SingingSealedFile: Sendable {
    private enum Phase { case admission, integrity }
    let url: URL
    let parentURL: URL
    let label: String
    let parentIdentity: SingingStableIdentity
    let identity: AudioFileSystem.Identity
    let sha256: String

    static func capture(
        _ url: URL, label: String, maximumBytes: UInt64?, cancellable: Bool,
        afterClose: (() throws -> Void)? = nil,
        beforeFinalObservation: (() throws -> Void)? = nil
    ) throws -> Self {
        try captureData(url, label: label, maximumBytes: maximumBytes, cancellable: cancellable,
                        retainData: false, phase: .admission, afterClose: afterClose,
                        beforeFinalObservation: beforeFinalObservation).0
    }

    static func captureData(
        _ url: URL, label: String, maximumBytes: UInt64, cancellable: Bool
    ) throws -> (Self, Data) {
        try captureData(url, label: label, maximumBytes: maximumBytes, cancellable: cancellable,
                        retainData: true, phase: .admission, afterClose: nil,
                        beforeFinalObservation: nil)
    }

    private static func captureData(
        _ url: URL, label: String, maximumBytes: UInt64?, cancellable: Bool,
        retainData: Bool, phase: Phase, afterClose: (() throws -> Void)?,
        beforeFinalObservation: (() throws -> Void)?
    ) throws -> (Self, Data) {
        let location = try split(url, label: label)
        let parent = try AudioFileSystem.openDirectory(location.parent, label: "parent of \(label)")
        var parentOpen = true
        var descriptorOpen = false
        var descriptor: Int32 = -1
        defer {
            if descriptorOpen { Darwin.close(descriptor) }
            if parentOpen { Darwin.close(parent) }
        }
        var parentValue = stat()
        guard Darwin.fstat(parent, &parentValue) == 0 else {
            throw InferenceFailure.invalidRequest("Cannot identify parent of \(label).")
        }
        let parentIdentity = SingingStableIdentity(AudioFileSystem.Identity(parentValue))
        descriptor = Darwin.openat(parent, location.name,
                                   O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw fileFailure("Cannot open \(label)")
        }
        descriptorOpen = true
        var beforeValue = stat()
        guard Darwin.fstat(descriptor, &beforeValue) == 0,
              beforeValue.st_mode & S_IFMT == S_IFREG else {
            throw InferenceFailure.invalidRequest("\(label) must be a regular nonsymlink file.")
        }
        let before = AudioFileSystem.Identity(beforeValue)
        guard before.size >= 0, maximumBytes.map({ UInt64(before.size) <= $0 }) ?? true else {
            throw change("\(label) exceeds its sealed size.", phase: phase)
        }
        var hash = SHA256(), retained = Data()
        if retainData { retained.reserveCapacity(Int(before.size)) }
        var remaining = before.size
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while remaining > 0 {
            if cancellable { try Task.checkCancellation() }
            let requested = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, requested) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 {
                var observed = stat()
                if Darwin.fstat(descriptor, &observed) == 0,
                   AudioFileSystem.Identity(observed) != before {
                    throw change("\(label) changed while its sealed bytes were read.", phase: phase)
                }
                throw unknown("Cannot read complete \(label)", phase: phase)
            }
            let chunk = Data(buffer.prefix(count)); hash.update(data: chunk)
            if retainData { retained.append(chunk) }
            remaining -= Int64(count)
        }
        try beforeFinalObservation?()
        var extra: UInt8 = 0
        var trailing: Int
        repeat { trailing = Darwin.read(descriptor, &extra, 1) } while trailing < 0 && errno == EINTR
        var afterValue = stat()
        let afterStatus = Darwin.fstat(descriptor, &afterValue)
        let fileClose = Darwin.close(descriptor)
        descriptorOpen = false
        let parentClose = Darwin.close(parent)
        parentOpen = false
        let observedChange = trailing > 0
            || (afterStatus == 0 && AudioFileSystem.Identity(afterValue) != before)
        if observedChange {
            throw change("\(label) changed while being sealed.", phase: phase)
        }
        guard trailing == 0, afterStatus == 0, fileClose == 0, parentClose == 0 else {
            throw unknown("Cannot finish reading or closing \(label)", phase: phase)
        }
        try afterClose?()
        let namedParent: SingingSealedDirectory
        do {
            namedParent = try SingingSealedDirectory.capture(location.parent, label: "parent of \(label)")
        } catch {
            if observedUnsafePath(location.parent, finalType: UInt32(S_IFDIR)) {
                throw change("Parent of \(label) disappeared or became unsafe after close.", phase: phase)
            }
            throw unknown("Cannot rebind parent of \(label): \(error.localizedDescription)", phase: phase)
        }
        guard namedParent.identity == parentIdentity else {
            throw change("Parent of \(label) was replaced after close.", phase: phase)
        }
        let named: AudioFileSystem.Identity
        do { named = try observedIdentity(location, label: label) }
        catch {
            if observedUnsafePath(location.url, finalType: UInt32(S_IFREG)) {
                throw change("Named \(label) disappeared or became unsafe after close.", phase: phase)
            }
            throw unknown("Cannot rebind named \(label): \(error.localizedDescription)", phase: phase)
        }
        guard named == before else {
            throw change("Named \(label) was replaced after close.", phase: phase)
        }
        return (Self(url: location.url, parentURL: location.parent, label: label,
                     parentIdentity: parentIdentity, identity: before,
                     sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()), retained)
    }

    func confirmUnchanged(
        cancellable: Bool, beforeFinalObservation: (() throws -> Void)? = nil
    ) throws {
        do {
            let currentParent = try SingingSealedDirectory.capture(parentURL, label: "parent of \(label)")
            guard currentParent.identity == parentIdentity else {
                throw InferenceFailure.inputIntegrityChanged("Parent of protected \(label) was replaced.")
            }
            let currentIdentity = try Self.observedIdentity(try Self.split(url, label: label), label: label)
            guard currentIdentity == identity else {
                throw InferenceFailure.inputIntegrityChanged("Protected \(label) identity, size, or type changed.")
            }
            let current = try Self.captureData(
                url, label: label, maximumBytes: UInt64(identity.size),
                cancellable: cancellable, retainData: false, phase: .integrity,
                afterClose: nil, beforeFinalObservation: beforeFinalObservation).0
            guard current.identity == identity, current.parentIdentity == parentIdentity,
                  current.sha256 == sha256 else {
                throw InferenceFailure.inputIntegrityChanged("Protected \(label) identity or content changed.")
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as InferenceFailure {
            if case .inputIntegrityChanged = failure { throw failure }
            if Self.observedUnsafePath(url, finalType: UInt32(S_IFREG)) {
                throw InferenceFailure.inputIntegrityChanged("Protected \(label) disappeared or became unsafe.")
            }
            throw InferenceFailure.backendFailed(
                "Cannot complete post-drain file verification for \(label): \(failure.localizedDescription)")
        }
    }

    static func observedUnsafePath(_ url: URL, finalType: UInt32) -> Bool {
        var current = ""
        let components = url.standardizedFileURL.path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current += "/" + component
            var value = stat()
            if Darwin.lstat(current, &value) != 0 {
                if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return true }
                return false
            }
            let kind = UInt32(value.st_mode & S_IFMT)
            if kind == UInt32(S_IFLNK) { return true }
            if index < components.count - 1, kind != UInt32(S_IFDIR) { return true }
            if index == components.count - 1, kind != finalType { return true }
        }
        return components.isEmpty
    }

    private static func split(_ url: URL, label: String) throws -> (url: URL, parent: URL, name: String) {
        let absolute = try AudioFileSystem.absoluteLocal(url, label: label)
        let components = absolute.path.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw InferenceFailure.invalidRequest("\(label) must name a regular file.")
        }
        return (absolute, URL(fileURLWithPath: "/" + components.dropLast().joined(separator: "/"),
                              isDirectory: true), name)
    }

    private static func observedIdentity(
        _ location: (url: URL, parent: URL, name: String), label: String
    ) throws -> AudioFileSystem.Identity {
        let parent = try AudioFileSystem.openDirectory(location.parent, label: "parent of \(label)")
        let descriptor = Darwin.openat(parent, location.name,
                                       O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            Darwin.close(parent)
            throw fileFailure("Cannot reopen named \(label)")
        }
        var value = stat()
        let status = Darwin.fstat(descriptor, &value)
        let fileClose = Darwin.close(descriptor), parentClose = Darwin.close(parent)
        guard status == 0, value.st_mode & S_IFMT == S_IFREG,
              fileClose == 0, parentClose == 0 else {
            throw InferenceFailure.invalidRequest("Cannot verify named regular file \(label).")
        }
        return AudioFileSystem.Identity(value)
    }

    private static func fileFailure(_ message: String) -> InferenceFailure {
        .invalidRequest("\(message): \(String(cString: strerror(errno)))")
    }

    private static func change(_ message: String, phase: Phase) -> InferenceFailure {
        switch phase {
        case .admission: .invalidRequest(message)
        case .integrity: .inputIntegrityChanged(message)
        }
    }

    private static func unknown(_ message: String, phase: Phase) -> InferenceFailure {
        let detail = message + ": " + String(cString: strerror(errno))
        switch phase {
        case .admission: .invalidRequest(detail)
        case .integrity: .backendFailed(detail)
        }
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
