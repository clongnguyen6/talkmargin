import AppKit
import PrompterCore

@MainActor
final class Settings {
    static let fontSizeRange: ClosedRange<Double> = 12...48


    private let defaults = UserDefaults.standard
    private let maxRecentFiles = 10

    init() {
        migratePathKeys()
    }

    var fontSize: Double {
        get { defaults.object(forKey: "fontSize") as? Double ?? 20 }
        set { defaults.set(min(max(newValue, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound), forKey: "fontSize") }
    }

    // MARK: Display

    static let defaultBackdrop = 0.8
    static let defaultTextBand = 0.0
    static let defaultTextOpacity = 1.0

    /// 0...1 darkness of the backdrop behind everything.
    var opacity: Double {
        get { defaults.object(forKey: "opacity") as? Double ?? Self.defaultBackdrop }
        set { defaults.set(min(max(newValue, 0), 1), forKey: "opacity") }
    }

    /// Blur the apps behind the overlay. Off lets them show through, e.g. a shared screen.
    var blurBehind: Bool {
        get { defaults.object(forKey: "blurBehind") as? Bool ?? (opacity >= 0.7) }
        set { defaults.set(newValue, forKey: "blurBehind") }
    }

    /// 0...1 darkness of the subtitle-style band behind the text; 0 is off.
    var textBand: Double {
        get { defaults.object(forKey: "textBand") as? Double ?? (blurBehind ? Self.defaultTextBand : 0.62) }
        set { defaults.set(min(max(newValue, 0), 1), forKey: "textBand") }
    }

    /// 0.4...1 opacity of the text itself.
    var textOpacity: Double {
        get { min(max(defaults.object(forKey: "textOpacity") as? Double ?? Self.defaultTextOpacity, 0.4), 1) }
        set { defaults.set(min(max(newValue, 0.4), 1), forKey: "textOpacity") }
    }

    func resetDisplay() {
        for key in ["opacity", "blurBehind", "textBand", "textOpacity"] { defaults.removeObject(forKey: key) }
        opacity = Self.defaultBackdrop
        blurBehind = true
        textBand = Self.defaultTextBand
        textOpacity = Self.defaultTextOpacity
    }

    /// Interface language, decided at launch (`UILanguagePreference.load` in main.swift). Not a
    /// display setting: `resetDisplay` leaves it.
    var language: UILanguage {
        get { UIText.language }
        set {
            UILanguagePreference.store(newValue, in: defaults)
            UIText.language = newValue
        }
    }

    var overlayVisible: Bool {
        get { defaults.object(forKey: "overlayVisible") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "overlayVisible") }
    }

    var outlineVisible: Bool {
        get { defaults.bool(forKey: "outlineVisible") }
        set { defaults.set(newValue, forKey: "outlineVisible") }
    }

    static let outlineWidthRange: ClosedRange<CGFloat> = 110...360
    static let defaultOutlineWidth: CGFloat = 180

    var outlineWidth: CGFloat {
        get { (defaults.object(forKey: "outlineWidth") as? CGFloat).map { min(max($0, 110), 360) } ?? Self.defaultOutlineWidth }
        set { defaults.set(min(max(newValue, Self.outlineWidthRange.lowerBound), Self.outlineWidthRange.upperBound), forKey: "outlineWidth") }
    }

    var chatVisible: Bool {
        get { defaults.bool(forKey: "chatVisible") }
        set { defaults.set(newValue, forKey: "chatVisible") }
    }

    /// Share of the width given to the notes when the chat column is open.
    var chatRatio: CGFloat {
        get { min(max(defaults.object(forKey: "chatRatio") as? CGFloat ?? 0.6, 0.4), 0.8) }
        set { defaults.set(min(max(newValue, 0.4), 0.8), forKey: "chatRatio") }
    }

    var expanded: Bool {
        get { defaults.bool(forKey: "expanded") }
        set { defaults.set(newValue, forKey: "expanded") }
    }

