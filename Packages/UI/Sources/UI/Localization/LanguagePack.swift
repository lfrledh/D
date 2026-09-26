import Darwin
import Foundation

struct LanguagePack: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let locale: String
    let displayName: String
    let strings: [String: String]
}

enum LanguagePackLimits {
    static let maximumBytes = 512 * 1_024
    static let maximumEntries = 2_000
    static let maximumKeyLength = 160
    static let maximumValueLength = 4_096
}

enum LanguagePackValidationError: Error, LocalizedError, Equatable {
    case tooLarge
    case invalidUTF8
    case invalidJSON
    case unsupportedVersion(Int)
    case invalidLocale
    case invalidDisplayName
    case tooManyEntries
    case invalidKey(String)
    case valueTooLong(String)
    case invalidPlaceholder(String)
    case placeholderMismatch(String)
    case invalidLocalFile
    case nonLocalFile
    case changedWhileReading

    var errorDescription: String? {
        switch self {
        case .tooLarge: "The language pack exceeds 512 KiB."
        case .invalidUTF8: "The language pack must be UTF-8 JSON."
        case .invalidJSON: "The language pack is not valid JSON."
        case .unsupportedVersion(let version): "Unsupported language pack schema version: \(version)."
        case .invalidLocale: "The language pack locale is invalid."
        case .invalidDisplayName: "The language pack display name is invalid."
        case .tooManyEntries: "The language pack contains more than 2,000 strings."
        case .invalidKey(let key): "The language pack contains an invalid key: \(key)."
        case .valueTooLong(let key): "The language pack value is too long: \(key)."
        case .invalidPlaceholder(let key): "The language pack contains an invalid placeholder: \(key)."
        case .placeholderMismatch(let key): "The language pack placeholders do not match English: \(key)."
        case .invalidLocalFile: "The language pack must be a regular local file without symbolic links."
        case .nonLocalFile: "The language pack must be stored on a local volume."
        case .changedWhileReading: "The language pack changed while it was being read."
        }
    }
}

enum LanguagePackFileReader {
    static func read(from url: URL) throws -> Data {
        let components = try validatedComponents(for: url)
        let descriptor = try openReadOnly(components)
        defer { Darwin.close(descriptor) }

        var filesystem = statfs()
        guard Darwin.fstatfs(descriptor, &filesystem) == 0,
              filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw LanguagePackValidationError.nonLocalFile
        }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0 else {
            throw LanguagePackValidationError.invalidLocalFile
        }
        guard before.st_size <= Int64(LanguagePackLimits.maximumBytes) else {
            throw LanguagePackValidationError.tooLarge
        }

