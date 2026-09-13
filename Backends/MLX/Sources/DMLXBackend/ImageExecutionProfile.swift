import DInference

/// Immutable, explicitly selected execution envelope for the pinned Klein 4B q8 model.
/// The scalable envelope describes shape adaptation only; it does not imply support
/// for another model size, quantization, scheduler, or text configuration.
public struct ImageExecutionProfile: Sendable, Hashable {
    let executionCapability: ImageExecutionCapability

    public var identifier: String { executionCapability.profile.identifier }
    public var minimumWidth: Int { executionCapability.minimumWidth }
    public var maximumWidth: Int { executionCapability.maximumWidth }
    public var minimumHeight: Int { executionCapability.minimumHeight }
    public var maximumHeight: Int { executionCapability.maximumHeight }
    public var dimensionMultiple: Int { executionCapability.dimensionMultiple }
    public var maximumPixelCount: UInt64 { executionCapability.maximumPixelCount }
    public var steps: Int { executionCapability.steps }
    public var guidanceScale: Float { executionCapability.guidanceScale }
    public var maximumTextTokens: Int { executionCapability.maximumTextTokens }

    public static let verified512 = ImageExecutionProfile(executionCapability: .verified512)
    public static let scalableKlein4B = ImageExecutionProfile(executionCapability: .scalableKlein4B)

    private init(executionCapability: ImageExecutionCapability) {
        self.executionCapability = executionCapability
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.executionCapability.profile == rhs.executionCapability.profile
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(executionCapability.profile)
    }

    func validate(_ request: ImageRequest) throws {
        try executionCapability.validate(request)
    }

    func resolvedCapability(for request: ImageRequest) throws -> ImageExecutionCapability {
        try executionCapability.resolvedCapability(for: request)
    }

    /// B1 established the 8 GiB estimate at 512 square. Larger shapes retain that
    /// base and conservatively add 1 GiB of workspace per additional 512-square
    /// pixel area, rounded upward. This is an estimate, not a measured OOM boundary.
    public func estimatedPeakBytes(width: Int, height: Int) throws -> UInt64 {
        try executionCapability.estimatedPeakBytes(width: width, height: height)
    }
}
