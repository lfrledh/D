import DInference
import Foundation

/// Immutable, explicitly selected execution envelope for the pinned Klein 4B q8 model.
/// The scalable envelope describes shape adaptation only; it does not imply support
/// for another model size, quantization, scheduler, or text configuration.
public struct ImageExecutionProfile: Sendable, Hashable {
    public let identifier: String
    public let minimumWidth: Int
    public let maximumWidth: Int
    public let minimumHeight: Int
    public let maximumHeight: Int
    public let dimensionMultiple: Int
    public let maximumPixelCount: UInt64
    public let steps: Int
    public let guidanceScale: Float
    public let maximumTextTokens: Int

    public static let verified512 = ImageExecutionProfile(
        identifier: "verified512",
        minimumWidth: 512, maximumWidth: 512,
        minimumHeight: 512, maximumHeight: 512,
        dimensionMultiple: 32, maximumPixelCount: 512 * 512,
        steps: 4, guidanceScale: 1, maximumTextTokens: 512)

    public static let scalableKlein4B = ImageExecutionProfile(
        identifier: "scalableKlein4B",
        minimumWidth: 256, maximumWidth: 2048,
        minimumHeight: 256, maximumHeight: 2048,
        dimensionMultiple: 32, maximumPixelCount: 2048 * 2048,
        steps: 4, guidanceScale: 1, maximumTextTokens: 512)

    private init(identifier: String,
                 minimumWidth: Int, maximumWidth: Int,
                 minimumHeight: Int, maximumHeight: Int,
                 dimensionMultiple: Int, maximumPixelCount: UInt64,
                 steps: Int, guidanceScale: Float, maximumTextTokens: Int) {
        self.identifier = identifier
        self.minimumWidth = minimumWidth
        self.maximumWidth = maximumWidth
        self.minimumHeight = minimumHeight
        self.maximumHeight = maximumHeight
        self.dimensionMultiple = dimensionMultiple
        self.maximumPixelCount = maximumPixelCount
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.maximumTextTokens = maximumTextTokens
    }

    func validate(_ request: ImageRequest) throws {
        _ = try validatedPixelCount(request)
    }

    private func validatedPixelCount(_ request: ImageRequest) throws -> UInt64 {
        guard request.width >= minimumWidth, request.width <= maximumWidth,
              request.height >= minimumHeight, request.height <= maximumHeight,
              request.width.isMultiple(of: dimensionMultiple),
              request.height.isMultiple(of: dimensionMultiple) else {
            if self == .verified512 {
                throw InferenceFailure.invalidRequest("This image backend supports only 512 x 512, 4 steps, guidance 1.")
            }
            throw InferenceFailure.invalidRequest(
                "The scalable Klein 4B profile requires width and height from 256 through 2048 in multiples of 32.")
        }
        let (pixelCount, overflow) = UInt64(request.width).multipliedReportingOverflow(by: UInt64(request.height))
        guard !overflow, pixelCount <= maximumPixelCount else {
            throw InferenceFailure.invalidRequest("The requested image area exceeds the execution profile limit.")
        }
        guard request.steps == steps, request.guidanceScale.isFinite,
              request.guidanceScale == guidanceScale else {
            if self == .verified512 {
                throw InferenceFailure.invalidRequest("This image backend supports only 512 x 512, 4 steps, guidance 1.")
            }
            throw InferenceFailure.invalidRequest("The scalable Klein 4B profile requires 4 steps and guidance 1.")
        }
        return pixelCount
    }

    /// B1 established the 8 GiB estimate at 512 square. Larger shapes retain that
    /// base and conservatively add 1 GiB of workspace per additional 512-square
    /// pixel area, rounded upward. This is an estimate, not a measured OOM boundary.
    public func estimatedPeakBytes(width: Int, height: Int) throws -> UInt64 {
        let shape = ImageRequest(prompt: "estimate", width: width, height: height,
                                 steps: steps, guidanceScale: guidanceScale, seed: 0)
        let pixelCount = try validatedPixelCount(shape)
        let baselinePixels = UInt64(512 * 512)
        let baselineBytes = UInt64(8 * 1024 * 1024 * 1024)
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
}
