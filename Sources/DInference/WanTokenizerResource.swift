/// Fixed learned tokenizer resources belonging to the selected Wan model, never
/// executable runtime code or part of the application bundle.
public struct WanTokenizerResource: Sendable, Equatable {
    public let name: String
    public let size: UInt64
    public let sha256: String
    public var sourcePath: String { "google/umt5-xxl/" + name }
    public var preparedPath: String { "tokenizer/" + name }
    public static let files: [Self] = [
        .init(name: "special_tokens_map.json", size: 6623, sha256: "7b8a9f5040adb67b5805abdfd42c1f8d0f3d0e711f10726580eb3789cd0ad61d"),
        .init(name: "spiece.model", size: 4548313, sha256: "e3909a67b780650b35cf529ac782ad2b6b26e6d1f849d3fbb6a872905f452458"),
        .init(name: "tokenizer.json", size: 16837417, sha256: "6e197b4d3dbd71da14b4eb255f4fa91c9c1f2068b20a2de2472967ca3d22602b"),
        .init(name: "tokenizer_config.json", size: 61728, sha256: "ed9a3a8b0faa71a70a32847e0435fe036e6e112d4df4edb7bb48a921e344dc05"),
    ]
}
