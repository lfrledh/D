import Foundation
import DInference

/// A form declared by the existing operation, not a second model catalogue.
public enum QuickAudioPresentation: Sendable, Equatable {
    case mrt2Text, aceGenerate

    public static func form(for draft: QuickDraft) -> Self? {
        WorkflowRegistry.standard.definition(for: draft.node)?.quickAudio
    }
    public static func requiresWorkflow(_ draft: QuickDraft) -> Bool {
        guard QuickCategory.category(for: draft.node.operationID) == .audio else { return false }
        guard let form = form(for: draft) else { return true }
        // Explicit ports retain their provenance and precedence. The compact form
        // edits parameter text only; never silently discard even an empty condition.
        guard draft.inputs.isEmpty, draft.node.dataConfiguration == nil else { return true }
        return form == .aceGenerate && draft.node.parameters["mode"]?.string != "generate"
    }
    public static func validationIssue(_ draft: QuickDraft) -> WorkflowIssue? {
        guard QuickCategory.category(for: draft.node.operationID) == .audio else { return nil }
        if requiresWorkflow(draft) {
            return .init("This creation uses advanced audio settings. Continue in the node workflow.", code: "quick.audio.complex")
        }
        switch form(for: draft) {
        case .mrt2Text:
            if let raw = draft.fieldText["quickDurationSeconds"], frames(seconds: raw) == nil {
                return .init("Enter 0.04–16 seconds in steps of 0.04 seconds.", code: "quick.audio.durationGrid")
            }
            guard let frames = draft.node.parameters["durationFrames"]?.integer, (1...400).contains(frames) else {
                return .init("Enter 0.04–16 seconds in steps of 0.04 seconds.", code: "quick.audio.durationGrid")
            }
            guard let seed = UInt64(draft.node.parameters["seed"]?.string ?? ""), seed <= AudioRequest.mrt2MaximumSeed else {
                return .init("Enter a seed from 0 to 4294967295.", code: "quick.audio.seedInvalid")
            }
            do {
                let condition = try WorkflowMRT2Condition.make(notes: nil, chords: nil, durationFrames: frames)
                try AudioRequest(prompt: draft.node.parameters["promptText"]?.string ?? "", seed: seed, noteSequence: condition).validate()
            } catch {
                return .init(error.localizedDescription, code: "quick.audio.descriptionInvalid")
            }
        case .aceGenerate:
            let p = draft.node.parameters, lyrics = p["lyricsText"]?.string ?? ""
            guard ["instrumental", "lyrics"].contains(p["vocal"]?.string ?? "") else {
                return .init("Choose Instrumental or With lyrics.", code: "quick.audio.vocalInvalid")
            }
            if p["vocal"]?.string == "instrumental", !lyrics.isEmpty {
                return .init("Lyrics are preserved. Choose With lyrics, or explicitly clear the lyrics before generating instrumental audio.", code: "quick.audio.lyricsConflict")
            }
            do {
                _ = try WorkflowACEOperation.request(node: draft.node, prompt: p["promptText"]?.string ?? "",
                    lyrics: lyrics, reference: nil, source: nil)
            } catch {
                return .init("Check the audio generation settings. " + error.localizedDescription, code: "quick.audio.invalidSettings")
            }
        case nil: break
        }
        return nil
    }
    public static func batchIssue(_ draft: QuickDraft) -> WorkflowIssue? {
        guard form(for: draft) != nil, draft.attempts > 1,
              let seed = UInt64(draft.node.parameters["seed"]?.string ?? "") else { return nil }
        let (last, overflow) = seed.addingReportingOverflow(UInt64(draft.attempts - 1))
        if overflow || last > UInt32.max {
            return .init("The final attempt exceeds this model's seed range. Reduce the number to generate or the seed.", code: "quick.audio.seedBatch")
        }
        return nil
    }
    public static func hasUnexpectedOutput(_ run: QuickRunRecord) -> Bool {
        guard form(for: run.draft) != nil else { return false }
        func unexpected(_ value: WorkflowValue) -> Bool {
            switch value {
            case .asset(let ref), .data(.asset(let ref)): return ref.kind != .audio
            case .data, .receipt: return true
            case .collection(let candidates): return candidates.contains { $0.asset.map { $0.kind != .audio } ?? false }
            }
        }
        return run.outputs.values.contains(where: unexpected)
            || run.candidates.contains { $0.asset.map { $0.kind != .audio } ?? false }
    }
    /// Decimal arithmetic rejects off-grid input; displaying a saved frame count
    /// never mutates it. In particular 123 frames stays 4.92 seconds.
    public static func seconds(frames: Int) -> String {
        NSDecimalNumber(decimal: Decimal(frames) / 25).stringValue
    }
    public static func frames(seconds text: String) -> Int? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              raw.filter({ $0 == "." }).count <= 1,
              let seconds = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var value = seconds * 25, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        guard value == rounded, value >= 1, value <= 400 else { return nil }
        return NSDecimalNumber(decimal: value).intValue
    }
}
