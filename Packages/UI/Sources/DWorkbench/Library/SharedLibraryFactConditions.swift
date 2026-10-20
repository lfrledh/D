import Foundation

/// Facts supplied by the owning projection, never inferred from editable user tags.
public struct SharedLibraryFactConditions: Codable, Sendable, Equatable {
    public var concepts: Set<String>
    public var producers: Set<String>
    public var consumers: Set<String>
    public var formats: Set<String>
    public init(concepts: Set<String> = [], producers: Set<String> = [], consumers: Set<String> = [], formats: Set<String> = []) {
        self.concepts = concepts; self.producers = producers; self.consumers = consumers; self.formats = formats
    }
    public var isEmpty: Bool { concepts.isEmpty && producers.isEmpty && consumers.isEmpty && formats.isEmpty }
    public func validate() throws {
        let values = Array(concepts) + Array(producers) + Array(consumers) + Array(formats)
        guard values.count <= 256, values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") }) else { throw SharedLibraryError.invalidProperty }
    }
    public func matches(_ facts: Self) -> Bool {
        (concepts.isEmpty || !concepts.isDisjoint(with: facts.concepts)) &&
        (producers.isEmpty || !producers.isDisjoint(with: facts.producers)) &&
        (consumers.isEmpty || !consumers.isDisjoint(with: facts.consumers)) &&
        (formats.isEmpty || !formats.isDisjoint(with: facts.formats))
    }
}

public enum SharedLibraryContentGroup: String, CaseIterable, Sendable {
    case text, image, video, audio, other
    public var kinds: Set<WorkflowDataKind> {
        switch self {
        case .text: [.text, .document]
        case .image: [.image, .images]
        case .video: [.video]
        case .audio: [.audio]
        case .other: Set(WorkflowDataKind.allCases).subtracting([.text, .document, .image, .images, .video, .audio])
        }
    }
}
