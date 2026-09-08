import Foundation

public enum RecipeField<Value: Codable & Sendable & Equatable>: Sendable, Equatable, Codable {
    case value(Value)
    case unknown
    case notApplicable
    case withheld
    case invalid(reasonCode: String)

    private enum CodingKeys: String, CodingKey { case state, value, reasonCode = "reason_code" }
    private enum State: String, Codable { case value, unknown, notApplicable = "not_applicable", withheld, invalid }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: ["state", "value", "reason_code"]) else { throw GenerationRecipeError.invalidStructure }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.state) else { throw GenerationRecipeError.invalidStructure }
        let state = try container.decode(State.self, forKey: .state)
        switch state {
        case .value:
            guard container.contains(.value), !container.contains(.reasonCode) else { throw GenerationRecipeError.invalidStructure }
            self = .value(try container.decode(Value.self, forKey: .value))
        case .invalid:
            guard container.contains(.reasonCode), !container.contains(.value) else { throw GenerationRecipeError.invalidStructure }
            let reasonCode = try container.decode(String.self, forKey: .reasonCode)
            guard !reasonCode.isEmpty, reasonCode.utf8.count <= 64, reasonCode.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw GenerationRecipeError.invalidValue }
            self = .invalid(reasonCode: reasonCode)
        case .unknown, .notApplicable, .withheld:
            guard !container.contains(.value), !container.contains(.reasonCode) else { throw GenerationRecipeError.invalidStructure }
            self = state == .unknown ? .unknown : (state == .notApplicable ? .notApplicable : .withheld)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .value(let value):
            try container.encode(State.value, forKey: .state); try container.encode(value, forKey: .value)
        case .unknown: try container.encode(State.unknown, forKey: .state)
        case .notApplicable: try container.encode(State.notApplicable, forKey: .state)
        case .withheld: try container.encode(State.withheld, forKey: .state)
        case .invalid(let reasonCode):
            try container.encode(State.invalid, forKey: .state); try container.encode(reasonCode, forKey: .reasonCode)
        }
    }

    fileprivate func validateReasonCode() throws {
        guard case .invalid(let code) = self else { return }
        guard !code.isEmpty, code.utf8.count <= 64,
              code.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw GenerationRecipeError.invalidValue
        }
    }
}

public enum RecipeClaim: String, Codable, Sendable, Equatable { case captured, callerDeclared = "caller_declared" }
public enum RecipeDisclosure: Sendable, Equatable { case privateArchive, publicShare }
public enum GenerationRecipeError: Error, Equatable { case invalidStructure, invalidValue, sizeLimitExceeded, depthLimitExceeded }

