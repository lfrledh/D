import Foundation

/// Only residency changes. The backend still establishes exact variant support.
public enum LowMemoryMethod: String, Codable, Sendable { case layered, streaming }

public struct InferenceExecutionPlan: Codable, Sendable, Equatable {
    public let request: InferenceRequest
    public let method: LowMemoryMethod
    public let strategyVersion: Int
    /// A seal of the admitted files, not a replacement for content verification.
    public let modelIdentityToken: String
    public init(request: InferenceRequest, method: LowMemoryMethod, strategyVersion: Int,
                modelIdentityToken: String) {
        self.request = request; self.method = method; self.strategyVersion = strategyVersion
        self.modelIdentityToken = modelIdentityToken
    }

    public func validateSemantics(original: InferenceRequest) throws {
        guard strategyVersion > 0, !modelIdentityToken.isEmpty,
              request == (try original.lowMemoryRequest(method: method)) else {
            throw InferenceFailure.invalidRequest("The execution plan changed protected request values.")
        }
    }
}

public extension InferenceRequest {
    /// Value copies retain every semantic field, including fields added in future.
    /// This helper grants no permission and does not assert backend support.
    func lowMemoryRequest(method: LowMemoryMethod) throws -> Self {
        let changed: InferenceInput
        switch (input, method) {
        case (.text(var value), .layered):
            value.loadingStrategy = .ssdLayered; changed = .text(value)
        case (.image(var value), .layered):
            value.loadingStrategy = .ssdLayered; changed = .image(value)
        case (.audio(var value), .layered):
            guard var ace = value.ace else {
                throw InferenceFailure.invalidRequest("This audio operation has no layered strategy.")
            }
            ace.loadingStrategy = .ssdLayered
            value.parameters = .aceStep15(ace); changed = .audio(value)
        case (.video(var value), .streaming):
            switch value.adapterOptions {
            case .h3: value.adapterOptions = .h3(streamWeights: true)
            case .ltx(_, let guidance):
                value.adapterOptions = .ltx(streamWeights: true, spatiotemporalGuidance: guidance)
            case nil: throw InferenceFailure.invalidRequest("This video request has no streaming strategy.")
            }
            changed = .video(value)
        default: throw InferenceFailure.invalidRequest("Unsupported execution organization.")
        }
        return .init(id: id, model: model, input: changed, memoryBudgetBytes: memoryBudgetBytes,
                     priority: priority, loadingSelection: nil)
    }

    var explicitLowMemoryMethod: LowMemoryMethod? {
        switch input {
        case .text(let v): return v.loadingStrategy == .ssdLayered ? .layered : nil
        case .image(let v): return v.loadingStrategy == .ssdLayered ? .layered : nil
        case .audio(let v): return v.ace?.loadingStrategy == .ssdLayered ? .layered : nil
        case .video(let v):
            switch v.adapterOptions {
            case .h3(true), .ltx(true, _): return .streaming
            default: return nil
            }
        default: return nil
        }
    }
}

/// Optional, bounded extension. Existing backends keep their fixed behavior.
public protocol InferenceExecutionPlanning: InferenceBackend {
    func lowMemoryPlans(for request: InferenceRequest) async throws -> [InferenceExecutionPlan]
    func validate(_ plan: InferenceExecutionPlan, for original: InferenceRequest) async throws
    /// Must carry the approved file seal into loading, not recapture it as a new baseline.
    func execute(_ plan: InferenceExecutionPlan, for original: InferenceRequest,
                 emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult
}

public struct LowMemoryProposal: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let entryToken: UUID
    public let original: InferenceRequest
    public let backend: BackendDescriptor
    public let plan: InferenceExecutionPlan
    public let preferredEstimate: ResourceEstimate
    public let estimate: ResourceEstimate
    public let budget: UInt64
    public init(id: UUID = UUID(), entryToken: UUID, original: InferenceRequest,
                backend: BackendDescriptor, plan: InferenceExecutionPlan,
                preferredEstimate: ResourceEstimate, estimate: ResourceEstimate, budget: UInt64) {
        self.id = id; self.entryToken = entryToken; self.original = original; self.backend = backend
        self.plan = plan; self.preferredEstimate = preferredEstimate; self.estimate = estimate; self.budget = budget
    }
}

public enum LowMemoryDecision: String, Codable, Sendable {
    case allowOnce, allowedByPreference, denyByPreference, userStopped
    public var permitsExecution: Bool { self == .allowOnce || self == .allowedByPreference }
}

/// One small record retained by the existing run handle, including failures/cancellation.
public struct InferenceExecutionRecord: Sendable, Codable, Equatable {
    public struct Candidate: Sendable, Codable, Equatable {
        public let method: LowMemoryMethod
        public let strategyVersion: Int
        public let estimate: ResourceEstimate
        public let withinBudget: Bool
        public init(plan: InferenceExecutionPlan, estimate: ResourceEstimate, budget: UInt64) {
            method = plan.method; strategyVersion = plan.strategyVersion
            self.estimate = estimate; withinBudget = estimate.peakBytes <= budget
        }
    }
    public enum State: String, Codable, Sendable {
        case evaluating, awaitingDecision, selected, stopped, completed, failed, cancelled
    }
    public var state: State
    public let requestID: UUID
    /// Distinguishes explicit retries that retain the same logical request/call ID.
    public let submissionID: UUID
    public let requested: InferenceLoadingSelection?
    public let preferredMode: String
    public let backend: BackendDescriptor
    public let model: ModelReference
    public let budget: UInt64
    public var preferredEstimate: ResourceEstimate?
    public var lowMemoryEstimate: ResourceEstimate?
    public var method: LowMemoryMethod?
    public var strategyVersion: Int?
    public var modelIdentityToken: String?
    public var decision: LowMemoryDecision?
    public var explicitlySelected: Bool
    public var reason: String?
    public var failureDiagnostic: String?
    public var candidates: [Candidate] = []
    public var measurements: [String: String]?
    /// True only after admission and immediately before the backend call. Old records stay unknown.
    public var executionStarted: Bool?
    public init(request: InferenceRequest, backend: BackendDescriptor, budget: UInt64, submissionID: UUID = UUID()) {
        state = .evaluating; executionStarted = false; requestID = request.id; self.submissionID = submissionID; requested = request.loadingSelection; self.backend = backend
        model = request.model; self.budget = budget
        switch request.input {
        case .text(let input): preferredMode = input.loadingStrategy?.rawValue ?? "resident"
        case .image(let input): preferredMode = input.loadingStrategy?.rawValue ?? "staged"
        case .audio(let input): preferredMode = input.ace?.loadingStrategy.rawValue ?? "resident"
        case .video: preferredMode = request.explicitLowMemoryMethod == .streaming ? "streaming" : "resident"
        default: preferredMode = "resident"
        }
        method = request.explicitLowMemoryMethod; explicitlySelected = method != nil
    }
}

public extension Array where Element == InferenceExecutionRecord {
    /// A saved call keeps prior submissions; a repeated save updates only its own record.
    func mergingExecutionRecords(_ incoming: [Element]) -> [Element] {
        var result = self
        for record in incoming {
            if let index = result.firstIndex(where: { $0.submissionID == record.submissionID }) { result[index] = record }
            else { result.append(record) }
        }
        return result
    }
}
