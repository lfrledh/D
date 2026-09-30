/// Typed image execution envelopes. A capability records requested constraints;
/// admission still requires a matching backend and a verified local installation.
public struct ImageExecutionCapability: Sendable, Equatable {
    public let profile: ExecutionProfileReference
    public let minimumWidth: Int
    public let maximumWidth: Int
    public let minimumHeight: Int
    public let maximumHeight: Int
    public let dimensionMultiple: Int
    public let maximumPixelCount: UInt64
    public let steps: Int
    public let guidanceScale: Float
    public let maximumTextTokens: Int
    public let contract: ExecutionContractDescription

    public static let verified512 = ImageExecutionCapability(
        profile: ExecutionProfileReference(identifier: "verified512", revision: 1),
        minimumWidth: 512, maximumWidth: 512,
        minimumHeight: 512, maximumHeight: 512,
        dimensionMultiple: 32, maximumPixelCount: 512 * 512,
        steps: 4, guidanceScale: 1, maximumTextTokens: 512)

    public static let scalableKlein4B = ImageExecutionCapability(
        profile: ExecutionProfileReference(identifier: "scalableKlein4B", revision: 1),
        minimumWidth: 256, maximumWidth: 2048,
        minimumHeight: 256, maximumHeight: 2048,
        dimensionMultiple: 32, maximumPixelCount: 2048 * 2048,
        steps: 4, guidanceScale: 1, maximumTextTokens: 512)

    /// Explicit identity makes older hosts reject, rather than ignore, reference input.
    public static let referenceKlein4B = ImageExecutionCapability(
        profile: ExecutionProfileReference(identifier: "referenceKlein4B", revision: 1),
        minimumWidth: 256, maximumWidth: 2048,
        minimumHeight: 256, maximumHeight: 2048,
        dimensionMultiple: 32, maximumPixelCount: 2048 * 2048,
        steps: 4, guidanceScale: 1, maximumTextTokens: 512)

    /// BF16 FLUX.2-dev envelope for a host with sufficient memory. The 512 token
    /// field is Vendor's processor fallback; a pinned tokenizer config must be
    /// checked before activation. This value alone does not enable a backend.
    public static let flux2Dev = ImageExecutionCapability(
        profile: ExecutionProfileReference(identifier: "flux2-dev-bf16-v1", revision: 1),
        minimumWidth: 256, maximumWidth: 2048,
        minimumHeight: 256, maximumHeight: 2048,
        dimensionMultiple: 16, maximumPixelCount: 2048 * 2048,
        steps: 1, guidanceScale: 0, maximumTextTokens: 512)

    public var supportsReferenceImage: Bool {
        self == .referenceKlein4B || self == .scalableKlein4B || self == .flux2Dev
    }

    private init(profile: ExecutionProfileReference,
                 minimumWidth: Int, maximumWidth: Int,
                 minimumHeight: Int, maximumHeight: Int,
                 dimensionMultiple: Int, maximumPixelCount: UInt64,
                 steps: Int, guidanceScale: Float, maximumTextTokens: Int) {
        self.profile = profile
        self.minimumWidth = minimumWidth
        self.maximumWidth = maximumWidth
        self.minimumHeight = minimumHeight
        self.maximumHeight = maximumHeight
        self.dimensionMultiple = dimensionMultiple
        self.maximumPixelCount = maximumPixelCount
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.maximumTextTokens = maximumTextTokens
        contract = ExecutionContractDescription(
            operationID: profile.identifier == "referenceKlein4B" ? "image.referenceEdit" :
                (profile.identifier == "flux2-dev-bf16-v1" ? "image.flux2Dev" : "image.generate"),
            inputRoles: profile.identifier == "referenceKlein4B" ? [.prompt, .image] : [.prompt], outputRole: .image,
            controlFidelity: .approximate)
    }

    /// Validates both the requested profile identity and the strict resolved envelope.
    /// A nil profile is the legacy path and resolves to this immutable host capability.
    public func validate(_ request: ImageRequest) throws {
        _ = try resolvedCapability(for: request)
    }

    /// Pure request resolution used by adapters that must record the actual profile.
    /// The scalable host contains the verified 512 profile; the reverse is forbidden.
    public func resolvedCapability(for request: ImageRequest) throws -> ImageExecutionCapability {
        let resolved: ImageExecutionCapability
        if let requestedProfile = request.executionProfile {
            if requestedProfile == Self.verified512.profile {
                resolved = .verified512
            } else if requestedProfile == Self.scalableKlein4B.profile {
                resolved = .scalableKlein4B
            } else if requestedProfile == Self.referenceKlein4B.profile {
                resolved = .referenceKlein4B
            } else if requestedProfile == Self.flux2Dev.profile {
                resolved = .flux2Dev
            } else {
                throw InferenceFailure.invalidRequest("Unsupported image execution profile or revision.")
            }
        } else {
            resolved = self
        }

        guard (self == .scalableKlein4B && resolved != .flux2Dev) || self == resolved ||
              (self != .flux2Dev && resolved == .verified512) else {
            throw InferenceFailure.invalidRequest(
                "The verified 512 image host cannot execute the scalable Klein 4B profile.")
        }
        try resolved.validateResolved(request)
        return resolved
    }

