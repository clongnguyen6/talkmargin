import Foundation
import Synchronization

/// Languages the interface is translated into.
public enum UILanguage: String, CaseIterable, Sendable {
    case vi, en

    /// Formats dates and relative times in the interface language.
    public var locale: Locale { Locale(identifier: rawValue) }
    /// Label on the language selector.
    public var code: String { rawValue.uppercased() }
}

/// Interface strings, one table per language (`UIText+vi.swift`, `UIText+en.swift`).
/// Never used for text that reaches Claude (`ClaudeText`), notes or saved chats.
///
/// Missing key: the current language, then English, then Vietnamese, then the key's name.
/// `UITextTests` checks that every key is in both tables with the same placeholders.
public enum UIText {
    public typealias Table = [Key: String]

    static let tables: [UILanguage: Table] = [.vi: vietnamese, .en: english]
    static let fallbackOrder: [UILanguage] = [.en, .vi]

    private static let selected = Mutex(UILanguage.vi)
    /// Tests only: a language for the current task, without touching the global one.
    @TaskLocal static var override: UILanguage?

    /// The language shown; set once at launch (`UILanguagePreference`) and by the selector.
    public static var language: UILanguage {
        get { override ?? selected.withLock { $0 } }
        set { selected.withLock { $0 = newValue } }
    }

    public static func string(_ key: Key, in language: UILanguage? = nil, _ arguments: [String] = []) -> String {
        fill(lookup(key, in: language ?? self.language, tables: tables), arguments)
    }

    static func lookup(_ key: Key, in language: UILanguage, tables: [UILanguage: Table]) -> String {
        for candidate in [language] + fallbackOrder {
            if let text = tables[candidate]?[key] { return text }
        }
        return key.rawValue
    }

    /// Replaces `{0}`, `{1}`… in one pass, so an argument containing `{1}` is left alone.
    static func fill(_ template: String, _ arguments: [String]) -> String {
        guard !arguments.isEmpty else { return template }
        var result = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let tail = rest[rest.index(after: open)...]
            if let close = tail.firstIndex(of: "}"), let index = Int(tail[..<close]), arguments.indices.contains(index) {
                result += arguments[index]
                rest = tail[tail.index(after: close)...]
            } else {
                result += "{"
                rest = tail
            }
        }
        return result + rest
    }

    /// Placeholders used by a template, for checking translations against each other.
    static func placeholders(in template: String) -> Set<Int> {
        let pattern = /\{(\d+)\}/
        return Set(template.matches(of: pattern).compactMap { Int($0.1) })
    }
}

/// The interface string for `key` in the current language, with `{0}`, `{1}`… filled in.
public func tr(_ key: UIText.Key, _ arguments: CustomStringConvertible...) -> String {
    UIText.string(key, arguments.map(\.description))
}

/// Which language a launch shows: the saved choice, else Vietnamese for an existing install
/// (the interface was Vietnamese only before), else the first of the macOS preferred languages
/// that is translated, else English. The decision is saved at once, so it never changes later
/// unless the user picks another language.
public enum UILanguagePreference {
    public static let key = "uiLanguage"

    /// `hasOtherSettings`: the settings domain held any key before this launch. Every earlier
    /// version writes some (`overlayVisible` when the overlay first shows, frames, recents),
    /// and nothing else writes a domain before the app first runs.
    public static func decide(stored: String?, hasOtherSettings: Bool, preferredLanguages: [String]) -> UILanguage {
        if let stored, let language = UILanguage(rawValue: stored) { return language }
        return hasOtherSettings ? .vi : fromPreferred(preferredLanguages)
    }

    /// The first preferred language that is translated (`en-VN` is English, `vi-VN` Vietnamese).
    public static func fromPreferred(_ preferredLanguages: [String]) -> UILanguage {
        for identifier in preferredLanguages {
            let code = Locale.Language(identifier: identifier).languageCode?.identifier
            if let language = code.flatMap(UILanguage.init(rawValue:)) { return language }
        }
        return .en
    }

    /// Reads the choice from `domain` in `defaults`, deciding and saving it when there is none.
    public static func load(from defaults: UserDefaults, domain: String,
                            preferredLanguages: [String] = Locale.preferredLanguages) -> UILanguage {
        let stored = defaults.string(forKey: key)
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        let language = decide(stored: stored, hasOtherSettings: saved.keys.contains { $0 != key },
                              preferredLanguages: preferredLanguages)
        if stored != language.rawValue { store(language, in: defaults) }
        return language
    }

    public static func store(_ language: UILanguage, in defaults: UserDefaults) {
        defaults.set(language.rawValue, forKey: key)
    }
}
