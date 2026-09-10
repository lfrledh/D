import DInference
import Foundation

/// AW1 editable creation options. Invalid/incomplete numeric input is saved verbatim;
/// submission validation creates a separate immutable AudioRequest.
public struct AudioCreationDraft: Codable, Sendable, Equatable {
    public var revision: UUID
    public var prompt: String
    public var operation: AudioOperation
    public var durationText: String
    public var seedText: String
    public var stepsText: String
    public var guidanceText: String
    public var strengthText: String
    public var editRegion: AudioFrameRange?
    public var rejectedAssetIDs: [UUID]

    public init(revision: UUID = UUID(), prompt: String = "", operation: AudioOperation = .generate,
                durationText: String = "6", seedText: String = "42", stepsText: String = "8",
                guidanceText: String = "1", strengthText: String = "0.5",
                editRegion: AudioFrameRange? = nil, rejectedAssetIDs: [UUID] = []) {
        self.revision = revision; self.prompt = prompt; self.operation = operation
        self.durationText = durationText; self.seedText = seedText; self.stepsText = stepsText
        self.guidanceText = guidanceText; self.strengthText = strengthText
        self.editRegion = editRegion; self.rejectedAssetIDs = rejectedAssetIDs
    }
}