    /// Last frame of the compact or expanded overlay; each mode remembers its own.
    func frame(expanded: Bool) -> NSRect? {
        defaults.string(forKey: expanded ? "expandedFrame" : "compactFrame").map(NSRectFromString)
    }

    func setFrame(_ frame: NSRect, expanded: Bool) {
        defaults.set(NSStringFromRect(frame), forKey: expanded ? "expandedFrame" : "compactFrame")
    }

    /// Claude Code session the meeting assistant forks from, kept across launches.
    var linkedSession: ClaudeSession? {
        get {
            guard let value = defaults.dictionary(forKey: "linkedSession"),
                  let id = value["id"] as? String, let cwd = value["cwd"] as? String, let title = value["title"] as? String
            else { return nil }
            return ClaudeSession(id: id, cwd: cwd, title: title, modified: value["modified"] as? Date ?? .distantPast)
        }
        set {
            defaults.set(newValue.map { ["id": $0.id, "cwd": $0.cwd, "title": $0.title, "modified": $0.modified] },
                         forKey: "linkedSession")
        }
    }

    var lastFile: String? {
        get { defaults.string(forKey: "lastFile") }
        set { defaults.set(newValue, forKey: "lastFile") }
    }

    var recentFiles: [String] {
        get { defaults.stringArray(forKey: "recentFiles") ?? [] }
        set { defaults.set(newValue, forKey: "recentFiles") }
    }

    /// Recent files that still exist and are of a type `NotesLoader` reads; the one list every picker shows.
    var openableRecentFiles: [String] {
        recentFiles.filter { FileManager.default.fileExists(atPath: $0) && NotesLoader.isSupported(URL(fileURLWithPath: $0)) }
    }

    /// File keys (last file, recents, reading positions) are `NotesPath.canonical`. At launch saved
    /// keys are only merged by `NotesPath.lexical` (e.g. `/private/tmp/…` from the open dialog),
    /// without the disk: a stale network volume must not hang launch. Spellings through a
    /// symlinked folder are merged when the file is opened (`noteOpened`).
    private func migratePathKeys() {
        let recents = recentFiles
        let merged = NotesPath.mergedRecents(recents, canonical: NotesPath.lexical)
        if merged != recents { recentFiles = merged }
        if let last = lastFile, NotesPath.lexical(last) != last { lastFile = NotesPath.lexical(last) }
        if let offsets = defaults.dictionary(forKey: "scrollOffsets") {
            let lexical = NotesPath.mergedValues(offsets, recents: recents, canonical: NotesPath.lexical)
            if Set(lexical.keys) != Set(offsets.keys) { defaults.set(lexical, forKey: "scrollOffsets") }
        }
    }

    /// `url` must be canonical (`OverlayController.open` makes it so). Recents naming the same
    /// file in another spelling are merged into it, keeping their reading position if it has none.
    func noteOpened(_ url: URL) {
        let path = url.path
        let aliases = NotesPath.aliases(of: path, in: recentFiles)
        if !aliases.isEmpty, var offsets = defaults.dictionary(forKey: "scrollOffsets") {
            if offsets[path] == nil, let kept = aliases.lazy.compactMap({ offsets[$0] }).first { offsets[path] = kept }
            for alias in aliases { offsets[alias] = nil }
            defaults.set(offsets, forKey: "scrollOffsets")
        }
        lastFile = path
        recentFiles = Array(([path] + recentFiles.filter { $0 != path && !aliases.contains($0) }).prefix(maxRecentFiles))
    }

    func scrollOffset(for path: String) -> Double {
        (defaults.dictionary(forKey: "scrollOffsets")?[path] as? Double) ?? 0
    }

    func setScrollOffset(_ offset: Double, for path: String) {
        var offsets = defaults.dictionary(forKey: "scrollOffsets") ?? [:]
        offsets[path] = offset
        defaults.set(offsets, forKey: "scrollOffsets")
    }
}
