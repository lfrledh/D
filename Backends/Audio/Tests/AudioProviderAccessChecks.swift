import Darwin
import Foundation

@main struct AudioProviderAccessChecks {
    static func main() throws {
        guard let path = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] else {
            throw NSError(domain: "Missing task temporary directory", code: 1)
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            .appendingPathComponent("host-access-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        let bootstrap = try directory("bootstrap"), model = try directory("模型 🎵"), run = try directory("run")
        let marker = model.appendingPathComponent("unchanged.txt")
        try Data("source".utf8).write(to: marker)
        var checks: [String] = []
        func expectFailure(_ title: String, _ body: () throws -> Void) throws {
            do { try body() } catch { checks.append(title); return }
            throw NSError(domain: "Expected failure: " + title, code: 1)
        }
        func require(_ value: Bool, _ title: String) throws {
            if !value { throw NSError(domain: title, code: 1) }
        }
        let id = UUID()
        let factory: (URL) throws -> Data = { Data(("fake-only:" + $0.lastPathComponent).utf8) }
        let access = try AudioProviderAccess.prepare(root: bootstrap, runID: id,
                                                     directories: [model, run], bookmark: factory)
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: access.manifest)) as! [String: Any]
        try require(value["runID"] as? String == id.uuidString.lowercased(), "run identity")
        let grants = value["grants"] as! [[String: String]]
        try require(Set(grants.compactMap { $0["path"] }) == Set([model.path, run.path]), "exact Unicode directories")
        let mode = try fm.attributesOfItem(atPath: access.manifest.path)[.posixPermissions] as! NSNumber
        try require(mode.intValue == 0o600, "private manifest mode")
        try access.finish()
        try require(!fm.fileExists(atPath: access.directory.path), "owned bootstrap removed")
        checks.append("exact-grants-private-manifest-balanced-cleanup")

        try expectFailure("empty-directory-list") {
            _ = try AudioProviderAccess.prepare(root: bootstrap, runID: id, directories: [], bookmark: factory)
        }
        try expectFailure("bootstrap-overlap") {
            _ = try AudioProviderAccess.prepare(root: bootstrap, runID: id, directories: [root], bookmark: factory)
        }
        let symlink = root.appendingPathComponent("linked-model")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: model)
        try expectFailure("symlink-grant") {
            _ = try AudioProviderAccess.prepare(root: bootstrap, runID: id, directories: [symlink], bookmark: factory)
        }
        let beforeFailure = try fm.contentsOfDirectory(atPath: bootstrap.path)
        var bookmarkFailed = false
        do {
            _ = try AudioProviderAccess.prepare(root: bootstrap, runID: id, directories: [model]) { _ in
                throw NSError(domain: "secret-capability-do-not-report", code: 1)
            }
        } catch {
            bookmarkFailed = true
            try require(!error.localizedDescription.contains("secret-capability"), "bookmark error redaction")
        }
        try require(bookmarkFailed, "bookmark factory failure propagated")
        try require(try fm.contentsOfDirectory(atPath: bootstrap.path) == beforeFailure, "preparation before publication")
        checks.append("bookmark-failure-redacted-no-publication")

        let changed = try AudioProviderAccess.prepare(root: bootstrap, runID: id, directories: [model], bookmark: factory)
        try Data("replacement".utf8).write(to: changed.manifest)
        try expectFailure("changed-manifest-preserved") { try changed.finish() }
        try require(try Data(contentsOf: changed.manifest) == Data("replacement".utf8), "replacement protected")

        let nonempty = try AudioProviderAccess.prepare(root: bootstrap, runID: id, directories: [run], bookmark: factory)
        let foreign = nonempty.directory.appendingPathComponent("unowned")
        try Data("keep".utf8).write(to: foreign)
        try expectFailure("foreign-file-preserved") { try nonempty.finish() }
        try require(try Data(contentsOf: foreign) == Data("keep".utf8), "foreign file protected")

        let moved = try AudioProviderAccess.prepare(root: bootstrap, runID: id, directories: [model], bookmark: factory)
        let retained = root.appendingPathComponent("retained-original-bootstrap")
        try fm.moveItem(at: moved.directory, to: retained)
        try fm.createSymbolicLink(at: moved.directory, withDestinationURL: model)
        try expectFailure("changed-directory-preserved") { try moved.finish() }
        try require(try Data(contentsOf: marker) == Data("source".utf8), "input unchanged")
        try require(fm.fileExists(atPath: retained.appendingPathComponent("access.json").path), "old manifest preserved")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["checks": checks,
            "fixtures": root.path, "realBookmarks": false, "sandboxApplication": false], options: [.sortedKeys]), as: UTF8.self))
    }
}
