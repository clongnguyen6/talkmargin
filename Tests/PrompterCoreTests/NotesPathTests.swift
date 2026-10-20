import Foundation
import Testing
@testable import PrompterCore

struct NotesPathTests {
    /// A fresh directory under /tmp (a symlink to /private/tmp), removed by the caller.
    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/mp-notespath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func privateTmpAndTmpAreOneKey() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "A-notes.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let key = NotesPath.canonical(file.path)
        #expect(key == file.path)
        #expect(NotesPath.canonical("/private" + file.path) == key)
    }

    @Test func missingFileKeepsItsKey() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Mid-save: Word has removed the file and not written the new one yet.
        let file = dir.appending(path: "brief.docx").path
        #expect(NotesPath.canonical(file) == file)
        #expect(NotesPath.canonical("/private" + file) == file)
        #expect(NotesPath.canonical("/private/tmp/no-such-dir/x.md") == "/tmp/no-such-dir/x.md")
    }

    @Test func temporaryDirectoryUnderVar() throws {
        // /var/folders/… is /private/var/folders/… on disk.
        let dir = FileManager.default.temporaryDirectory.appending(path: "mp-notespath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "n.md").path
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let real = (try FileManager.default.destinationOfSymbolicLink(atPath: "/var")).hasPrefix("private")
            ? file.replacingOccurrences(of: "/var/", with: "/private/var/") : file
        #expect(NotesPath.canonical(real) == NotesPath.canonical(file))
        #expect(!NotesPath.canonical(file).hasPrefix("/private/"))
    }

    @Test func dotsAndSymlinkedFoldersResolve() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "x".write(to: real.appending(path: "n.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "link"), withDestinationURL: real)
        let key = real.appending(path: "n.md").path
        #expect(NotesPath.canonical(dir.path + "/link/n.md") == key)
        #expect(NotesPath.canonical(dir.path + "/real/./../real/n.md") == key)
        // A file not yet there, inside a linked folder.
        #expect(NotesPath.canonical(dir.path + "/link/new.md") == real.appending(path: "new.md").path)
    }

    @Test func symlinkedFileKeepsItsOwnName() throws {
        // A `current.md` link the user re-points: the key is the link, not today's target.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "2026-10-18.md")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appending(path: "current.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(NotesPath.canonical(link.path) == link.path)
        #expect(NotesPath.canonical("/private" + link.path) == link.path)
        // A link in a linked folder: the folder resolves, the name stays.
        let real = dir.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: real.appending(path: "current.md"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "folder-link"), withDestinationURL: real)
        #expect(NotesPath.canonical(dir.path + "/folder-link/current.md") == real.appending(path: "current.md").path)
    }

    @Test func lexicalNeedsNoDisk() {
        #expect(NotesPath.lexical("/private/tmp/e2e/../e2e/./A.md") == "/tmp/e2e/A.md")
        #expect(NotesPath.lexical("//Users/me//notes/a.md") == "/Users/me/notes/a.md")
        #expect(NotesPath.lexical("/private/var/folders/x/n.md") == "/var/folders/x/n.md")
        #expect(NotesPath.lexical("/Volumes/stale-share/notes.md") == "/Volumes/stale-share/notes.md")
        #expect(NotesPath.lexical("/") == "/")
    }

    @Test func aliasesAreSameNamedOtherSpellings() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "x".write(to: real.appending(path: "n.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "link"), withDestinationURL: real)
        let path = real.appending(path: "n.md").path
        let recents = [path, dir.path + "/link/n.md", dir.path + "/link/other.md", "/elsewhere/n.md"]
        #expect(NotesPath.aliases(of: path, in: recents) == [dir.path + "/link/n.md"])
        // Differently named entries are never resolved.
        var resolved: [String] = []
        _ = NotesPath.aliases(of: "/a/n.md", in: ["/b/x.md", "/c/n.md"]) { resolved.append($0); return $0 }
        #expect(resolved == ["/c/n.md"])
    }

    @Test func onlyTheLinkedPrivateRootsLoseTheirPrefix() {
        #expect(NotesPath.withoutPrivateRoot("/private/etc/hosts") == "/etc/hosts")
        #expect(NotesPath.withoutPrivateRoot("/private/var") == "/var")
        #expect(NotesPath.withoutPrivateRoot("/private/tmpfoo/x") == "/private/tmpfoo/x")
        #expect(NotesPath.withoutPrivateRoot("/Users/me/private/tmp/x") == "/Users/me/private/tmp/x")
    }

    // MARK: - Saved defaults

    /// Stand-in for the file system: strips /private like the real one does for /tmp.
    private let fake: (String) -> String = { NotesPath.withoutPrivateRoot($0) }

    @Test func recentsMergeKeepsTheMostRecentPosition() {
        // The device run's defaults after opening A through the dialog.
        let saved = ["/private/tmp/e2e/notes/A.md", "/tmp/e2e/notes/B.docx", "/tmp/e2e/notes/A.md"]
        #expect(NotesPath.mergedRecents(saved, canonical: fake) == ["/tmp/e2e/notes/A.md", "/tmp/e2e/notes/B.docx"])
        #expect(NotesPath.mergedRecents(["/a.md", "/b.md"], canonical: fake) == ["/a.md", "/b.md"])
    }

    @Test func offsetsMergeKeepsTheCanonicalEntry() {
        let recents = ["/private/tmp/e2e/notes/A.md", "/tmp/e2e/notes/B.docx", "/tmp/e2e/notes/A.md"]
        let offsets: [String: Double] = [
            "/private/tmp/e2e/notes/A.md": 0, "/tmp/e2e/notes/A.md": 345, "/tmp/e2e/notes/B.docx": 664,
        ]
        let merged = NotesPath.mergedValues(offsets, recents: recents, canonical: fake)
        #expect(merged == ["/tmp/e2e/notes/A.md": 345, "/tmp/e2e/notes/B.docx": 664])
    }

    @Test func offsetsWithOnlyOtherSpellingsTakeTheMostRecent() {
        let recents = ["/private/tmp/x/../n.md", "/private/tmp/n.md"]
        let offsets: [String: Double] = ["/private/tmp/n.md": 10, "/private/tmp/x/../n.md": 20]
        let standardize: (String) -> String = { NotesPath.withoutPrivateRoot(($0 as NSString).standardizingPath) }
        #expect(NotesPath.mergedValues(offsets, recents: recents, canonical: standardize) == ["/tmp/n.md": 20])
    }

    @Test func existingCanonicalDefaultsAreUnchanged() {
        let recents = ["/Users/me/notes/a.md", "/Users/me/b.docx"]
        let offsets: [String: Double] = ["/Users/me/notes/a.md": 12, "/Users/me/b.docx": 0]
        #expect(NotesPath.mergedRecents(recents, canonical: fake) == recents)
        #expect(NotesPath.mergedValues(offsets, recents: recents, canonical: fake) == offsets)
    }

    // MARK: - Claude's document identity

    @Test func savedContextUnderOtherSpellingStillMatches() {
        let markdown = "# Heron\n\nPostgreSQL 17."
        let saved = NotesContext(current: NotesVersion(path: "/private/tmp/e2e/B.docx", markdown: markdown),
                                 delivered: [NotesVersion(path: "/private/tmp/e2e/B.docx", markdown: "old"),
                                             NotesVersion(path: "/tmp/e2e/A.md", markdown: "a"),
                                             NotesVersion(path: "/tmp/e2e/B.docx", markdown: markdown)])
        #expect(!NotesDelivery.isCurrent(path: "/tmp/e2e/B.docx", markdown: markdown, in: saved))
        let migrated = saved.mapPaths(fake)
        #expect(NotesDelivery.isCurrent(path: "/tmp/e2e/B.docx", markdown: markdown, in: migrated))
        // One version per document, the latest kept, digests untouched.
        #expect(migrated.delivered.map(\.path) == ["/tmp/e2e/A.md", "/tmp/e2e/B.docx"])
        #expect(migrated.delivered.last == NotesVersion(path: "/tmp/e2e/B.docx", markdown: markdown))
        let plan = NotesDelivery.plan(path: "/tmp/e2e/B.docx", markdown: markdown, context: migrated, hasHistory: true) { _ in nil }
        #expect(plan.kind == .none)
    }

    @Test func unsavedNotesKeepNoPath() {
        let version = NotesVersion(path: nil, markdown: "help")
        #expect(version.mapPath(fake) == version)
    }
}
