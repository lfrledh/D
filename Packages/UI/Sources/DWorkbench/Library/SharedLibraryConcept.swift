import Foundation

/// Stable fact identity, separate from display names and user labels.
/// Schema 1–3 wire tokens are intentionally frozen, including old Chinese bytes.
/// They are compatibility encoding, never validator/adapter dispatch controls.
/// Unknown saved strings remain unknown: no namespace guessing or canonicalizing.
public enum SharedLibraryConcept: Sendable, Hashable {
    case operation(String)
    case content(WorkflowDataKind)
    case structured(WorkflowDataKind)

    public var wireValue: String? {
        switch self {
        case .operation(let id): Self.operationWireValues[id]
        case .content(let kind): "content." + kind.rawValue
        case .structured(.notes): "音符序列"
        case .structured(.chords): "和弦轨"
        case .structured(.tempo): "速度映射"
        case .structured: nil
        }
    }
    public var wireValues: Set<String> { wireValue.map { [$0] } ?? [] }
    public init?(wireValue: String) {
        if let id = Self.operationIDsByWire[wireValue] { self = .operation(id); return }
        if wireValue.hasPrefix("content."), let kind = WorkflowDataKind(rawValue: String(wireValue.dropFirst(8))) {
            self = .content(kind); return
        }
        switch wireValue {
        case "音符序列": self = .structured(.notes)
        case "和弦轨": self = .structured(.chords)
        case "速度映射": self = .structured(.tempo)
        default: return nil
        }
    }
    public static let operationWireValues: [String: String] = [
        "d.asset.choose": "选择候选",
        "d.asset.export": "导出",
        "d.asset.reference": "项目素材",
        "d.audio.convert": "转换音频规格",
        "d.audio.trim": "截取音频",
        "d.control.branch": "条件选择",
        "d.control.human": "等待用户处理",
        "d.control.invoke": "使用自定义工具",
        "d.control.loop": "重复到满足条件",
        "d.control.map": "逐项执行",
        "d.image.convert": "转换图像",
        "d.image.flux2-dev": "FLUX.2-dev · BF16",
        "d.image.generate": "FLUX.2-klein-4B",
        "d.image.resize": "调整图像尺寸",
        "d.model.language": "Qwen2.5 Instruct · 兼容",
        "d.model.qwen35-9b": "Qwen3.5-9B",
        "d.model.qwen38-27b": "Qwen3.8-27B",
        "d.music.ace-step-1.5-xl-sft": "ACE-Step 1.5 XL SFT",
        "d.music.align": "解释节拍",
        "d.music.chords": "编写和声",
        "d.music.generate": "MRT2 small/export-v1",
        "d.music.keys": "查看调性候选",
        "d.music.pitch": "识别哼唱音高",
        "d.music.render": "音符合成试听",
        "d.text.confirm": "确认文字",
        "d.text.input": "文字输入",
        "d.text.remove-blank-lines": "移除空行",
        "d.text.rewrite": "文字改写",
        "d.text.template": "文字模板",
        "d.value.candidates": "候选转列表",
        "d.value.export": "导出文件",
        "d.value.field": "Field",
        "d.value.filter": "Filter",
        "d.value.input": "Data Input",
        "d.value.list": "List",
        "d.value.pair": "Pair",
        "d.value.record": "Record",
        "d.value.return": "Return",
        "d.value.select": "Select",
        "d.value.template": "Data Template",
        "d.value.validate": "Validate",
        "d.video.generate": "Wan2.1-T2V-1.3B",
        "d.video.ltx-2.3-dev-bf16-full-v1": "LTX 2.3 dev · BF16",
        "d.video.ltx-2.3-dev-q8-gemma3-q4-test-v1": "LTX 2.3 dev · Q8 / Gemma Q4",
        "d.video.ltx-2.5-dev-bf16-full-v1": "LTX-2.5 dev · BF16",
        "d.video.minimax-h3-fl2va-bf16-full-v1": "MiniMax H3 Base FL2VA · BF16",
    ]
    private static let operationIDsByWire = Dictionary(uniqueKeysWithValues: operationWireValues.map { ($0.value, $0.key) })
}
