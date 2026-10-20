import Foundation

/// The headings that split a document into meeting sections.
public enum Sections {
    /// A lone top-level title with level-2 headings under it means the level-2
    /// headings are the sections; otherwise the highest heading level is used.
    public static func sections(in headings: [Heading]) -> [Heading] {
        guard let top = headings.map(\.level).min() else { return [] }
        let topCount = headings.filter { $0.level == top }.count
        if topCount == 1, let next = headings.map(\.level).filter({ $0 > top }).min() {
            return headings.filter { $0.level == next }
        }
        return headings.filter { $0.level == top }
    }
}
