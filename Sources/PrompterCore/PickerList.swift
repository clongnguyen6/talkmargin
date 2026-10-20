import Foundation

/// Keyboard navigation over a picker's rows, some of which (group headers,
/// notices) cannot be chosen.
public enum PickerList {
    /// The next selectable row from `current` in `direction` (+1 down, -1 up),
    /// wrapping around. With no current row, the first selectable row in that
    /// direction from the respective end. `nil` when nothing is selectable.
    public static func move(from current: Int?, by direction: Int, selectable: [Bool]) -> Int? {
        let count = selectable.count
        guard count > 0, selectable.contains(true) else { return nil }
        let step = direction >= 0 ? 1 : -1
        var index = current.map { ($0 + step + count) % count } ?? (step > 0 ? 0 : count - 1)
        for _ in 0..<count {
            if selectable[index] { return index }
            index = (index + step + count) % count
        }
        return nil
    }

    /// The row of the `ordinal`-th (1-based) selectable entry, as typed with ⌥1…⌥9.
    public static func ordinal(_ ordinal: Int, selectable: [Bool]) -> Int? {
        guard ordinal >= 1 else { return nil }
        var seen = 0
        for (index, isSelectable) in selectable.enumerated() where isSelectable {
            seen += 1
            if seen == ordinal { return index }
        }
        return nil
    }
}

/// Short labels for file paths shown in the document picker.
public enum PathLabel {
    /// The file's folder with the home directory shortened to `~`, e.g. `~/Documents/notes`.
    public static func folder(of path: String, home: String) -> String {
        abbreviated((path as NSString).deletingLastPathComponent, home: home)
    }

    /// A directory path with the home directory shortened to `~`.
    public static func abbreviated(_ directory: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if directory == home { return "~" }
        if !home.isEmpty, directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory.isEmpty ? "/" : directory
    }
}
