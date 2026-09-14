import DInference
import Foundation
import Testing
@testable import UI

@Suite("Pitch analysis view action gates")
struct PitchAnalysisViewTests {
    @Test
    func emptyCandidateOnlyPermitsAvailableAnalysis() {
        #expect(PitchAnalysisViewActionGate.canAnalyze(result: nil, isBusy: false, hasSaved: false, canAnalyze: true))
        #expect(!PitchAnalysisViewActionGate.canSave(result: nil, isBusy: false, isStale: false, hasSaved: false))
        #expect(!PitchAnalysisViewActionGate.canReject(result: nil, isBusy: false, hasSaved: false))
        #expect(!PitchAnalysisViewActionGate.canExport(result: nil, isBusy: false))
    }

    @Test
    func unresolvedAndStaleCandidatesCannotAnalyzeOrSave() {
        let result = makeResult()
        #expect(!PitchAnalysisViewActionGate.canAnalyze(result: result, isBusy: false, hasSaved: false, canAnalyze: true))
        #expect(!PitchAnalysisViewActionGate.canSave(result: result, isBusy: false, isStale: true, hasSaved: false))
        #expect(PitchAnalysisViewActionGate.canReject(result: result, isBusy: false, hasSaved: false))
        #expect(PitchAnalysisViewActionGate.canExport(result: result, isBusy: false))
    }

    @Test
    func savedCandidateCanExportAndStartNewAnalysisButCannotSaveOrRejectAgain() {
        let result = makeResult()
        #expect(PitchAnalysisViewActionGate.canAnalyze(result: result, isBusy: false, hasSaved: true, canAnalyze: true))
        #expect(!PitchAnalysisViewActionGate.canSave(result: result, isBusy: false, isStale: false, hasSaved: true))
        #expect(!PitchAnalysisViewActionGate.canReject(result: result, isBusy: false, hasSaved: true))
        #expect(PitchAnalysisViewActionGate.canExport(result: result, isBusy: false))
    }

    @Test
    func busyStatePermitsOnlyCancellation() {
        let result = makeResult()
        #expect(!PitchAnalysisViewActionGate.canAnalyze(result: result, isBusy: true, hasSaved: true, canAnalyze: true))
        #expect(PitchAnalysisViewActionGate.canCancel(isBusy: true))
        #expect(!PitchAnalysisViewActionGate.canSave(result: result, isBusy: true, isStale: false, hasSaved: false))
        #expect(!PitchAnalysisViewActionGate.canReject(result: result, isBusy: true, hasSaved: false))
        #expect(!PitchAnalysisViewActionGate.canExport(result: result, isBusy: true))
    }

    @Test
    func callbacksRouteOnlyWhenTheirStateAllowsTheAction() {
        let result = makeResult()
        var routed: [String] = []
        #expect(PitchAnalysisViewActionGate.analyze(result: nil, isBusy: false, hasSaved: false, canAnalyze: true) {
            routed.append("analyze")
        })
        #expect(PitchAnalysisViewActionGate.cancel(isBusy: true) { routed.append("cancel") })
        #expect(PitchAnalysisViewActionGate.save(result: result, isBusy: false, isStale: false, hasSaved: false) {
            routed.append("save")
        })
        #expect(PitchAnalysisViewActionGate.reject(result: result, isBusy: false, hasSaved: false) {
            routed.append("reject")
        })
        #expect(PitchAnalysisViewActionGate.export(result: result, isBusy: false) { routed.append("export") })
        #expect(!PitchAnalysisViewActionGate.save(result: result, isBusy: false, isStale: true, hasSaved: false) {
            routed.append("stale-save")
        })
        #expect(!PitchAnalysisViewActionGate.export(result: nil, isBusy: false) { routed.append("empty-export") })
        #expect(routed == ["analyze", "cancel", "save", "reject", "export"])
    }

    @Test
    func invalidResultsUseErrorPresentationAndCannotSaveOrExport() {
        let validSilence = makeResult(frames: Array(repeating: unvoicedFrame(confidence: 0.4), count: 5))
        let invalidSchema = makeResult(schemaVersion: 2)
        let invalidNonfinitePitch = makeResult(frames: Array(repeating: PitchFrame(pitchHz: .nan, confidence: 0.95, voiced: true), count: 5))
        let invalidConfidence = makeResult(frames: Array(repeating: unvoicedFrame(confidence: 1.1), count: 5))
        let invalidShape = makeResult(sampleCount: 1_536)

        if case .valid = PitchAnalysisViewActionGate.resultState(result: validSilence) {
            #expect(PitchAnalysisViewActionGate.canSave(result: validSilence, isBusy: false, isStale: false, hasSaved: false))
            #expect(PitchAnalysisViewActionGate.canExport(result: validSilence, isBusy: false))
        } else {
            Issue.record("A valid no-pitch result must not use the error presentation.")
        }

        for invalid in [invalidSchema, invalidNonfinitePitch, invalidConfidence, invalidShape] {
            #expect(PitchAnalysisViewActionGate.resultState(result: invalid) == .invalid)
            #expect(!PitchAnalysisViewActionGate.canSave(result: invalid, isBusy: false, isStale: false, hasSaved: false))
            #expect(!PitchAnalysisViewActionGate.canExport(result: invalid, isBusy: false))
            #expect(PitchAnalysisViewActionGate.canReject(result: invalid, isBusy: false, hasSaved: false))
        }
    }

    private func makeResult(frames: [PitchFrame]? = nil, sampleCount: Int = 1_280, schemaVersion: Int = 1) -> PitchAnalysisResult {
        let source = PitchSourceIdentity(assetID: UUID(), documentID: UUID(), documentRevision: 1,
                                         contentSHA256: String(repeating: "a", count: 64), sampleRate: 16_000,
                                         frameCount: Int64(sampleCount), startFrame: 0, endFrame: Int64(sampleCount))
        return PitchAnalysisResult(runID: UUID(), source: source, inputSHA256: String(repeating: "b", count: 64),
                                   sampleCount: sampleCount,
                                   frames: frames ?? Array(repeating: PitchFrame(pitchHz: 440, confidence: 0.95, voiced: true), count: 5),
                                   schemaVersion: schemaVersion)
    }

    private func unvoicedFrame(confidence: Double) -> PitchFrame {
        PitchFrame(pitchHz: nil, confidence: confidence, voiced: false)
    }
}
