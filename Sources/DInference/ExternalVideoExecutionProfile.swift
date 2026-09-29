/// Pure request validation for external video adapter recipes. A valid value is not
/// evidence that model resources are installed or that an adapter can execute.
public enum ExternalVideoExecutionProfile: String, Sendable, Codable, CaseIterable {
    case h3BF16Full = "minimax-h3-fl2va-bf16-full-v1"
    case ltx23BF16Full = "ltx-2.3-dev-bf16-full-v1"
    case ltx25BF16Full = "ltx-2.5-dev-bf16-full-v1"

    public var reference: ExecutionProfileReference {
        ExecutionProfileReference(identifier: rawValue, revision: 1)
    }

    public func validate(_ request: VideoRequest) throws {
        try request.validate()
        guard request.executionProfile == reference else {
            throw InferenceFailure.invalidRequest("Unsupported external video profile or revision.")
        }

        switch self {
        case .h3BF16Full:
            guard case .some(.h3) = request.adapterOptions else {
                throw InferenceFailure.invalidRequest("H3 requires H3 adapter options.")
            }
            guard request.width % 32 == 0, request.height % 32 == 0,
                  request.width * request.height <= 768 * 1344,
                  (22...362).contains(request.frameCount),
                  (request.frameCount - 5) % 17 == 0,
                  Int64(request.frameRate.numerator) == 24 * Int64(request.frameRate.denominator),
                  (2...1000).contains(request.steps),
                  request.negativePrompt.isEmpty,
                  request.guidanceScale == 1, request.scheduleShift == 1 else {
                throw InferenceFailure.invalidRequest("Request does not match the full H3 FL2VA recipe.")
            }

        case .ltx23BF16Full, .ltx25BF16Full:
            guard case .some(.ltx(_, let spatiotemporalGuidance)) = request.adapterOptions else {
                throw InferenceFailure.invalidRequest("LTX requires LTX adapter options.")
            }
            guard request.width % 32 == 0, request.height % 32 == 0,
                  (request.frameCount - 1) % 8 == 0,
                  request.seed <= UInt64(UInt32.max),
                  request.scheduleShift == 1,
                  spatiotemporalGuidance.isFinite, spatiotemporalGuidance >= 0 else {
                throw InferenceFailure.invalidRequest("Request does not match the full LTX recipe.")
            }
        }
    }
}
