import Foundation

/// Explicit Wan video parameter bundles for newly created nodes and user-invoked inspector actions.
/// Applying a preset changes only the seven listed generation parameters; it never starts a run.
public struct WorkflowVideoPreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let frameRate: Int
    public let steps: Int
    public let guidance: Double
    public let scheduleShift: Double

    public init(
        id: String,
        width: Int,
        height: Int,
        frameCount: Int,
        frameRate: Int,
        steps: Int,
        guidance: Double,
        scheduleShift: Double
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.steps = steps
        self.guidance = guidance
        self.scheduleShift = scheduleShift
    }

    public var parameters: [String: WorkflowScalar] {
        [
            "width": .integer(width),
            "height": .integer(height),
            "frameCount": .integer(frameCount),
            "frameRate": .integer(frameRate),
            "steps": .integer(steps),
            "guidance": .decimal(guidance),
            "scheduleShift": .decimal(scheduleShift),
        ]
    }

    /// Returns a value replacement only for the video operation. Unknown and future parameters
    /// remain byte-for-byte represented by their existing scalar values.
    public func applying(to node: WorkflowNode) -> WorkflowNode? {
        guard node.operationID == "d.video.generate" else { return nil }
        var result = node
        for (key, value) in parameters { result.parameters[key] = value }
        return result
    }
}

public enum WorkflowVideoPresets {
    /// Fast wiring check only; not an ordinary quality recommendation.
    public static let connectivity = WorkflowVideoPreset(
        id: "connectivity", width: 256, height: 256, frameCount: 17, frameRate: 16,
        steps: 4, guidance: 5, scheduleShift: 5
    )

    /// Default for newly created video nodes and the newly created E04 example.
    public static let fullPreview = WorkflowVideoPreset(
        id: "fullPreview", width: 320, height: 192, frameCount: 17, frameRate: 16,
        steps: 50, guidance: 6, scheduleShift: 8
    )

    /// Official Wan 480p starting geometry and sampling values; not locally verified this round.
    public static let official480p = WorkflowVideoPreset(
        id: "official480p", width: 832, height: 480, frameCount: 81, frameRate: 16,
        steps: 50, guidance: 6, scheduleShift: 8
    )

    public static let all: [WorkflowVideoPreset] = [connectivity, fullPreview, official480p]
}
