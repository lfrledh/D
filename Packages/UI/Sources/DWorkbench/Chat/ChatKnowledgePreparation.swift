import Darwin
import Foundation

/// A bounded, nonrecursive view of one directory explicitly selected by the caller.
/// This does not acquire a security scope, read document contents, or import assets.
public struct ChatKnowledgeDirectoryInventory: Sendable {
    public enum InventoryError: Swift.Error, LocalizedError, Equatable {
        case invalidDirectory
        case invalidMaximumEntries
        case directoryUnavailable(String)
        case directoryChanged
        case tooManyEntries(Int)
        case entryUnavailable(String)
        case entryChanged(String)

        public var errorDescription: String? {
            switch self {
            case .invalidDirectory: "Select an absolute local directory without symbolic links."
            case .invalidMaximumEntries: "The directory entry limit must be greater than zero."
            case .directoryUnavailable(let reason): "The selected directory is unavailable: \(reason)"
            case .directoryChanged: "The selected directory was replaced; select it again."
            case .tooManyEntries(let maximum): "The selected directory has more than \(maximum) entries; choose a smaller directory."
            case .entryUnavailable(let name): "The selected file is missing or unreadable: \(name)"
            case .entryChanged(let name): "The selected file changed since inspection: \(name)"
            }
        }
    }

