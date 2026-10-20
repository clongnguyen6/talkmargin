import Foundation
import Testing
@testable import PrompterCore

struct CapturePolicyTests {
    private let allow = ["MP_ALLOW_CAPTURE": "1"]

    @Test func productionIsNeverCapturable() {
        let production = AppIdentity(bundleID: AppIdentity.productionID)
        #expect(!CapturePolicy.allowsCapture(identity: production, environment: allow))
        #expect(!CapturePolicy.allowsCapture(identity: production, environment: [:]))
        // Any other build (unbundled, unknown id) is treated like production.
        #expect(!CapturePolicy.allowsCapture(identity: AppIdentity(bundleID: nil), environment: allow))
        #expect(!CapturePolicy.allowsCapture(identity: AppIdentity(bundleID: "com.example.other"), environment: allow))
    }

    @Test func devAndVerificationBuildsHonourTheSwitch() {
        for id in [AppIdentity.devID, "com.long.meetingprompter.verify-ui"] {
            let identity = AppIdentity(bundleID: id)
            #expect(CapturePolicy.allowsCapture(identity: identity, environment: allow))
            #expect(!CapturePolicy.allowsCapture(identity: identity, environment: [:]))
            #expect(!CapturePolicy.allowsCapture(identity: identity, environment: ["MP_ALLOW_CAPTURE": "0"]))
            #expect(!CapturePolicy.allowsCapture(identity: identity, environment: ["MP_ALLOW_CAPTURE": "yes"]))
        }
    }

    // MARK: - Every window follows the rule (source check)

    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    private func sources(_ folder: String) throws -> [(name: String, text: String)] {
        let dir = Self.appSources.appending(path: folder)
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .map { ($0, try String(contentsOf: dir.appending(path: $0), encoding: .utf8)) }
    }

    @Test func everyWindowTheAppCreatesUsesTheCaptureSetting() throws {
        // Anything that becomes a window of this app: the overlay, notices, dialogs, alerts, popovers.
        let creates = try NSRegularExpression(pattern:
            #"NSOpenPanel\(\)|NSSavePanel\(\)|NSAlert\(\)|NSPopover\(\)|NSWindow\(|NSPanel\(|super\.init\(contentRect:"#)
        let setsCapture = try NSRegularExpression(pattern: #"sharingType = (OverlayPanel|Self)\.captureSharingType"#)
        let files = try sources("MeetingPrompter")
        #expect(files.count > 10)
        var windowFiles: [String] = []
        for (name, text) in files {
            let range = NSRange(text.startIndex..., in: text)
            if creates.firstMatch(in: text, range: range) != nil {
                windowFiles.append(name)
                #expect(setsCapture.firstMatch(in: text, range: range) != nil, "\(name) creates a window without the capture setting")
            }
            // No window gets its sharing type from anywhere else.
            for line in text.split(separator: "\n") where line.contains("sharingType = ") {
                #expect(line.contains("captureSharingType"), "\(name): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        // The known windows are all found (a renamed file must not silently drop out of this check).
        #expect(Set(windowFiles).isSuperset(of: ["OverlayPanel.swift", "NoticePanel.swift", "OpenNotesDialog.swift"]))
    }

    @Test func theSwitchIsReadOnlyThroughThePolicy() throws {
        for (folder, allowed) in [("MeetingPrompter", Set<String>()), ("PrompterCore", ["SingleInstance.swift"])] {
            for (name, text) in try sources(folder) where text.contains(#""MP_ALLOW_CAPTURE""#) {
                #expect(allowed.contains(name), "\(folder)/\(name) reads MP_ALLOW_CAPTURE directly")
            }
        }
    }
}
