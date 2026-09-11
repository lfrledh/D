import Foundation

/// A presentation workspace inside one project; not a storage partition or model identity.
public enum CreatorMode: String, CaseIterable, Hashable, Sendable, Identifiable {
    case image, text, audio
    public var id: Self { self }
    public init(_ kind: ProjectDocumentKind) {
        switch kind { case .image: self = .image; case .text: self = .text; case .audio: self = .audio }
    }
    public var title: String { switch self { case .image: "图像"; case .text: "文字"; case .audio: "音频" } }
    public var symbol: String { switch self { case .image: "photo"; case .text: "text.alignleft"; case .audio: "waveform" } }
    public var newDocumentTitle: String { switch self { case .image: "新建图像创作"; case .text: "新建文稿"; case .audio: "新建声音创作" } }
}
