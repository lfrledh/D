import DWorkbench
import SwiftUI

/// One semantic mapping for port dots and the edges sourced from those ports.
enum WorkflowPortStyle {
    static let legend: [(String, WorkflowPortDefinition)] = [
        ("文字", .init("text", "", kinds: [.text])),
        ("图像", .init("image", "", kinds: [.image])),
        ("视频", .init("video", "", kinds: [.video])),
        ("音频", .init("audio", "", kinds: [.audio])),
        ("音符与音高", .init("notes", "", kinds: [.notes])),
        ("通用或未决", .init("generic", "", kinds: [.list]))
    ]

    static func kind(for port: WorkflowPortDefinition) -> WorkflowDataKind? {
        let kinds = Set(port.kinds)
        if let asset = port.assetListKind {
            guard kinds.contains(.list), kinds.subtracting([.list, asset]).isEmpty else { return nil }
            return asset
        }
        guard kinds.count == 1, let kind = kinds.first else { return nil }
        return kind
    }

    static func color(for port: WorkflowPortDefinition?) -> Color {
        guard let port, let kind = kind(for: port) else { return .secondary }
        switch kind {
        case .text: return Color(nsColor: .systemBlue)
        case .image, .images: return Color(red: 0.70, green: 0.39, blue: 0.10)
        case .video: return Color(nsColor: .systemPurple)
        case .audio: return Color(nsColor: .systemGreen)
        case .notes, .chords, .pitch, .tempo: return Color(nsColor: .systemPink)
        default: return .secondary
        }
    }

    static func label(for port: WorkflowPortDefinition?) -> String {
        guard let port else { return "未决类型" }
        if let kind = kind(for: port) { return WorkflowCanvasPresentation.kind(kind) }
        return port.kinds.isEmpty ? "未决类型" : port.kinds.map(WorkflowCanvasPresentation.kind).joined(separator: "/")
    }
}