    fileprivate struct Identity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(truncatingIfNeeded: value.st_dev)
            inode = UInt64(truncatingIfNeeded: value.st_ino)
            size = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }

        func sameFile(as other: Self) -> Bool { device == other.device && inode == other.inode }
    }

    public struct Entry: Identifiable, Sendable {
        /// Stable within the selected path; the identity snapshot below detects replacement.
        public var id: URL { url }
        public let url: URL
        public let name: String
        public let byteCount: Int64
        private let directoryURL: URL
        private let directoryIdentity: Identity
        private let fileIdentity: Identity

        fileprivate init(url: URL, name: String, directoryURL: URL,
                         directoryIdentity: Identity, fileIdentity: Identity) {
            self.url = url
            self.name = name
            self.byteCount = fileIdentity.size
            self.directoryURL = directoryURL
            self.directoryIdentity = directoryIdentity
            self.fileIdentity = fileIdentity
        }

        /// Recheck the selected path just before an import. ProjectStore's own import
        /// remains authoritative: a later URL-based read can still race with a rename.
        public func validateUnchanged() throws {
            let directory: Int32
            do { directory = try ChatKnowledgeDirectoryInventory.openSelectedDirectory(directoryURL) }
            catch { throw InventoryError.directoryChanged }
            defer { Darwin.close(directory) }
            var directoryStat = stat()
            guard fstat(directory, &directoryStat) == 0,
                  directoryIdentity.sameFile(as: Identity(directoryStat)) else {
                throw InventoryError.directoryChanged
            }
            var listedStat = stat()
            guard fstatat(directory, name, &listedStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw InventoryError.entryUnavailable(name)
            }
            guard listedStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  Identity(listedStat) == fileIdentity else { throw InventoryError.entryChanged(name) }
            let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else {
                if errno == ELOOP || errno == ENOTDIR { throw InventoryError.entryChanged(name) }
                throw InventoryError.entryUnavailable(name)
            }
            defer { Darwin.close(file) }
            var fileStat = stat()
            guard fstat(file, &fileStat) == 0 else { throw InventoryError.entryUnavailable(name) }
            guard fileStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  Identity(fileStat) == fileIdentity else { throw InventoryError.entryChanged(name) }
        }

    }

    public let entries: [Entry]
    /// Direct children omitted from import, each with a reason; no child is descended into.
    public let excluded: [String]

    /// Counts *all* direct children, including unsupported files, against maximumEntries.
    /// Exceeding the limit fails rather than returning a partial directory view.
    public static func inspect(_ directory: URL, maximumEntries: Int = 128) throws -> Self {
        guard maximumEntries > 0 else { throw InventoryError.invalidMaximumEntries }
        let fd = try openSelectedDirectory(directory)
        defer { Darwin.close(fd) }
        var rootStat = stat()
        guard fstat(fd, &rootStat) == 0 else {
            throw InventoryError.directoryUnavailable("Cannot inspect directory identity.")
        }
        let rootIdentity = Identity(rootStat)
        let enumerationFD = dup(fd)
        guard enumerationFD >= 0 else {
            throw InventoryError.directoryUnavailable("Cannot open directory enumeration.")
        }
        guard let stream = fdopendir(enumerationFD) else {
            Darwin.close(enumerationFD)
            throw InventoryError.directoryUnavailable("Cannot enumerate the selected directory.")
        }
        defer { closedir(stream) }
        var found: [Entry] = []
        var excluded: [String] = []
        var count = 0
        while true {
            errno = 0
            guard let child = readdir(stream) else {
                guard errno == 0 else {
                    throw InventoryError.directoryUnavailable("Directory enumeration failed: \(String(cString: strerror(errno)))")
                }
                break
            }
            let name: String? = withUnsafePointer(to: child.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: child.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw InventoryError.directoryUnavailable("A filename is not valid UTF-8.") }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= maximumEntries else { throw InventoryError.tooManyEntries(maximumEntries) }
            var listedStat = stat()
            guard fstatat(fd, name, &listedStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw InventoryError.entryUnavailable(name)
            }
            let kind = listedStat.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) { excluded.append("\(name): symbolic link"); continue }
            if kind == mode_t(S_IFDIR) { excluded.append("\(name): directory or package"); continue }
            guard kind == mode_t(S_IFREG) else { excluded.append("\(name): not a regular file"); continue }
            let ext = (name as NSString).pathExtension.lowercased()
            guard DocumentTextExtractor.supportsPlainText(fileExtension: ext) || ext == "pdf" || ext == "docx" else {
                excluded.append("\(name): unsupported file type")
                continue
            }
            // Open without following a replacement link. No content bytes are read.
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw InventoryError.entryUnavailable(name) }
            var openedStat = stat()
            let inspected = fstat(file, &openedStat) == 0
            Darwin.close(file)
            guard inspected else { throw InventoryError.entryUnavailable(name) }
            guard openedStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  Identity(listedStat) == Identity(openedStat) else {
                throw InventoryError.entryChanged(name)
            }
            found.append(Entry(url: directory.appendingPathComponent(name, isDirectory: false), name: name,
                               directoryURL: directory, directoryIdentity: rootIdentity,
                               fileIdentity: Identity(openedStat)))
        }
        var finalStat = stat()
        guard fstat(fd, &finalStat) == 0, Identity(finalStat) == rootIdentity else {
            throw InventoryError.directoryChanged
        }
        // Swift's lexicographic String order is deterministic and preserves each filename.
        return Self(entries: found.sorted { $0.name < $1.name }, excluded: excluded.sorted())
    }

    fileprivate static func openSelectedDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.path.hasPrefix("/"), url.standardizedFileURL.path == url.path else {
            throw InventoryError.invalidDirectory
        }
        if url.path == "/" {
            let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw InventoryError.directoryUnavailable(String(cString: strerror(errno))) }
            return root
        }
        let components: [String]
        do { components = try ProjectFiles.components(String(url.path.dropFirst())) }
        catch { throw InventoryError.invalidDirectory }
        let parent: Int32
        do { parent = try ProjectFiles.openDirectory(url.deletingLastPathComponent()) }
        catch { throw InventoryError.directoryUnavailable(String(describing: error)) }
        defer { Darwin.close(parent) }
        let fd = openat(parent, components[components.count - 1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw InventoryError.directoryUnavailable(String(cString: strerror(errno))) }
        return fd
    }
}

