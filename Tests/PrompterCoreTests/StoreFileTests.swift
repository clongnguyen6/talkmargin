import Foundation
import Testing
@testable import PrompterCore

struct StoreFileTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "mp-storefile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func missingAndValidFiles() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "conversations.json")
        guard case .missing = StoreFile.load([String].self, from: file, decoder: JSONDecoder()) else { Issue.record(); return }
        try Data(#"["a","b"]"#.utf8).write(to: file)
        guard case .value(let value) = StoreFile.load([String].self, from: file, decoder: JSONDecoder()) else { Issue.record(); return }
        #expect(value == ["a", "b"])
    }

    @Test func unreadableFileIsMovedAsideIntact() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "conversations.json")
        let bytes = Data(#"[{"id": "truncated"#.utf8)
        try bytes.write(to: file)
        guard case .setAside(let aside, _) = StoreFile.load([String].self, from: file, decoder: JSONDecoder(), now: now)
        else { Issue.record(); return }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(aside.deletingLastPathComponent().path == file.deletingLastPathComponent().path)
        #expect(aside.lastPathComponent.hasPrefix("conversations.unreadable-"))
        #expect(try Data(contentsOf: aside) == bytes)
        // A second bad file in the same second gets its own name.
        try bytes.write(to: file)
        guard case .setAside(let second, _) = StoreFile.load([String].self, from: file, decoder: JSONDecoder(), now: now)
        else { Issue.record(); return }
        #expect(second != aside)
        #expect(FileManager.default.fileExists(atPath: aside.path))
    }

    @Test func unmovableFileIsLockedNotLost() throws {
        let dir = try scratch()
        let file = dir.appending(path: "conversations.json")
        let bytes = Data("not json".utf8)
        try bytes.write(to: file)
        // A read-only folder: the file can be read but not moved.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        guard case .locked = StoreFile.load([String].self, from: file, decoder: JSONDecoder(), now: now) else { Issue.record(); return }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
