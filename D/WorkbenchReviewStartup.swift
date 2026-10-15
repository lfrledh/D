import Darwin
import Foundation

/// App-private launch policy. No defaults, directories, services, or network are touched here.
enum WorkbenchLaunchContext: Sendable {
    static let markerKey = "DReviewLaunchMode"
    static let markerValue = "isolated-download-v1"
    static let current: Result<WorkbenchLaunchContext, Error> = Result {
        #if D_REVIEW_ONLY
        let required = true
        #else
        let required = false
        #endif
        #if DEBUG
        let supported = true
        #else
        let supported = false
        #endif
        return try parse(marker: Bundle.main.object(forInfoDictionaryKey: markerKey),
            environment: ProcessInfo.processInfo.environment, required: required, supported: supported)
    }

    case ordinary
    case uiTest(UUID)
    case review(Review)

    struct Review: Sendable {
        let session: UUID
        let root: URL
        let source: URL
    }

    struct Rejected: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "独立评审启动已拒绝；未初始化用户服务。 / Review startup refused; user services were not initialized.\n" + reason
        }
    }

    static func parse(marker: Any?, environment env: [String: String], required: Bool,
                      supported: Bool = true) throws -> Self {
        let hasDownloadContext = env["D_DOWNLOAD_REVIEW_ROOT"] != nil || env["D_DOWNLOAD_REVIEW_SOURCE"] != nil
        if marker == nil && !required && !hasDownloadContext {
            if supported, let token = env["D_UI_TEST_SESSION"], let id = UUID(uuidString: token) { return .uiTest(id) }
            return .ordinary
        }
        guard supported, let value = marker as? String, value == markerValue else {
            throw Rejected(reason: "评审包持久标记缺失、无效或不受支持。 / Missing, invalid, or unsupported bundle marker.")
        }
        guard env["D_AUDIO_DEPLOYMENT_CHECK"] == nil,
              env["D_AUDIO_PROBE_PYTHON"] == nil, env["D_AUDIO_PROBE_SHA256"] == nil else {
            throw Rejected(reason: "评审与部署检查上下文冲突。 / Conflicting review and deployment contexts.")
        }
        guard let token = env["D_UI_TEST_SESSION"], let id = UUID(uuidString: token),
              token == id.uuidString, let path = env["D_DOWNLOAD_REVIEW_ROOT"],
              path.hasPrefix("/Volumes/"), !path.contains("\0") else {
            throw Rejected(reason: "评审会话或根目录缺失/无效。 / Missing or invalid session/root.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.path == path, root.lastPathComponent == id.uuidString else {
            throw Rejected(reason: "评审目录与会话身份不一致。 / Root and session identities do not match.")
        }
        guard let address = env["D_DOWNLOAD_REVIEW_SOURCE"], let source = URL(string: address),
              let parts = URLComponents(url: source, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1",
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw Rejected(reason: "缺少有效的专用回环来源。 / Missing or invalid loopback source.")
        }
        return .review(Review(session: id, root: root, source: source))
    }

    var permitsDeploymentProbe: Bool {
        if case .uiTest = self { return true }
        return false
    }
}

/// Held for the admitted App lifetime, including shutdown. A second process cannot reach services.
final class WorkbenchReviewLease {
    private let descriptor: Int32

    init(root: URL) throws {
        let path = root.appendingPathComponent(".d-review-session.lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw WorkbenchLaunchContext.Rejected(reason: "评审独占锁无法打开。 / Cannot open review lease.") }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw WorkbenchLaunchContext.Rejected(reason: "评审目录正在使用或租约无效。 / Review folder is already in use or its lease is invalid.")
        }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }
}

@MainActor
enum WorkbenchReviewAdmission {
    /// Authorization is injected in tests; production supplies the native panel.
    /// The continuation is the only path to constructing writable services.
    static func admit(_ review: WorkbenchLaunchContext.Review,
                      authorize: (URL) async throws -> URL) async throws -> WorkbenchReviewLease {
        let selected = try await authorize(review.root)
        guard selected.standardizedFileURL == review.root,
              review.root.resolvingSymlinksInPath() == review.root else {
            throw WorkbenchLaunchContext.Rejected(reason: "授权目录不一致或为符号链接。 / Authorization does not match the canonical review root.")
        }
        try validateStorage(review)
        return try WorkbenchReviewLease(root: review.root)
    }

    static func validateStorage(_ review: WorkbenchLaunchContext.Review) throws {
        guard review.root.resolvingSymlinksInPath() == review.root else {
            throw WorkbenchLaunchContext.Rejected(reason: "Review root changed to a symbolic link.")
        }
        let marker = review.root.appendingPathComponent("download-review-fixture.json")
        let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4096,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any],
              object["task"] as? String == "D-DOWNLOAD-MANAGEMENT-01",
              object["session"] as? String == review.session.uuidString,
              object["fixtures"] as? String == "A/B/C 18 MiB each; no inference route" else {
            throw WorkbenchLaunchContext.Rejected(reason: "评审夹具标记缺失或身份不一致。 / Missing or conflicting review fixture marker.")
        }
        // Known service roots only: do not let a valid outer folder redirect a writer.
        // This is deliberately not a filesystem scan or a change to Store semantics.
        for relative in ["ModelLibrary", "ModelLibrary/index.json", "Quick Creations.dproject",
                         "shared-library.json", "Appearance", "Appearance/initial-preferences.json", "LanguagePacks", "AudioProcessAccess", "VideoProcessAccess",
                         "Files", "review-runtime.json"] {
            let child = review.root.appendingPathComponent(relative)
            guard child.resolvingSymlinksInPath().standardizedFileURL == child.standardizedFileURL else {
                throw WorkbenchLaunchContext.Rejected(reason: "评审服务路径含符号链接。 / Review service path contains a symbolic link: " + relative)
            }
            if let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw WorkbenchLaunchContext.Rejected(reason: "Review service path is a symbolic link: " + relative)
            }
        }
    }
}