/// Optional model-assisted ordering of already frozen lexical excerpts.
/// Callers can use the input order directly for zero or one excerpt; parse still
/// requires a complete JSON object if a model is invoked. This owns no model.
public enum ChatKnowledgeReranking {
    public enum RerankingError: Swift.Error, LocalizedError, Equatable {
        case tooManyExcerpts
        case queryTooLarge
        case inputTooLarge
        case duplicateExcerptID
        case invalidOrder

        public var errorDescription: String? {
            switch self {
            case .tooManyExcerpts: "Reranking accepts at most 16 excerpts."
            case .queryTooLarge: "The reranking query exceeds 4096 UTF-8 bytes."
            case .inputTooLarge: "The reranking prompt exceeds 262144 UTF-8 bytes."
            case .duplicateExcerptID: "The supplied excerpts contain duplicate IDs."
            case .invalidOrder: "The reranking order must contain every supplied ID exactly once."
            }
        }
    }

    private static func validateInputs(query: String? = nil, excerpts: [ChatKnowledgeExcerpt]) throws {
        guard excerpts.count <= 16 else { throw RerankingError.tooManyExcerpts }
        if let query, query.utf8.count > 4_096 { throw RerankingError.queryTooLarge }
        guard Set(excerpts.map(\.id)).count == excerpts.count else { throw RerankingError.duplicateExcerptID }
        for excerpt in excerpts { try excerpt.validate() }
    }

    /// JSON data body for a caller-owned text model. It preserves all input text and
    /// identity fields; exceeding either byte limit is an explicit error.
    public static func prepare(query: String, excerpts: [ChatKnowledgeExcerpt]) throws -> String {
        try validateInputs(query: query, excerpts: excerpts)
        let records: [[String: Any]] = excerpts.map { excerpt in
            ["id": excerpt.id.uuidString, "name": excerpt.name, "text": excerpt.text,
             "projectID": excerpt.source.projectID.uuidString,
             "sourceID": excerpt.source.assetID.uuidString,
             "version": excerpt.source.version.uuidString,
             "sourceSHA256": excerpt.source.sha256,
             "utf16Offset": excerpt.utf16Offset, "utf16Length": excerpt.utf16Length,
             "page": excerpt.page.map { $0 as Any } ?? NSNull(),
             "line": excerpt.line.map { $0 as Any } ?? NSNull()]
        }
        let body: [String: Any] = [
            "instruction": "Return one JSON object with only an order array containing each excerpt id exactly once, ranked most relevant first. Do not rewrite excerpts.",
            "query": query, "excerpts": records
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard data.count <= 262_144 else { throw RerankingError.inputTooLarge }
        guard let result = String(data: data, encoding: .utf8) else { throw RerankingError.inputTooLarge }
        return result
    }

    /// Accepts exactly {"order":[UUID,...]}; returns original values in that order.
    /// The shared structured parser rejects fences, trailing text, duplicate keys,
    /// unknown fields, and wrong JSON types before ID membership is checked.
    public static func parse(_ output: String, excerpts: [ChatKnowledgeExcerpt]) throws -> [ChatKnowledgeExcerpt] {
        try validateInputs(excerpts: excerpts)
        let schema = WorkflowDataSchema.record([WorkflowRecordField("order", .list(.text))])
        let datum = try WorkflowStructuredText.parse(output, as: schema)
        guard let items = datum.fields?["order"]?.items, items.count == excerpts.count else {
            throw RerankingError.invalidOrder
        }
        let frozen = Dictionary(uniqueKeysWithValues: excerpts.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var ordered: [ChatKnowledgeExcerpt] = []
        for item in items {
            guard let value = item.value.text, let id = UUID(uuidString: value),
                  id.uuidString == value.uppercased(), seen.insert(id).inserted,
                  let original = frozen[id] else { throw RerankingError.invalidOrder }
            ordered.append(original)
        }
        return ordered
    }
}
