import CryptoKit
import Foundation

/// Annotation ownership only. No field is written into a frozen run or its values.
/// Canonical encoding includes the entire value and call path; a content match in
/// another run/instance/candidate never shares this key. No display strings enter it.
public struct WorkflowValueIdentity: Sendable, Equatable {
    public let storageKey: String
    public init(projectID: UUID, instanceID: UUID, call: WorkflowCallReference, port: String,
                value: WorkflowValue, candidateID: UUID? = nil, itemID: String? = nil, sourceVersion: String? = nil) throws {
        struct Payload: Encodable {
            let version: Int
            let project: UUID
            let instance: UUID
            let call: WorkflowCallReference
            let port: String
            let candidate: UUID?
            let itemID: String?
            let sourceVersion: String?
            let value: WorkflowValue
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Payload(version: 1, project: projectID, instance: instanceID,
            call: call, port: port, candidate: candidateID, itemID: itemID, sourceVersion: sourceVersion, value: value))
        storageKey = "runtime-value-v1:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public static func isStorageKey(_ key: String) -> Bool {
        let prefix = "runtime-value-v1:"
        return key.hasPrefix(prefix) && key.utf8.count == prefix.utf8.count + 64
            && key.dropFirst(prefix.count).allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

public struct WorkflowValueAnnotation: Codable, Sendable, Equatable {
    public var name: String
    public var note: String
    public var favorite: Bool
    public init(name: String, note: String = "", favorite: Bool = false) {
        self.name = name; self.note = note; self.favorite = favorite
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.note.utf8.elementsEqual(rhs.note.utf8) && lhs.favorite == rhs.favorite
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 256 else { throw SharedLibraryError.invalidName }
        guard note.utf8.count <= 16_384 else { throw SharedLibraryError.limitExceeded("result note exceeds 16 KiB") }
    }
}
