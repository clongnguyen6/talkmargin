import Foundation
import Testing
@testable import PrompterCore

struct UITextTests {
    // MARK: - Tables

    @Test func everyKeyIsInBothLanguages() {
        for language in UILanguage.allCases {
            let table = UIText.tables[language] ?? [:]
            let missing = UIText.Key.allCases.filter { (table[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            #expect(missing.isEmpty, "\(language): no text for \(missing)")
        }
    }

    @Test func translationsUseTheSamePlaceholders() {
        for key in UIText.Key.allCases {
            let vi = UIText.placeholders(in: UIText.vietnamese[key] ?? "")
            let en = UIText.placeholders(in: UIText.english[key] ?? "")
            #expect(vi == en, "\(key): vi \(vi.sorted()) en \(en.sorted())")
            // Placeholders are numbered from 0 without gaps, as `tr` fills them.
            #expect(vi == Set(0..<vi.count), "\(key)")
        }
    }

    @Test func noEmDash() {
        for (language, table) in UIText.tables {
            for (key, text) in table { #expect(!text.contains("\u{2014}"), "\(language) \(key)") }
        }
    }

    /// The only keys meant to read the same in both languages: the status menu's language item,
    /// so it can be found whatever the interface language. Adding to this set is a deliberate choice.
    private static let sameInBothLanguages: Set<UIText.Key> = [.menuLanguage, .languageVietnamese, .languageEnglish]

    @Test func englishIsNotVietnamese() {
        // A key copied over untranslated, apart from the deliberate exceptions above.
        let same = UIText.Key.allCases.filter { UIText.vietnamese[$0] == UIText.english[$0] }
        #expect(Set(same) == Self.sameInBothLanguages, "untranslated: \(Set(same).subtracting(Self.sameInBothLanguages)); exempt but translated: \(Self.sameInBothLanguages.subtracting(same))")
    }

    // MARK: - Status menu language item

    @Test func languageMenuReadsTheSameInBothLanguages() {
        for language in UILanguage.allCases {
            UIText.$override.withValue(language) {
                #expect(LanguageMenu.title == "Ngôn ngữ / Language")
                #expect(LanguageMenu.choices(current: .vi).map(\.title) == ["Tiếng Việt", "English"])
            }
        }
    }

    @Test func languageMenuChecksTheCurrentLanguage() {
        for current in UILanguage.allCases {
            let choices = LanguageMenu.choices(current: current)
            #expect(choices.map(\.language) == [.vi, .en])
            #expect(choices.filter(\.isCurrent).map(\.language) == [current])
        }
    }

    /// The menu and the display settings selector go through one switch (`OverlayController.setLanguage`).
    @Test func languageMenuUsesTheSelectorsSwitch() throws {
        let app = Self.sources.appending(path: "MeetingPrompter")
        let delegate = try String(contentsOf: app.appending(path: "AppDelegate.swift"), encoding: .utf8)
        let overlay = try String(contentsOf: app.appending(path: "OverlayController.swift"), encoding: .utf8)
        #expect(delegate.contains("menu.addItem(languageItem())"))
        #expect(delegate.contains("overlay.setLanguage(language)"))
        #expect(overlay.contains("case .language(let language): setLanguage(language)"))
        #expect(overlay.contains("func setLanguage(_ language: UILanguage) {"))
    }

    // MARK: - Lookup

    @Test func missingKeyFallsBackToEnglishThenVietnameseThenTheKeyName() {
        let tables: [UILanguage: UIText.Table] = [
            .vi: [.menuQuit: "Thoát", .menuReload: "Tải lại"],
            .en: [.menuQuit: "Quit", .menuHelp: "Shortcuts & help"],
        ]
        #expect(UIText.lookup(.menuQuit, in: .vi, tables: tables) == "Thoát")
        #expect(UIText.lookup(.menuHelp, in: .vi, tables: tables) == "Shortcuts & help")
        #expect(UIText.lookup(.menuReload, in: .en, tables: tables) == "Tải lại")
        #expect(UIText.lookup(.menuOpenFile, in: .en, tables: tables) == "menuOpenFile")
        #expect(UIText.lookup(.menuOpenFile, in: .vi, tables: [:]) == "menuOpenFile")
    }

    @Test func fillsPlaceholdersInOnePass() {
        #expect(UIText.fill("{0} · {1}", ["a", "b"]) == "a · b")
        #expect(UIText.fill("{1} then {0}", ["a", "b"]) == "b then a")
        // An argument is never filled in again, whatever it contains.
        #expect(UIText.fill("{0} and {1}", ["{1}", "x"]) == "{1} and x")
        #expect(UIText.fill("{2} {x} {", ["a"]) == "{2} {x} {")
        #expect(UIText.fill("no args {0}", []) == "no args {0}")
    }

    @Test func trFollowsTheLanguage() {
        UIText.$override.withValue(.en) {
            #expect(tr(.menuQuit) == "Quit")
            #expect(tr(.noticeCopied, 12) == "✓ Copied 12 characters")
        }
        UIText.$override.withValue(.vi) {
            #expect(tr(.menuQuit) == "Thoát")
            #expect(tr(.noticeCopied, 12) == "✓ Đã copy 12 ký tự")
        }
        #expect(UIText.string(.menuQuit, in: .en) == "Quit")
    }

    @Test func notesErrorsFollowTheLanguage() throws {
        let error = NotesLoadError.invalidDocx(URL(fileURLWithPath: "/x.docx"), .notZip)
        UIText.$override.withValue(.en) {
            #expect(error.errorDescription == "The file is not a Word .docx (not a zip package).")
        }
        UIText.$override.withValue(.vi) {
            #expect(error.errorDescription == "File không phải định dạng Word .docx (không phải gói zip).")
        }
    }

    /// The help page names the picker rows and the selector as they read in the same language.
    @Test func helpNamesTheControlsOfItsLanguage() {
        for language in UILanguage.allCases {
            let help = UIText.string(.pageHelp, in: language)
            let dialog = UIText.string(.pickerOpenDialog, in: language).components(separatedBy: " (")[0]
            for name in [UIText.string(.pickerBrowse, in: language), dialog, UIText.string(.displayLanguage, in: language)] {
                #expect(help.contains("**\(name)**"), "\(language): \(name)")
            }
        }
    }

    // MARK: - Language preference

    /// Removes a scratch domain and the empty plist file macOS leaves behind.
    private func discard(_ defaults: UserDefaults, _ name: String) {
        defaults.removePersistentDomain(forName: name)
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: file)
    }

    private func scratchDefaults(_ values: [String: Any] = [:]) -> (UserDefaults, String) {
        let name = "com.long.meetingprompter.tests.language-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        for (key, value) in values { defaults.set(value, forKey: key) }
        return (defaults, name)
    }

    @Test func existingInstallKeepsVietnamese() {
        #expect(UILanguagePreference.decide(stored: nil, hasOtherSettings: true, preferredLanguages: ["en-US"]) == .vi)
        #expect(UILanguagePreference.decide(stored: nil, hasOtherSettings: true, preferredLanguages: ["fr-FR"]) == .vi)
        // Not a known language: decided again by the same rule.
        #expect(UILanguagePreference.decide(stored: "fr", hasOtherSettings: true, preferredLanguages: ["en-US"]) == .vi)
    }

    @Test func freshInstallFollowsThePreferredLanguages() {
        func fresh(_ preferred: [String]) -> UILanguage {
            UILanguagePreference.decide(stored: nil, hasOtherSettings: false, preferredLanguages: preferred)
        }
        #expect(fresh(["vi-VN", "en-US"]) == .vi)
        #expect(fresh(["vi"]) == .vi)
        #expect(fresh(["fr-FR", "vi-VN"]) == .vi)
        #expect(fresh(["en-VN"]) == .en)
        #expect(fresh(["en-US", "vi-VN"]) == .en)
        #expect(fresh(["fr-FR", "de-DE"]) == .en)
        #expect(fresh(["zh-Hans-CN"]) == .en)
        #expect(fresh([]) == .en)
    }

    @Test func savedChoiceWins() {
        for language in UILanguage.allCases {
            for other in [true, false] {
                #expect(UILanguagePreference.decide(stored: language.rawValue, hasOtherSettings: other, preferredLanguages: ["vi-VN"]) == language)
                #expect(UILanguagePreference.decide(stored: language.rawValue, hasOtherSettings: other, preferredLanguages: ["en-US"]) == language)
            }
        }
    }

    @Test func loadOnAnExistingDomainSavesVietnamese() {
        let (defaults, name) = scratchDefaults(["overlayVisible": true, "fontSize": 12.0])
        defer { discard(defaults, name) }
        #expect(UILanguagePreference.load(from: defaults, domain: name, preferredLanguages: ["en-US"]) == .vi)
        #expect(defaults.string(forKey: UILanguagePreference.key) == "vi")
        // Existing settings are left as they were.
        #expect(defaults.bool(forKey: "overlayVisible"))
        #expect(defaults.double(forKey: "fontSize") == 12)
    }

    @Test func loadOnAFreshDomainSavesTheDecisionAtOnce() {
        let (vietnamese, viName) = scratchDefaults()
        defer { discard(vietnamese, viName) }
        #expect(UILanguagePreference.load(from: vietnamese, domain: viName, preferredLanguages: ["vi-VN"]) == .vi)
        #expect(vietnamese.string(forKey: UILanguagePreference.key) == "vi")

        let (english, enName) = scratchDefaults()
        defer { discard(english, enName) }
        #expect(UILanguagePreference.load(from: english, domain: enName, preferredLanguages: ["en-VN"]) == .en)
        #expect(english.string(forKey: UILanguagePreference.key) == "en")
        // Later launches: the domain now has settings, but the saved choice holds, whatever macOS prefers by then.
        english.set(true, forKey: "overlayVisible")
        #expect(UILanguagePreference.load(from: english, domain: enName, preferredLanguages: ["vi-VN"]) == .en)
    }

    @Test func choicePersistsAcrossRelaunch() {
        let (defaults, name) = scratchDefaults(["overlayVisible": true])
        defer { discard(defaults, name) }
        #expect(UILanguagePreference.load(from: defaults, domain: name, preferredLanguages: ["vi-VN"]) == .vi)
        UILanguagePreference.store(.en, in: defaults)
        // A new process reads the domain afresh.
        let relaunched = UserDefaults(suiteName: name)!
        #expect(UILanguagePreference.load(from: relaunched, domain: name, preferredLanguages: ["vi-VN"]) == .en)
        UILanguagePreference.store(.vi, in: relaunched)
        #expect(UILanguagePreference.load(from: UserDefaults(suiteName: name)!, domain: name, preferredLanguages: ["en-US"]) == .vi)
    }

    // MARK: - Every interface string goes through the tables (source check)

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    /// Vietnamese letters with diacritics; plain ASCII Vietnamese cannot be told from English.
    private static let vietnamese = try! NSRegularExpression(
        pattern: "[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]", options: [.caseInsensitive])

    /// Vietnamese text outside the Vietnamese table: what Claude receives, the old build's menu name and the
    /// bilingual language item.
    private static let allowed: [String: [String]] = [
        "PrompterCore/ClaudeText.swift": ["*"],
        "PrompterCore/UIText+vi.swift": ["*"],
        "PrompterCore/NotesLoader.swift": ["\"*(Tài liệu không có nội dung văn bản.)*\\n\""],
        "PrompterCore/NotesDelivery.swift": ["\"ghi chú\""],
        // The old build's menu name, and the language item that reads the same in both tables.
        "PrompterCore/UIText+en.swift": ["→ Thoát", "\"Ngôn ngữ / Language\"", "\"Tiếng Việt\""],
    ]

    @Test func noVietnameseLiteralOutsideTheTables() throws {
        var found: [String] = []
        for folder in ["MeetingPrompter", "PrompterCore"] {
            let dir = Self.sources.appending(path: folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
                let name = "\(folder)/\(file)"
                let allowed = Self.allowed[name] ?? []
                if allowed == ["*"] { continue }
                var inBlock = false
                for line in try String(contentsOf: dir.appending(path: file), encoding: .utf8).split(separator: "\n") {
                    let text = String(line)
                    let quotes = text.components(separatedBy: "\"\"\"").count - 1
                    let candidates: [String]
                    if inBlock || quotes > 0 {
                        candidates = [text]
                    } else if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                        candidates = []
                    } else {
                        candidates = text.matches(of: /"(?:[^"\\\n]|\\.)*"/).map { String($0.0) }
                    }
                    if quotes % 2 == 1 { inBlock.toggle() }
                    for literal in candidates where Self.vietnamese.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)) != nil {
                        if !allowed.contains(where: literal.contains) { found.append("\(name): \(literal)") }
                    }
                }
            }
        }
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }
}