public struct GenerationRecipe: Codable, Sendable, Equatable {
    public var assetID: UUID; public var assetVersion: UUID; public var runID: UUID
    public var modelSource: RecipeField<String>; public var modelRevision: RecipeField<String>; public var weightsManifestSHA256: RecipeField<String>
    public var prompt: RecipeField<String>; public var structuredInputRevision: RecipeField<String>; public var seed: RecipeField<String>
    public var steps: RecipeField<Int>; public var guidance: RecipeField<Double>; public var width: RecipeField<Int>; public var height: RecipeField<Int>
    public var scheduler: RecipeField<String>; public var computePrecision: RecipeField<String>; public var quantization: RecipeField<String>; public var implementationVersion: RecipeField<String>; public var mediaPayloadSHA256: RecipeField<String>
    public var parents: [UUID]; public var claim: RecipeClaim

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case assetID, assetVersion, runID, modelSource, modelRevision, weightsManifestSHA256, prompt, structuredInputRevision, seed, steps, guidance, width, height, scheduler, computePrecision, quantization, implementationVersion, mediaPayloadSHA256, parents, claim
    }

    public init(assetID: UUID, assetVersion: UUID, runID: UUID, modelSource: RecipeField<String>, modelRevision: RecipeField<String>, weightsManifestSHA256: RecipeField<String>, prompt: RecipeField<String>, structuredInputRevision: RecipeField<String>, seed: RecipeField<String>, steps: RecipeField<Int>, guidance: RecipeField<Double>, width: RecipeField<Int>, height: RecipeField<Int>, scheduler: RecipeField<String>, computePrecision: RecipeField<String>, quantization: RecipeField<String>, implementationVersion: RecipeField<String>, mediaPayloadSHA256: RecipeField<String>, parents: [UUID], claim: RecipeClaim) {
        self.assetID = assetID; self.assetVersion = assetVersion; self.runID = runID; self.modelSource = modelSource; self.modelRevision = modelRevision; self.weightsManifestSHA256 = weightsManifestSHA256; self.prompt = prompt; self.structuredInputRevision = structuredInputRevision; self.seed = seed; self.steps = steps; self.guidance = guidance; self.width = width; self.height = height; self.scheduler = scheduler; self.computePrecision = computePrecision; self.quantization = quantization; self.implementationVersion = implementationVersion; self.mediaPayloadSHA256 = mediaPayloadSHA256; self.parents = parents; self.claim = claim
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyKey.self)
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        guard Set(dynamic.allKeys.map(\.stringValue)) == expected else { throw GenerationRecipeError.invalidStructure }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try c.decode(UUID.self, forKey: .assetID); assetVersion = try c.decode(UUID.self, forKey: .assetVersion); runID = try c.decode(UUID.self, forKey: .runID)
        modelSource = try c.decode(RecipeField<String>.self, forKey: .modelSource); modelRevision = try c.decode(RecipeField<String>.self, forKey: .modelRevision); weightsManifestSHA256 = try c.decode(RecipeField<String>.self, forKey: .weightsManifestSHA256)
        prompt = try c.decode(RecipeField<String>.self, forKey: .prompt); structuredInputRevision = try c.decode(RecipeField<String>.self, forKey: .structuredInputRevision); seed = try c.decode(RecipeField<String>.self, forKey: .seed)
        steps = try c.decode(RecipeField<Int>.self, forKey: .steps); guidance = try c.decode(RecipeField<Double>.self, forKey: .guidance); width = try c.decode(RecipeField<Int>.self, forKey: .width); height = try c.decode(RecipeField<Int>.self, forKey: .height)
        scheduler = try c.decode(RecipeField<String>.self, forKey: .scheduler); computePrecision = try c.decode(RecipeField<String>.self, forKey: .computePrecision); quantization = try c.decode(RecipeField<String>.self, forKey: .quantization); implementationVersion = try c.decode(RecipeField<String>.self, forKey: .implementationVersion); mediaPayloadSHA256 = try c.decode(RecipeField<String>.self, forKey: .mediaPayloadSHA256)
        parents = try c.decode([UUID].self, forKey: .parents); claim = try c.decode(RecipeClaim.self, forKey: .claim)
    }

    public func projected(for disclosure: RecipeDisclosure) -> Self {
        guard disclosure == .publicShare else { return self }
        var copy = self
        copy.prompt = .withheld; copy.structuredInputRevision = .withheld; copy.parents = []; copy.claim = .callerDeclared
        return copy
    }

    fileprivate func validated() throws -> Self {
        guard parents.count <= 32 else { throw GenerationRecipeError.invalidValue }
        for field in [modelSource, modelRevision, weightsManifestSHA256, prompt, structuredInputRevision, seed, scheduler, computePrecision, quantization, implementationVersion, mediaPayloadSHA256] { try field.validateReasonCode() }
        for field in [steps, width, height] { try field.validateReasonCode() }
        try guidance.validateReasonCode()
        try validateModelSource(modelSource)
        for field in [modelRevision, scheduler, computePrecision, quantization, implementationVersion] { try validateIdentifier(field) }
        for field in [weightsManifestSHA256, mediaPayloadSHA256] { try validateSHA256(field) }
        try validatePrompt(prompt); try validateIdentifier(structuredInputRevision); try validateSeed(seed)
        for field in [steps, width, height] { if case .value(let value) = field, value <= 0 { throw GenerationRecipeError.invalidValue } }
        if case .value(let value) = guidance, !value.isFinite || value < 0 { throw GenerationRecipeError.invalidValue }
        return self
    }
}

