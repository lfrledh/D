import AppKit
import CryptoKit
import Foundation
import SwiftUI

struct WorkbenchNoticeFile: Identifiable, Sendable, Equatable {
    let group: String
    let relativePath: String
    let root: URL
    let byteCount: Int?
    let sha256: String?
    var id: String { group + ":" + relativePath }
}

enum WorkbenchNoticeReader {
    private struct Manifest: Decodable {
        struct File: Decodable { let path: String; let sizeBytes: Int; let sha256: String }
        let files: [File]
    }
    static func location(root: URL, relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CocoaError(.fileReadInvalidFileName) }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]).isSymbolicLink != true,
              try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoPermission) }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        return url
    }
    static func index(engines: URL, ui: URL) throws -> [WorkbenchNoticeFile] {
        for root in [engines, ui] {
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        }
        var result: [WorkbenchNoticeFile] = []
        for path in ["Chat-Third-Party-Notices.txt", "Mermaid/THIRD-PARTY-NOTICES.txt", "Mermaid/LICENSE"] {
            _ = try location(root: ui, relative: path)
            result.append(.init(group: "D UI", relativePath: path, root: ui, byteCount: nil, sha256: nil))
        }
        // Only the seven packaged runtimes and files in their signed inventories.
        for name in ["AudioEngine", "MRT2MusicEngine", "VideoEngine", "PitchEngine", "ExternalVideoEngine", "ACEMusicEngine", "ChatPython"] {
            let root = engines.appendingPathComponent(name + ".dengine")
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let manifest = try location(root: root, relative: "engine.json")
            guard (try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let files = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest)).files
            for file in files {
                let base = URL(fileURLWithPath: file.path).lastPathComponent.uppercased()
                let notice = file.path.split(separator: "/").contains { $0.uppercased() == "LICENSES" } || ["LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS"].contains { base.contains($0) }
                let source = ["SOURCE.JSON", "SOURCES.JSON", "RUNTIME-ORIGIN.JSON", "PROVENANCE.JSON", "FFMPEG-9.0.1-SOURCE.JSON"].contains(base)
                if (notice || source), file.sizeBytes <= 1024 * 1024 {
                    result.append(.init(group: name, relativePath: file.path, root: root, byteCount: file.sizeBytes, sha256: file.sha256))
                }
            }
        }
        return result.sorted { ($0.group, $0.relativePath) < ($1.group, $1.relativePath) }
    }
    static func text(_ file: WorkbenchNoticeFile) throws -> String {
        let url = try location(root: file.root, relative: file.relativePath)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 1024 * 1024, file.byteCount.map({ $0 == bytes.count }) ?? true,
              file.sha256.map({ $0 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }) ?? true,
              let text = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return text
    }
}

struct WorkbenchThirdPartyNotices: View {
    @Environment(\.dLanguageStore) private var language
    @State private var files: [WorkbenchNoticeFile] = []
    @State private var selection: String?
    @State private var bodyText = ""
    @State private var failed = false
    private func t(_ key: String) -> String { workflowText(language, "notices." + key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("scope")).font(.caption).foregroundStyle(.secondary)
            if failed { Text(t("unavailable")).foregroundStyle(.red) }
            HStack(spacing: 16) {
                List(selection: $selection) {
                    ForEach(files) { file in
                        VStack(alignment: .leading) {
                            Text(file.group).font(.caption).foregroundStyle(.secondary)
                            Text(file.relativePath).font(.caption).lineLimit(2)
                        }.tag(file.id)
                    }
                }.frame(width: 250).accessibilityLabel(t("list"))
                NoticeReadOnlyText(text: bodyText).accessibilityLabel(t("document"))
            }
        }.padding(20).frame(width: 760, height: 540)
        .task {
            guard let engines = Bundle.main.resourceURL?.appendingPathComponent("Engines"), let ui = Bundle.module.resourceURL else { failed = true; return }
            do { files = try await Task.detached(priority: .utility) { try WorkbenchNoticeReader.index(engines: engines, ui: ui) }.value; selection = files.first?.id }
            catch { failed = true }
        }
        .task(id: selection) {
            guard let file = files.first(where: { $0.id == selection }) else { bodyText = ""; return }
            do {
                let value = try await Task.detached(priority: .utility) { try WorkbenchNoticeReader.text(file) }.value
                guard !Task.isCancelled else { return }; bodyText = value; failed = false
            } catch { guard !Task.isCancelled else { return }; bodyText = ""; failed = true }
        }
    }
}

private struct NoticeReadOnlyText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), editor = NSTextView()
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.drawsBackground = false; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = .labelColor; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text; editor.scrollToBeginningOfDocument(nil)
    }
}