        let readLimit = LanguagePackLimits.maximumBytes + 1
        var data = Data()
        data.reserveCapacity(min(Int(before.st_size), LanguagePackLimits.maximumBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count < readLimit {
            let requested = min(buffer.count, readLimit - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw LanguagePackValidationError.invalidLocalFile }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= LanguagePackLimits.maximumBytes else {
            throw LanguagePackValidationError.tooLarge
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameReadState(before, after),
              after.st_size == Int64(data.count) else {
            throw LanguagePackValidationError.changedWhileReading
        }
        return data
    }

    private static func validatedComponents(for url: URL) throws -> [String] {
        guard url.isFileURL, url.baseURL == nil, url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil,
              url.host == nil || url.host == "",
              url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty,
              url.standardizedFileURL.path == url.path else {
            throw LanguagePackValidationError.invalidLocalFile
        }
        let components = String(url.path.dropFirst())
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." &&
                      !$0.contains("\\") && !$0.contains("\0")
              }) else {
            throw LanguagePackValidationError.invalidLocalFile
        }
        return components
    }

    private static func openReadOnly(_ components: [String]) throws -> Int32 {
        var current = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw LanguagePackValidationError.invalidLocalFile }

        for component in components.dropLast() {
            let next = Darwin.openat(current, component,
                                     O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(current)
            guard next >= 0 else { throw LanguagePackValidationError.invalidLocalFile }
            current = next
        }

        let descriptor = Darwin.openat(
            current,
            components.last!,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        Darwin.close(current)
        guard descriptor >= 0 else { throw LanguagePackValidationError.invalidLocalFile }
        return descriptor
    }

    private static func sameReadState(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev &&
            before.st_ino == after.st_ino &&
            before.st_mode == after.st_mode &&
            before.st_size == after.st_size &&
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec &&
            after.st_mode & S_IFMT == S_IFREG
    }
}

enum LanguagePackCodec {
    static func decode(_ data: Data, english: LanguagePack? = nil) throws -> LanguagePack {
        guard data.count <= LanguagePackLimits.maximumBytes else {
            throw LanguagePackValidationError.tooLarge
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw LanguagePackValidationError.invalidUTF8
        }
        let pack: LanguagePack
        do {
            pack = try JSONDecoder().decode(LanguagePack.self, from: Data(source.utf8))
        } catch {
            throw LanguagePackValidationError.invalidJSON
        }
        try validate(pack, english: english)
        return LanguagePack(
            schemaVersion: pack.schemaVersion,
            locale: try normalizedLocale(pack.locale),
            displayName: pack.displayName,
            strings: pack.strings
        )
    }

    static func validate(_ pack: LanguagePack, english: LanguagePack? = nil) throws {
        guard pack.schemaVersion == 1 else {
            throw LanguagePackValidationError.unsupportedVersion(pack.schemaVersion)
        }
        _ = try normalizedLocale(pack.locale)
        let trimmedName = pack.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, pack.displayName.count <= 160,
              !pack.displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LanguagePackValidationError.invalidDisplayName
        }
        guard pack.strings.count <= LanguagePackLimits.maximumEntries else {
            throw LanguagePackValidationError.tooManyEntries
        }
        for (key, value) in pack.strings {
            guard isNamedKey(key), key.count <= LanguagePackLimits.maximumKeyLength else {
                throw LanguagePackValidationError.invalidKey(key)
            }
            guard value.count <= LanguagePackLimits.maximumValueLength else {
                throw LanguagePackValidationError.valueTooLong(key)
            }
            let placeholders = try placeholderNames(in: value, key: key)
            if let englishValue = english?.strings[key] {
                let englishPlaceholders = try placeholderNames(in: englishValue, key: key)
                guard placeholders == englishPlaceholders else {
                    throw LanguagePackValidationError.placeholderMismatch(key)
                }
            }
        }
    }

    static func normalizedLocale(_ locale: String) throws -> String {
        guard !locale.isEmpty, locale.count <= 64, locale.first != "-", locale.last != "-",
              !locale.contains("--"), locale.utf8.allSatisfy({ byte in
                  (65 ... 90).contains(byte) || (97 ... 122).contains(byte) ||
                  (48 ... 57).contains(byte) || byte == 45
              }) else {
            throw LanguagePackValidationError.invalidLocale
        }
        let parts = locale.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let language = parts.first, (2 ... 8).contains(language.count),
              language.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) }) else {
            throw LanguagePackValidationError.invalidLocale
        }
        return parts.enumerated().map { index, part in
            if index == 0 { return part.lowercased() }
            if part.count == 4, part.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) }) {
                return part.prefix(1).uppercased() + part.dropFirst().lowercased()
            }
            if part.count == 2, part.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) }) {
                return part.uppercased()
            }
            return part.lowercased()
        }.joined(separator: "-")
    }

    static func placeholderNames(in value: String, key: String) throws -> Set<String> {
        var names: Set<String> = []
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "{" || character == "}" else {
                index = value.index(after: index)
                continue
            }
            guard character == "{", let close = value[index...].firstIndex(of: "}") else {
                throw LanguagePackValidationError.invalidPlaceholder(key)
            }
            let nameStart = value.index(after: index)
            let name = String(value[nameStart..<close])
            guard isPlaceholderName(name), !name.contains("{") else {
                throw LanguagePackValidationError.invalidPlaceholder(key)
            }
            names.insert(name)
            index = value.index(after: close)
        }
        return names
    }

    static func render(_ template: String, arguments: [String: String]) -> String {
        guard !arguments.isEmpty else { return template }
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "{", let close = template[index...].firstIndex(of: "}") else {
                result.append(template[index])
                index = template.index(after: index)
                continue
            }
            let nameStart = template.index(after: index)
            let name = String(template[nameStart..<close])
            if isPlaceholderName(name), let replacement = arguments[name] {
                result.append(replacement)
            } else {
                result.append(contentsOf: template[index...close])
            }
            index = template.index(after: close)
        }
        return result
    }

    private static func isNamedKey(_ key: String) -> Bool {
        guard let first = key.utf8.first,
              (65 ... 90).contains(first) || (97 ... 122).contains(first) || first == 95,
              key.last != ".", !key.contains("..") else { return false }
        return key.utf8.allSatisfy { byte in
            (65 ... 90).contains(byte) || (97 ... 122).contains(byte) ||
            (48 ... 57).contains(byte) || byte == 46 || byte == 95 || byte == 45
        }
    }

    private static func isPlaceholderName(_ name: String) -> Bool {
        guard let first = name.utf8.first,
              (65 ... 90).contains(first) || (97 ... 122).contains(first) || first == 95 else { return false }
        return name.utf8.dropFirst().allSatisfy { byte in
            (65 ... 90).contains(byte) || (97 ... 122).contains(byte) ||
            (48 ... 57).contains(byte) || byte == 95 || byte == 45 || byte == 46
        }
    }
}