public enum GenerationRecipeCodec {
    public static func encode(_ recipe: GenerationRecipe, disclosure: RecipeDisclosure = .publicShare) throws -> Data {
        let projected = try recipe.projected(for: disclosure).validated()
        let data = try JSONEncoder().encode(Envelope(recipe: projected))
        guard data.count <= 128 * 1024 else { throw GenerationRecipeError.sizeLimitExceeded }
        return data
    }

    public static func decode(_ data: Data) throws -> GenerationRecipe {
        guard data.count <= 128 * 1024 else { throw GenerationRecipeError.sizeLimitExceeded }
        try StrictJSON.check(data)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.namespace == "org.d.generation-recipe", envelope.schemaVersion == 1 else { throw GenerationRecipeError.invalidStructure }
        var recipe = try envelope.recipe.validated()
        recipe.claim = .callerDeclared
        return recipe
    }
}

private struct Envelope: Codable {
    let namespace: String
    let schemaVersion: Int
    let recipe: GenerationRecipe
    enum CodingKeys: String, CodingKey { case namespace, schemaVersion = "schema_version", recipe }
    init(recipe: GenerationRecipe) { namespace = "org.d.generation-recipe"; schemaVersion = 1; self.recipe = recipe }
    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(["namespace", "schema_version", "recipe"]) else { throw GenerationRecipeError.invalidStructure }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try c.decode(String.self, forKey: .namespace); schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); recipe = try c.decode(GenerationRecipe.self, forKey: .recipe)
    }
}

private struct AnyKey: CodingKey, Hashable {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

private func stringValue(_ field: RecipeField<String>) -> String? { if case .value(let value) = field { return value }; return nil }
private func validateModelSource(_ field: RecipeField<String>) throws {
    guard let value = stringValue(field) else { return }
    let segments = value.split(separator: "/", omittingEmptySubsequences: false)
    guard !value.isEmpty, value.utf8.count <= 256, !value.hasPrefix("/"), !value.contains("://"), !value.contains("?"), !value.contains("#"), !value.contains("@"), segments.count <= 2, !segments.contains(""), !segments.contains(".."), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == "/") }) else { throw GenerationRecipeError.invalidValue }
}
private func validateIdentifier(_ field: RecipeField<String>) throws {
    guard let value = stringValue(field) else { return }
    guard !value.isEmpty, value.utf8.count <= 256, !value.hasPrefix("/"), !value.contains(":"), !value.contains("?"), !value.contains("#"), !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw GenerationRecipeError.invalidValue }
}
private func validateSHA256(_ field: RecipeField<String>) throws {
    guard let value = stringValue(field) else { return }
    guard value.count == 64, value.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else { throw GenerationRecipeError.invalidValue }
}
private func validatePrompt(_ field: RecipeField<String>) throws { if let value = stringValue(field), value.utf8.count > 64 * 1024 { throw GenerationRecipeError.sizeLimitExceeded } }
private func validateSeed(_ field: RecipeField<String>) throws {
    guard let value = stringValue(field) else { return }
    guard value == "0" || (value.first != "0" && value.allSatisfy(\.isNumber) && UInt64(value) != nil) else { throw GenerationRecipeError.invalidValue }
}

