import Foundation
import DWorkbench
import Testing
@testable import UI

@Suite @MainActor
struct SharedLibraryConceptCompatibilityTests {
    @Test func fixedLegacyResultSets() throws {
        let entries = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: nil)
        let concepts = Set(entries.flatMap { $0.item.facts.concepts })
        let sets = Dictionary(uniqueKeysWithValues: concepts.sorted().map { concept in
            (concept, entries.filter { SharedLibraryFactConditions(concepts: [concept]).matches($0.item.facts) }.map { $0.item.key }.sorted())
        })
        // Captured from the real 2d8 projection before identity changes. Exact
        // result keys include all variants sharing one old purpose condition.
        let expected = try JSONDecoder().decode([String: [String]].self, from: Data(Self.legacy.utf8))
        #expect(sets == expected)
        #expect(Set(SharedLibraryConcept.operationWireValues.keys) == Set(WorkflowRegistry.standard.definitions.map(\.id)))

    }
    @Test func localizedLabelsNeverBecomeBusinessIdentity() throws {
        let store = try SharedLibraryStore()
        let zh = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let en = UILanguageStore(preferredLanguages: ["en"])
        let query = SharedLibraryQuery(facts: .init(concepts: ["文字输入", "Qwen3.5-9B"]))
        let a = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: zh).map(\.item)
        let b = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: en).map(\.item)
        #expect(Set(store.filter(a, query: query).map(\.key)) == Set(store.filter(b, query: query).map(\.key)))
        #expect(SharedLibraryConceptPresentation.label("音符序列", language: en) == "Note sequence")
        #expect(SharedLibraryConceptPresentation.label("文字输入", language: en) != "文字输入")
        for unknown in ["d.concept.operation.d.text.input", "d.text.input", "用户新概念"] {
            #expect(SharedLibraryConcept(wireValue: unknown) == nil)
            #expect(SharedLibraryConceptPresentation.label(unknown, language: zh) == unknown)
            #expect(store.filter(a, query: .init(facts: .init(concepts: [unknown]))).isEmpty)
            let textOnly = SharedLibraryQuery(text: "Qwen3.5")
            let union = SharedLibraryQuery(text: "Qwen3.5", textTagCombination: .any, facts: .init(concepts: [unknown]))
            #expect(store.filter(a, query: union).map(\.key) == store.filter(a, query: textOnly).map(\.key))
            let bytes = try JSONEncoder().encode(union)
            #expect(try JSONDecoder().decode(SharedLibraryQuery.self, from: bytes) == union)
        }
        let user = SharedLibraryItem(key: "tool:custom", title: "文字输入", kind: .tool, role: "workflow-tool")
        let userMatch = store.matches(user, query: SharedLibraryQuery(facts: .init(concepts: ["文字输入"])))
        #expect(userMatch == false)
        let renamed = SharedLibraryItem(key: "operation:d.text.input", title: "A changed display title", kind: .program, role: "program", facts: .init(concepts: SharedLibraryConcept.operation("d.text.input").wireValues))
        let renamedMatch = store.matches(renamed, query: SharedLibraryQuery(facts: .init(concepts: ["文字输入"])))
        #expect(renamedMatch)
        let wrongProducer = store.matches(renamed, query: SharedLibraryQuery(facts: .init(concepts: ["文字输入"], producers: ["different producer"])))
        #expect(wrongProducer == false)
    }

    @Test func typedRuntimeConceptsAndSavedSearchColdOpen() throws {
        let tempo = WorkflowTempoMap(beatsPerMinute: 120, firstBeatSeconds: 0, numerator: 4, denominator: 4)
        let notes = WorkflowNoteSequence(clock: .seconds, notes: [], duration: 1, sources: [])
        let chords = WorkflowChordTrack(chords: [], duration: 1, tempo: tempo, sources: [])
        let values: [(WorkflowDatum, WorkflowDataKind, String)] = [
            (try notes.datum(), .notes, "音符序列"), (try chords.datum(), .chords, "和弦轨"), (try tempo.datum(), .tempo, "速度映射")]
        for (datum, kind, wire) in values {
            #expect(WorkflowInputContract.conceptIdentity(of: datum) == .structured(kind))
            #expect(WorkflowValueCompatibility.facts(.data(datum), producer: "producer").concepts == [wire])
        }
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]!).resolvingSymlinksInPath()
        let root = base.appendingPathComponent("concept-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let store = try SharedLibraryStore(fileURL: url)
        let query = SharedLibraryQuery(text: "Qwen", textTagCombination: .any, facts: .init(concepts: ["文字输入", "d.concept.operation.d.text.input"]))
        let id = try store.createSavedQuery(name: "User name 不翻译", query: query)
        let original = try Data(contentsOf: url)
        let reopened = try SharedLibraryStore(fileURL: url)
        let entries = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: nil).map(\.item)
        #expect(reopened.metadata.savedQueries[id]?.query == query)
        #expect(reopened.metadata.savedQueries[id]?.name == "User name 不翻译")
        #expect(try reopened.filter(entries, savedQueryID: id).map(\.key) == store.filter(entries, query: query).map(\.key))
        #expect(try Data(contentsOf: url) == original)
        let json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        #expect(json["schema"] as? Int == 3)
    }

    private static let legacy = #"""
{
  "ACE-Step 1.5 XL SFT" : [
    "ace-step-1.5-xl-sft-f32-no-lm"
  ],
  "Data Input" : [
    "operation:d.value.input"
  ],
  "Data Template" : [
    "operation:d.value.template"
  ],
  "FLUX.2-dev · BF16" : [
    "flux2-dev-bf16"
  ],
  "FLUX.2-klein-4B" : [
    "flux2-klein-4b-bf16",
    "flux2-klein-4b-q8"
  ],
  "Field" : [
    "operation:d.value.field"
  ],
  "Filter" : [
    "operation:d.value.filter"
  ],
  "LTX 2.3 dev · BF16" : [
    "video.model.ltx-2.3-dev-bf16-full-v1"
  ],
  "LTX 2.3 dev · Q8 / Gemma Q4" : [
    "video.model.ltx-2.3-dev-q8-gemma3-q4-test-v1"
  ],
  "LTX-2.5 dev · BF16" : [
    "video.model.ltx-2.5-dev-bf16-full-v1"
  ],
  "List" : [
    "operation:d.value.list"
  ],
  "MRT2 small/export-v1" : [
    "mrt2-small-export-v1"
  ],
  "MiniMax H3 Base FL2VA · BF16" : [
    "video.model.minimax-h3-fl2va-bf16-full-v1"
  ],
  "Pair" : [
    "operation:d.value.pair"
  ],
  "Qwen2.5 Instruct · 兼容" : [
    "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
    "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
    "mlx-community/Qwen2.5-32B-Instruct-4bit",
    "mlx-community/Qwen2.5-7B-Instruct-4bit"
  ],
  "Qwen3.5-9B" : [
    "Qwen/Qwen3.5-9B",
    "mlx-community/Qwen3.5-9B-4bit"
  ],
  "Qwen3.8-27B" : [
    "Qwen/Qwen3.8-27B",
    "mlx-community/Qwen3.8-27B-4bit"
  ],
  "Record" : [
    "operation:d.value.record"
  ],
  "Return" : [
    "operation:d.value.return"
  ],
  "Select" : [
    "operation:d.value.select"
  ],
  "Validate" : [
    "operation:d.value.validate"
  ],
  "Wan2.1-T2V-1.3B" : [
    "wan21-t2v-1.3b-bf16-v1"
  ],
  "使用自定义工具" : [
    "operation:d.control.invoke"
  ],
  "候选转列表" : [
    "operation:d.value.candidates"
  ],
  "导出" : [
    "operation:d.asset.export"
  ],
  "导出文件" : [
    "operation:d.value.export"
  ],
  "截取音频" : [
    "operation:d.audio.trim"
  ],
  "文字模板" : [
    "operation:d.text.template"
  ],
  "文字输入" : [
    "operation:d.text.input"
  ],
  "条件选择" : [
    "operation:d.control.branch"
  ],
  "查看调性候选" : [
    "operation:d.music.keys"
  ],
  "确认文字" : [
    "operation:d.text.confirm"
  ],
  "移除空行" : [
    "operation:d.text.remove-blank-lines"
  ],
  "等待用户处理" : [
    "operation:d.control.human"
  ],
  "编写和声" : [
    "operation:d.music.chords"
  ],
  "解释节拍" : [
    "operation:d.music.align"
  ],
  "识别哼唱音高" : [
    "swift-f0-0.1.2-cpu-v1"
  ],
  "调整图像尺寸" : [
    "operation:d.image.resize"
  ],
  "转换图像" : [
    "operation:d.image.convert"
  ],
  "转换音频规格" : [
    "operation:d.audio.convert"
  ],
  "选择候选" : [
    "operation:d.asset.choose"
  ],
  "逐项执行" : [
    "operation:d.control.map"
  ],
  "重复到满足条件" : [
    "operation:d.control.loop"
  ],
  "音符合成试听" : [
    "operation:d.music.render"
  ],
  "项目素材" : [
    "operation:d.asset.reference"
  ]
}
"""#
}