    private func validateResolved(_ request: ImageRequest) throws {
        let references = try request.resolvedReferences()
        if self == .referenceKlein4B {
            guard request.executionProfile == Self.referenceKlein4B.profile, !references.isEmpty else {
                throw InferenceFailure.invalidRequest("The reference profile requires at least one explicit reference image.")
            }
        } else if self != .flux2Dev && !references.isEmpty {
            throw InferenceFailure.invalidRequest("A reference image requires the referenceKlein4B profile.")
        }
        _ = try validatedPixelCount(width: request.width, height: request.height)
        if self == .flux2Dev {
            guard request.executionProfile == Self.flux2Dev.profile,
                  request.steps >= 1, request.guidanceScale.isFinite,
                  request.guidanceScale >= 0 else {
                throw InferenceFailure.invalidRequest("FLUX.2-dev requires at least one step and finite nonnegative guidance.")
            }
            return
        }
        guard request.steps == steps, request.guidanceScale.isFinite,
              request.guidanceScale == guidanceScale else {
            if self == .verified512 {
                throw InferenceFailure.invalidRequest(
                    "This image backend supports only 512 x 512, 4 steps, guidance 1.")
            }
            throw InferenceFailure.invalidRequest(
                "The scalable Klein 4B profile requires 4 steps and guidance 1.")
        }
    }

    private func validatedPixelCount(width: Int, height: Int) throws -> UInt64 {
        guard width >= minimumWidth, width <= maximumWidth,
              height >= minimumHeight, height <= maximumHeight,
              width.isMultiple(of: dimensionMultiple),
              height.isMultiple(of: dimensionMultiple) else {
            if self == .verified512 {
                throw InferenceFailure.invalidRequest(
                    "This image backend supports only 512 x 512, 4 steps, guidance 1.")
            }
            throw InferenceFailure.invalidRequest(
                "The scalable Klein 4B profile requires width and height from 256 through 2048 in multiples of 32.")
        }
        let (pixelCount, overflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !overflow, pixelCount <= maximumPixelCount else {
            throw InferenceFailure.invalidRequest("The requested image area exceeds the execution profile limit.")
        }
        return pixelCount
    }

    /// B1 established the 8 GiB estimate at 512 square. Larger shapes retain that
    /// base and conservatively add 1 GiB of workspace per additional 512-square
    /// pixel area, rounded upward. This is an estimate, not a measured OOM boundary.
    public func estimatedPeakBytes(width: Int, height: Int) throws -> UInt64 {
        let pixelCount = try validatedPixelCount(width: width, height: height)
        let baselinePixels = UInt64(512 * 512)
        // The official BF16 Dev weights alone occupy about 105.058 GiB. This
        // 128 GiB planning floor is deliberately above that weight footprint.
        let baselineBytes = (self == .flux2Dev ? UInt64(128) : UInt64(8)) * 1024 * 1024 * 1024
        let workspacePerBaselineArea = UInt64(1024 * 1024 * 1024)
        guard pixelCount > baselinePixels else { return baselineBytes }

        let additionalPixels = pixelCount - baselinePixels
        let wholeAreas = additionalPixels / baselinePixels
        let partialAreaPixels = additionalPixels % baselinePixels
        let (wholeWorkspace, wholeOverflow) = wholeAreas.multipliedReportingOverflow(
            by: workspacePerBaselineArea)
        let (partialProduct, partialOverflow) = partialAreaPixels.multipliedReportingOverflow(
            by: workspacePerBaselineArea)
        guard !wholeOverflow, !partialOverflow else {
            throw InferenceFailure.invalidRequest("The image resource estimate exceeds UInt64 capacity.")
        }
        let partialQuotient = partialProduct / baselinePixels
        let partialWorkspace = partialQuotient
            + (partialProduct.isMultiple(of: baselinePixels) ? 0 : 1)
        let (workspace, workspaceOverflow) = wholeWorkspace.addingReportingOverflow(partialWorkspace)
        let (estimate, estimateOverflow) = baselineBytes.addingReportingOverflow(workspace)
        guard !workspaceOverflow, !estimateOverflow else {
            throw InferenceFailure.invalidRequest("The image resource estimate exceeds UInt64 capacity.")
        }
        return estimate
    }

    /// Conservative incremental reference encoding/attention estimate, not a
    /// reference-count cap. Every ordered input contributes its own area.
    public func estimatedPeakBytes(for request: ImageRequest) throws -> UInt64 {
        try validateResolved(request)
        let baseline = try estimatedPeakBytes(width: request.width, height: request.height)
        var estimate = baseline
        for reference in try request.resolvedReferences() {
            let pixels = UInt64(reference.width) * UInt64(reference.height)
            let areas = (pixels + 512 * 512 - 1) / (512 * 512)
            let (increment, multiplyOverflow) = areas.multipliedReportingOverflow(by: 1024 * 1024 * 1024)
            let (total, addOverflow) = estimate.addingReportingOverflow(increment)
            guard !multiplyOverflow, !addOverflow else {
                throw InferenceFailure.invalidRequest("The image reference resource estimate exceeds UInt64 capacity.")
            }
            estimate = total
        }
        return estimate
    }
}
