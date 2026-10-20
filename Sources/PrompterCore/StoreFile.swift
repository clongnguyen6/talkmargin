import Foundation

/// Loads a JSON store file without ever losing it. A file that exists but cannot be read
/// or decoded is moved aside before the store starts empty; if it cannot be moved, the
/// store must not save at all, so the next save never writes over the user's data.
public enum StoreFile {
    public enum Loaded<Value> {
        case value(Value)
        /// No file yet.
        case missing
        /// Unreadable; moved to `aside`, the store starts empty and may save.
        case setAside(aside: URL, error: Error)
        /// Unreadable and could not be moved: start empty and never save.
        case locked(error: Error)
    }

    public static func load<Value: Decodable>(_ type: Value.Type, from file: URL, decoder: JSONDecoder,
                                              now: Date = Date()) -> Loaded<Value> {
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        let failure: Error
        do {
            return .value(try decoder.decode(type, from: Data(contentsOf: file)))
        } catch {
            failure = error
        }
        let aside = asideURL(for: file, now: now)
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            return .setAside(aside: aside, error: failure)
        } catch {
            return .locked(error: failure)
        }
    }

    /// `conversations.json` → `conversations.unreadable-20261018-171500.json`, next to it.
    static func asideURL(for file: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = file.deletingPathExtension().lastPathComponent
        var url = file.deletingLastPathComponent().appending(path: "\(stem).unreadable-\(formatter.string(from: now)).\(file.pathExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = file.deletingLastPathComponent().appending(path: "\(stem).unreadable-\(formatter.string(from: now))-\(n).\(file.pathExtension)")
            n += 1
        }
        return url
    }
}