private enum StrictJSON {
    static func check(_ data: Data) throws {
        var parser = Parser(bytes: Array(data)); try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count else { throw GenerationRecipeError.invalidStructure }
    }
    private struct Parser {
        let bytes: [UInt8]; var index = 0
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func value(depth: Int) throws {
            space(); guard index < bytes.count else { throw GenerationRecipeError.invalidStructure }
            switch bytes[index] { case 123: try object(depth: depth + 1); case 91: try array(depth: depth + 1); case 34: _ = try string(); case 116: try literal("true"); case 102: try literal("false"); case 110: try literal("null"); default: try number() }
        }
        mutating func object(depth: Int) throws {
            guard depth <= 16 else { throw GenerationRecipeError.depthLimitExceeded }; index += 1; space(); if take(125) { return }; var keys = Set<String>()
            while true { space(); let key = try string(); guard keys.insert(key).inserted else { throw GenerationRecipeError.invalidStructure }; space(); guard take(58) else { throw GenerationRecipeError.invalidStructure }; try value(depth: depth); space(); if take(125) { return }; guard take(44) else { throw GenerationRecipeError.invalidStructure } }
        }
        mutating func array(depth: Int) throws {
            guard depth <= 16 else { throw GenerationRecipeError.depthLimitExceeded }; index += 1; space(); if take(93) { return }
            while true { try value(depth: depth); space(); if take(93) { return }; guard take(44) else { throw GenerationRecipeError.invalidStructure } }
        }
        mutating func string() throws -> String {
            guard take(34) else { throw GenerationRecipeError.invalidStructure }; var output = ""
            while index < bytes.count { let start = index; while index < bytes.count && bytes[index] != 34 && bytes[index] != 92 { guard bytes[index] >= 32 else { throw GenerationRecipeError.invalidStructure }; index += 1 }; guard let segment = String(bytes: bytes[start..<index], encoding: .utf8) else { throw GenerationRecipeError.invalidStructure }; output += segment; guard index < bytes.count else { break }; if take(34) { return output }; index += 1; guard index < bytes.count else { break }; let escaped = bytes[index]; index += 1; switch escaped { case 34: output += "\""; case 92: output += "\\"; case 47: output += "/"; case 98: output += "\u{08}"; case 102: output += "\u{0C}"; case 110: output += "\n"; case 114: output += "\r"; case 116: output += "\t"; case 117: output += try unicode(); default: throw GenerationRecipeError.invalidStructure } }
            throw GenerationRecipeError.invalidStructure
        }
        mutating func unicode() throws -> String {
            func codeUnit(_ position: Int) -> UInt16? { guard position + 4 <= bytes.count, let text = String(bytes: bytes[position..<position + 4], encoding: .utf8) else { return nil }; return UInt16(text, radix: 16) }
            guard let first = codeUnit(index) else { throw GenerationRecipeError.invalidStructure }; index += 4
            if (0xD800...0xDBFF).contains(first) {
                guard index + 6 <= bytes.count, bytes[index] == 92, bytes[index + 1] == 117, let second = codeUnit(index + 2), (0xDC00...0xDFFF).contains(second), let scalar = UnicodeScalar(0x10000 + (UInt32(first) - 0xD800) * 0x400 + (UInt32(second) - 0xDC00)) else { throw GenerationRecipeError.invalidStructure }
                index += 6; return String(scalar)
            }
            guard !(0xDC00...0xDFFF).contains(first), let scalar = UnicodeScalar(UInt32(first)) else { throw GenerationRecipeError.invalidStructure }
            return String(scalar)
        }
        mutating func literal(_ text: String) throws { let expected = Array(text.utf8); guard bytes.dropFirst(index).starts(with: expected) else { throw GenerationRecipeError.invalidStructure }; index += expected.count }
        mutating func number() throws { let start = index; if take(45) {}; guard index < bytes.count else { throw GenerationRecipeError.invalidStructure }; if take(48) {} else { guard bytes[index] >= 49 && bytes[index] <= 57 else { throw GenerationRecipeError.invalidStructure }; while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 { index += 1 } }; if take(46) { let fraction = index; while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 { index += 1 }; guard index > fraction else { throw GenerationRecipeError.invalidStructure } }; if index < bytes.count && (bytes[index] == 69 || bytes[index] == 101) { index += 1; _ = take(43) || take(45); let exponent = index; while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 { index += 1 }; guard index > exponent else { throw GenerationRecipeError.invalidStructure } }; guard index > start else { throw GenerationRecipeError.invalidStructure } }
        mutating func take(_ byte: UInt8) -> Bool { guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true }
    }
}
