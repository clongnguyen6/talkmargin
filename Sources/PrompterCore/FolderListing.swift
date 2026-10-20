import Foundation

/// What the in-overlay folder browser shows of a directory: visible subfolders
/// first, then files of a supported type, each sorted by name.
public enum FolderListing {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool

        public init(name: String, isDirectory: Bool) {
            self.name = name
            self.isDirectory = isDirectory
        }
    }

    public static func rows(_ entries: [Entry], supportedExtensions: [String]) -> [Entry] {
        let visible = entries.filter { !$0.name.hasPrefix(".") }
        let supported = Set(supportedExtensions.map { $0.lowercased() })
        let byName: (Entry, Entry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let folders = visible.filter(\.isDirectory).sorted(by: byName)
        let files = visible.filter { !$0.isDirectory && supported.contains(($0.name as NSString).pathExtension.lowercased()) }
            .sorted(by: byName)
        return folders + files
    }
}
