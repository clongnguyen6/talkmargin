import Foundation
import Testing
@testable import PrompterCore

/// scripts/registrations.sh against a fake lsregister (logs its arguments, serves a crafted dump):
/// the real LaunchServices database is never touched.
struct RegistrationsScriptTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "scripts/registrations.sh")

    private struct Fixture {
        let root: URL
        let sandbox: URL
        let log: URL
        let dump: URL
        let fake: URL

        init(marker: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "mp-reg-\(UUID().uuidString)")
            sandbox = root.appending(path: "sandbox")
            log = root.appending(path: "lsregister.log")
            dump = root.appending(path: "dump.txt")
            fake = root.appending(path: "fake-lsregister")
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            if marker { try Data().write(to: sandbox.appending(path: ".mp-update-sandbox")) }
            try Data().write(to: dump)
            try """
            #!/bin/bash
            echo "$*" >> "\(log.path)"
            [[ "$1" == -dump ]] && { cat "\(dump.path)"; exit 0; }
            # Like the real one for a bundle it has no record of.
            [[ "$1" == -u && -f "\(root.path)/fail-u" ]] && exit 1
            [[ "$1" == -u && "$2" == *fail-here* ]] && exit 1
            exit 0
            """.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        }

        func record(path: String, id: String) -> String {
            "bundle id:                  Test (0x1)\npath:                       \(path) (0x2)\nidentifier:                 \(id)\nname:                       Test\n"
        }

        func setDump(_ records: [String]) throws {
            try (records.joined(separator: "\n--------------------------------------------------------------------------------\n") + "\n")
                .write(to: dump, atomically: true, encoding: .utf8)
        }

        var calls: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func run(_ arguments: [String], sandboxRoot: String?) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [RegistrationsScriptTests.script.path] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["MP_LSREGISTER"] = fake.path
            environment.removeValue(forKey: "MP_UPDATE_SANDBOX")
            if let sandboxRoot { environment["MP_UPDATE_SANDBOX"] = sandboxRoot }
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func missingSandboxRootIsRefusedBeforeAnything() throws {
        let f = try Fixture()
        defer { f.remove() }
        #expect(try f.run(["stale", "com.long.meetingprompter"], sandboxRoot: f.root.appending(path: "missing").path) == 2)
        #expect(try f.run(["stale", "com.long.meetingprompter"], sandboxRoot: "") == 2)
        #expect(f.calls.isEmpty)
    }

    @Test func unmarkedOrBroadRootsAreRefused() throws {
        let f = try Fixture(marker: false)
        defer { f.remove() }
        #expect(try f.run(["stale", "com.long.meetingprompter"], sandboxRoot: f.sandbox.path) == 2)
        let home = InstanceLock.realHome()
        #expect(try f.run(["stale", "com.long.meetingprompter"], sandboxRoot: home + "/Applications") == 2)
        #expect(try f.run(["stale", "com.long.meetingprompter"], sandboxRoot: home) == 2)
        #expect(try f.run(["stale", "com.long.meetingprompter"], sandboxRoot: "/") == 2)
        #expect(f.calls.isEmpty)
    }

    @Test func targetsOutsideTheSandboxOrInApplicationsAreRefused() throws {
        let f = try Fixture()
        defer { f.remove() }
        let outside = f.root.appending(path: "elsewhere/MeetingPrompter.app")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        #expect(try f.run(["unregister", outside.path], sandboxRoot: f.sandbox.path) == 2)
        #expect(try f.run(["unregister", InstanceLock.realHome() + "/Applications/MeetingPrompter.app"], sandboxRoot: f.sandbox.path) == 2)
        #expect(try f.run(["unregister", "/Applications/TalkMargin.app"], sandboxRoot: f.sandbox.path) == 2)
        #expect(f.calls.isEmpty)
    }

    @Test func unregisteringABundleWithoutRecordIsFine() throws {
        let f = try Fixture()
        defer { f.remove() }
        let app = f.sandbox.appending(path: "stage/MeetingPrompter.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: f.root.appending(path: "fail-u"))
        // Never registered: -u fails, no record names it, so nothing is left to remove.
        #expect(try f.run(["unregister", app.path], sandboxRoot: f.sandbox.path) == 0)
        // Still registered after a failed -u: an error.
        // LaunchServices lists physical paths (/private/var/...); Foundation's resolving would strip /private.
        let physical = try #require(realpath(app.path, nil).map { defer { free($0) }; return String(cString: $0) })
        try f.setDump([f.record(path: physical, id: "com.long.meetingprompter.verify-x")])
        #expect(try f.run(["unregister", app.path], sandboxRoot: f.sandbox.path) == 1)
    }

    // MARK: - Normal mode (no sandbox): known folders only

    @Test func normalModeClearsOnlyKnownTemporaryFolders() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = "com.long.meetingprompter.verify-test"
        let token = UUID().uuidString
        let tmpGone = "/private/tmp/mp-reg-\(token)/gone/MeetingPrompter.app"
        let ejected = "/Volumes/mp-reg-ejected-\(token)/MeetingPrompter.app"
        let inApplications = InstanceLock.realHome() + "/Applications/mp-reg-\(token).app"
        defer { try? FileManager.default.removeItem(atPath: "/private/tmp/mp-reg-\(token)") }
        try f.setDump([f.record(path: tmpGone, id: id), f.record(path: ejected, id: id), f.record(path: inApplications, id: id)])
        #expect(try f.run(["stale", id], sandboxRoot: nil) == 0)
        let unregistered = f.calls.filter { $0.hasPrefix("-u") }
        #expect(unregistered == ["-u \(tmpGone)"])
        // Nothing was created on the ejected volume or in Applications; the placeholder is gone again.
        #expect(!FileManager.default.fileExists(atPath: ejected))
        #expect(!FileManager.default.fileExists(atPath: inApplications))
        #expect(!FileManager.default.fileExists(atPath: "/private/tmp/mp-reg-\(token)"))
    }

    @Test func oneFailingRecordDoesNotStopTheOthers() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = "com.long.meetingprompter.verify-test"
        let token = UUID().uuidString
        let failing = "/private/tmp/mp-reg-\(token)/fail-here/MeetingPrompter.app"
        let fine = "/private/tmp/mp-reg-\(token)/fine/MeetingPrompter.app"
        defer { try? FileManager.default.removeItem(atPath: "/private/tmp/mp-reg-\(token)") }
        try f.setDump([f.record(path: failing, id: id), f.record(path: fine, id: id)])
        #expect(try f.run(["stale", id], sandboxRoot: nil) == 1)
        #expect(Set(f.calls.filter { $0.hasPrefix("-u") }) == ["-u \(failing)", "-u \(fine)"])
        #expect(!FileManager.default.fileExists(atPath: "/private/tmp/mp-reg-\(token)"))
    }

    // MARK: - Applications folders (build-app.sh --out)

    private func inAppFolder(_ path: String, home: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let lib = Self.script.deletingLastPathComponent().appending(path: "lib/paths.sh").path
        process.arguments = ["-c", ". \"$0\"; in_app_folder \"$1\" \"$2\"", lib, path, home]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test func applicationsFoldersAreRecognisedPhysically() throws {
        let f = try Fixture()
        defer { f.remove() }
        let home = f.root.appending(path: "home").path
        try FileManager.default.createDirectory(atPath: home + "/Applications", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.root.appending(path: "link").path, withDestinationPath: home + "/Applications")
        #expect(try inAppFolder(home + "/Applications/TalkMargin.app", home: home))
        #expect(try inAppFolder(home + "/Applications", home: home))
        #expect(try inAppFolder(f.root.appending(path: "link/New/MeetingPrompter.app").path, home: home))
        #expect(try inAppFolder("/Applications/TalkMargin.app", home: home))
        #expect(try !inAppFolder(home + "/Applications2/X.app", home: home))
        #expect(try !inAppFolder(f.sandbox.path + "/out", home: home))
    }

    private func bash(_ script: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let lib = Self.script.deletingLastPathComponent().appending(path: "lib/paths.sh").path
        process.arguments = ["-c", ". \"$0\"; " + script, lib] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func runningAppIsFoundWhicheverSpellingOfItsPath() throws {
        // A stand-in "app" launched through /tmp, asked about as /private/tmp (and the other way round).
        let token = UUID().uuidString
        let app = "/tmp/mp-run-\(token)/X.app"
        defer { try? FileManager.default.removeItem(atPath: "/private/tmp/mp-run-\(token)") }
        try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        // Compiled here: a copied system binary (e.g. /bin/sleep) is killed by the system at launch.
        let compile = try bash("printf 'int pause(void); int main(void){ pause(); return 0; }' | cc -x c - -o \"$1\"", [app + "/Contents/MacOS/Sleeper"])
        #expect(compile.isEmpty)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: app + "/Contents/MacOS/Sleeper")
        try sleeper.run()
        defer { sleeper.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        try #require(sleeper.isRunning, "the stand-in must be running for this test to mean anything")
        let pid = String(sleeper.processIdentifier)
        #expect(try bash("running_from \"$1\" Sleeper", ["/private" + app]) == pid)
        #expect(try bash("running_from \"$1\" Sleeper", [app]) == pid)
        #expect(try bash("running_from \"$1\" Sleeper", ["/private/tmp/mp-run-\(token)/Y.app"]).isEmpty)
        // An existing file keeps its name; only folders are resolved.
        #expect(try bash("physical_path \"$1\"", [app + "/Contents/MacOS/Sleeper"]) == "/private" + app + "/Contents/MacOS/Sleeper")
    }

    @Test func staleRecordsInsideTheSandboxAreRemovedWithAPlaceholder() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = "com.long.meetingprompter.verify-test"
        let stale = f.sandbox.appending(path: "gone/build/MeetingPrompter.app").path
        let present = f.sandbox.appending(path: "here/MeetingPrompter.app")
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        try f.setDump([f.record(path: stale, id: id), f.record(path: present.path, id: id),
                       f.record(path: "/private/tmp/not-in-sandbox/MeetingPrompter.app", id: id),
                       f.record(path: f.sandbox.appending(path: "other/X.app").path, id: "com.example.other")])

        #expect(try f.run(["stale", id, "--check"], sandboxRoot: f.sandbox.path) == 0)
        #expect(!f.calls.contains { $0.hasPrefix("-u") })

        #expect(try f.run(["stale", id], sandboxRoot: f.sandbox.path) == 0)
        let unregistered = f.calls.filter { $0.hasPrefix("-u") }
        // Only the missing bundle inside the sandbox, by its real path; the placeholder folders are gone again.
        #expect(unregistered.count == 1 && unregistered[0].hasSuffix("/sandbox/gone/build/MeetingPrompter.app"))
        #expect(!FileManager.default.fileExists(atPath: f.sandbox.appending(path: "gone").path))
        #expect(FileManager.default.fileExists(atPath: present.path))
    }
}
