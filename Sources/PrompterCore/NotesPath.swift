import Foundation

/// One spelling per notes file, used for every key: recent files, reading positions
/// and Claude's document identity. The open dialog returns `/private/tmp/…` for a
/// file the recents hold as `/tmp/…`; both must be the same key.
public enum NotesPath {
    /// The folder canonicalized (symlinks resolved on the part that exists), the file's
    /// own name kept as given: a `current.md` link the user re-points stays the link.
    /// The `/private` roots macOS links from `/tmp`, `/var` and `/etc` are written
    /// without `/private` whether or not the file exists (Word replaces files on save,
    /// so a key must not change while one is briefly missing). Touches the disk.
    public static func canonical(_ path: String) -> String {
        let path = lexical(path)
        guard path != "/" else { return path }
        let name = (path as NSString).lastPathComponent
        var existing = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().path
        for component in missing + [name] { resolved = (resolved as NSString).appendingPathComponent(component) }
        return withoutPrivateRoot(resolved)
    }

    public static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: canonical(url.path))
    }

    /// `canonical` without the disk: empty, `.` and `..` components removed and the
    /// `/private` roots dropped. For keys that need not be resolved now (saved data at launch).
    public static func lexical(_ path: String) -> String {
        let path = path.hasPrefix("/") ? path : URL(fileURLWithPath: path).path
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return withoutPrivateRoot("/" + parts.joined(separator: "/"))
    }

    static func withoutPrivateRoot(_ path: String) -> String {
        for root in ["/private/tmp", "/private/var", "/private/etc"] where path == root || path.hasPrefix(root + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// Entries of `paths` naming the file at canonical `path` in another spelling. Only
    /// same-named entries are resolved (`canonical` keeps names), so the disk is touched rarely.
    public static func aliases(of path: String, in paths: [String], canonical: (String) -> String = canonical) -> [String] {
        let name = (path as NSString).lastPathComponent
        return paths.filter { $0 != path && ($0 as NSString).lastPathComponent == name && canonical($0) == path }
    }

    /// Saved recent files in `canonical` form (at launch: `lexical`), most recent first, each file once.
    public static func mergedRecents(_ paths: [String], canonical: (String) -> String = canonical) -> [String] {
        var seen = Set<String>()
        return paths.map(canonical).filter { seen.insert($0).inserted }
    }

    /// Saved per-file values (reading positions) keyed canonically. When several old
    /// keys name one file, the one already in canonical form wins (the form the
    /// recents and the picker used), else the one opened most recently per `recents`.
    public static func mergedValues<Value>(_ values: [String: Value], recents: [String],
                                           canonical: (String) -> String = canonical) -> [String: Value] {
        let rank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [String: (value: Value, score: (Int, Int, String))] = [:]
        for (key, value) in values {
            let target = canonical(key)
            // Lower wins: canonical form first, then recency, then the key itself for a stable result.
            let score = (key == target ? 0 : 1, rank[key] ?? Int.max, key)
            if let current = merged[target], current.score <= score { continue }
            merged[target] = (value, score)
        }
        return merged.mapValues(\.value)
    }
}

extension NotesVersion {
    /// The same version under another spelling of its path.
    public func mapPath(_ transform: (String) -> String) -> NotesVersion {
        NotesVersion(path: path.map(transform), digest: digest)
    }
}

extension NotesContext {
    /// Paths rewritten by `transform`; versions that now name the same document
    /// keep only the latest, as `delivered` holds one version per document.
    public func mapPaths(_ transform: (String) -> String) -> NotesContext {
        var versions: [NotesVersion] = []
        for version in delivered.map({ $0.mapPath(transform) }) {
            versions.removeAll { $0.isSameDocument(as: version) }
            versions.append(version)
        }
        return NotesContext(current: current?.mapPath(transform), delivered: versions)
    }
}
