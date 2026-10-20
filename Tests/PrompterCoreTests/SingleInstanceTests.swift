import Foundation
import Testing
@testable import PrompterCore

struct SingleInstanceTests {
    private func lockURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "mp-lock-\(UUID().uuidString)/instance.lock")
    }

    private func acquired(_ attempt: InstanceLock.Attempt) -> InstanceLock? {
        if case .acquired(let lock) = attempt { return lock }
        return nil
    }

    private func isHeld(_ attempt: InstanceLock.Attempt) -> Bool {
        if case .held = attempt { return true }
        return false
    }

    /// `lockf -t 0 <file> true`: exit 0 when it got the lock, 75 when another process holds it.
    private func otherProcessCanLock(_ url: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-t", "0", url.path, "/usr/bin/true"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Identity and hooks

    private let production = AppIdentity(bundleID: AppIdentity.productionID)
    private let dev = AppIdentity(bundleID: AppIdentity.devID)
    private let verify = AppIdentity(bundleID: "com.long.meetingprompter.verify-a")
    private let unbundled = AppIdentity(bundleID: nil)

    @Test func identitiesKeepTheirOwnData() {
        #expect(production.kind == .production && production.dataFolderName == "MeetingPrompter")
        #expect(dev.kind == .dev && dev.dataFolderName == "MeetingPrompter Dev")
        #expect(verify.kind == .verify && verify.dataFolderName == "MeetingPrompter (com.long.meetingprompter.verify-a)")
        #expect(unbundled.kind == .other && unbundled.dataFolderName == "MeetingPrompter (unbundled)")
        #expect(production.forwardsDocuments && verify.forwardsDocuments)
        #expect(!dev.forwardsDocuments && !unbundled.forwardsDocuments)
        // A near miss is not a verification build.
        #expect(AppIdentity(bundleID: "com.long.meetingprompter.verifyx").kind == .other)
    }

    @Test func testHooksOnlyForVerificationBuilds() {
        let environment = ["MP_LOCK_PATH": "/tmp/sandbox/instance.lock", "MP_HEADLESS": "1"]
        #expect(TestHooks.from(identity: production, environment: environment) == .none)
        #expect(TestHooks.from(identity: dev, environment: environment) == .none)
        #expect(TestHooks.from(identity: unbundled, environment: environment) == .none)
        #expect(TestHooks.from(identity: verify, environment: environment)
                == TestHooks(lockPath: "/tmp/sandbox/instance.lock", headless: true))
        #expect(TestHooks.from(identity: verify, environment: [:]) == .none)
        // Production always uses the shared lock, whatever the environment says.
        #expect(InstanceLock.url(identity: production, hooks: TestHooks.from(identity: production, environment: environment)) == InstanceLock.sharedURL())
        #expect(InstanceLock.url(identity: dev, hooks: TestHooks.from(identity: dev, environment: environment)) == InstanceLock.sharedURL())
        #expect(InstanceLock.url(identity: verify, hooks: TestHooks.from(identity: verify, environment: environment)).path == "/tmp/sandbox/instance.lock")
    }

    @Test func verifyBuildWithoutLockPathNeverTakesTheSharedLock() {
        let temporary = URL(fileURLWithPath: "/private/var/folders/xx/T")
        let url = InstanceLock.url(identity: verify, hooks: .none, temporaryDirectory: temporary)
        #expect(url != InstanceLock.sharedURL())
        #expect(url.path == "/private/var/folders/xx/T/com.long.meetingprompter.verify-a.instance.lock")
        // Another verify id gets another lock.
        #expect(InstanceLock.url(identity: AppIdentity(bundleID: "com.long.meetingprompter.verify-b"), hooks: .none, temporaryDirectory: temporary) != url)
    }

    @Test func familiesThatMustNotRunTogether() {
        #expect(production.conflicts(with: AppIdentity.devID) && dev.conflicts(with: AppIdentity.productionID))
        #expect(production.conflicts(with: AppIdentity.productionID))
        #expect(!production.conflicts(with: "com.long.meetingprompter.verify-b"))
        // Verification builds: only their own id (separate runs, separate ids and locks, side by side).
        #expect(verify.conflicts(with: "com.long.meetingprompter.verify-a"))
        #expect(!verify.conflicts(with: "com.long.meetingprompter.verify-legacy"))
        #expect(!verify.conflicts(with: AppIdentity.productionID))
        #expect(!production.conflicts(with: "com.apple.TextEdit") && !production.conflicts(with: nil))
    }

    // MARK: - Lock

    @Test func secondAcquisitionIsHeldUntilReleased() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try #require(acquired(InstanceLock.acquire(at: url, pid: 4242)))
        #expect(isHeld(InstanceLock.acquire(at: url)))
        #expect(InstanceLock.holderPID(at: url) == 4242)
        first.release()
        let second = try #require(acquired(InstanceLock.acquire(at: url, pid: 5151)))
        #expect(InstanceLock.holderPID(at: url) == 5151)
        second.release()
    }

    @Test func unusableLockIsNotMistakenForHeld() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mp-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The lock's folder is a file: nothing can be opened there.
        let blocker = root.appending(path: "folder")
        try Data().write(to: blocker)
        guard case .unavailable(let reason) = InstanceLock.acquire(at: blocker.appending(path: "instance.lock")) else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("cannot open"))
    }

    @Test func readOnlyLockFileStillLocks() throws {
        let url = lockURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "999\n".write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let lock = try #require(acquired(InstanceLock.acquire(at: url, pid: 4242)))
        #expect(try !otherProcessCanLock(url))
        // Read-only: no pid could be written; a second launch then waits and falls back to the recent files.
        #expect(InstanceLock.holderPID(at: url) == 999)
        lock.release()
    }

    @Test func lockIsSeenByOtherProcesses() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lock = try #require(acquired(InstanceLock.acquire(at: url)))
        #expect(try !otherProcessCanLock(url))
        lock.release()
        #expect(try otherProcessCanLock(url))
    }

    @Test func lockHeldByAnotherProcessIsHeld() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        holder.arguments = ["-k", url.path, "/bin/sleep", "3"]
        try holder.run()
        defer { holder.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(isHeld(InstanceLock.acquire(at: url)))
        holder.terminate()
        holder.waitUntilExit()
        // Released when the holding process ends, without any cleanup.
        let lock = try #require(acquired(InstanceLock.acquire(at: url)))
        lock.release()
    }

    @Test func childProcessesDoNotInheritTheLock() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lock = try #require(acquired(InstanceLock.acquire(at: url)))
        // Like a `claude` run started while the app holds the lock.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["3"]
        try child.run()
        defer { child.terminate() }
        lock.release()
        #expect(try otherProcessCanLock(url))
    }

    @Test func sharedLockIgnoresAFakeHome() {
        #expect(InstanceLock.sharedURL(home: "/Users/me").path == "/Users/me/Library/Application Support/MeetingPrompter/instance.lock")
        #expect(InstanceLock.realHome().hasPrefix("/"))
    }

    // MARK: - Second launch

    @Test func theLockHolderIsPrimary() {
        #expect(InstanceGate.decide(lockAcquired: true, identity: production, holder: nil) == .primary)
        #expect(InstanceGate.decide(lockAcquired: true, identity: dev, holder: nil, forwarded: true) == .primary)
    }

    @Test func productionForwardsToAnotherProductionCopy() {
        // Open With on a second registered copy while the installed app runs.
        let installed = InstanceGate.Holder(pid: 48106, bundleID: AppIdentity.productionID,
                                            bundlePath: "/Users/me/Applications/MeetingPrompter.app")
        #expect(InstanceGate.decide(lockAcquired: false, identity: production, holder: installed)
                == .forward(bundlePath: "/Users/me/Applications/MeetingPrompter.app"))
    }

    @Test func aForwardedLaunchNeverForwardsAgain() {
        let installed = InstanceGate.Holder(pid: 9, bundleID: AppIdentity.productionID, bundlePath: "/Users/me/Applications/MeetingPrompter.app")
        guard case .refuse = InstanceGate.decide(lockAcquired: false, identity: production, holder: installed, forwarded: true) else {
            Issue.record("a forwarded launch must not forward")
            return
        }
    }

    @Test func onlyTheHolderAnsweringCountsAsForwarded() {
        #expect(InstanceGate.forwardReachedHolder(holderPID: 9, answeredBy: 9))
        #expect(!InstanceGate.forwardReachedHolder(holderPID: 9, answeredBy: 10))
        #expect(!InstanceGate.forwardReachedHolder(holderPID: 9, answeredBy: nil))
    }

    @Test func unknownHolderMeansWait() {
        #expect(InstanceGate.decide(lockAcquired: false, identity: production, holder: nil) == .wait)
    }

    @Test func otherBuildsNeverShareTheSession() {
        let devHolder = InstanceGate.Holder(pid: 7, bundleID: AppIdentity.devID, bundlePath: "/r/build/MeetingPrompter Dev.app")
        let unbundledHolder = InstanceGate.Holder(pid: 8, bundleID: nil, bundlePath: nil)
        let installed = InstanceGate.Holder(pid: 9, bundleID: AppIdentity.productionID, bundlePath: "/Users/me/Applications/MeetingPrompter.app")
        guard case .refuse = InstanceGate.decide(lockAcquired: false, identity: production, holder: devHolder) else { Issue.record(); return }
        guard case .refuse = InstanceGate.decide(lockAcquired: false, identity: production, holder: unbundledHolder) else { Issue.record(); return }
        // A dev build never forwards: it refuses while anything else runs.
        guard case .refuse = InstanceGate.decide(lockAcquired: false, identity: dev, holder: installed) else { Issue.record(); return }
        guard case .refuse = InstanceGate.decide(lockAcquired: false, identity: dev, holder: nil) else { Issue.record(); return }
    }

    // MARK: - Legacy instances

    private func other(_ pid: Int32, _ id: String?, exe: String? = "TalkMargin", stamped: Bool = true) -> LegacyInstances.Other {
        LegacyInstances.Other(pid: pid, bundleID: id, executableName: exe, stamped: stamped)
    }

    @Test func aBuildFromBeforeTheLockIsLegacy() {
        // The user's 75241: unstamped, executable MeetingPrompter.
        let preLock = other(75241, AppIdentity.productionID, exe: "MeetingPrompter", stamped: false)
        #expect(LegacyInstances.check([preLock], identity: production, selfPID: 100) == .legacy([75241]))
        // A dev build must not start next to it either.
        #expect(LegacyInstances.check([preLock], identity: dev, selfPID: 100) == .legacy([75241]))
        // Either sign alone is enough: unstamped, or the old executable name.
        #expect(other(1, AppIdentity.productionID, exe: "TalkMargin", stamped: false).isLegacyBuild)
        #expect(other(2, AppIdentity.productionID, exe: "MeetingPrompter", stamped: true).isLegacyBuild)
    }

    @Test func aCurrentBuildsSecondLaunchIsNeverLegacy() {
        // E.g. a second launch kept alive by an unanswered notice: stamped and named TalkMargin.
        let secondLaunch = other(200, AppIdentity.productionID)
        #expect(!secondLaunch.isLegacyBuild)
        #expect(LegacyInstances.check([secondLaunch], identity: production, selfPID: 100) == .clear)
        #expect(LegacyInstances.check([other(201, AppIdentity.devID)], identity: production, selfPID: 100) == .clear)
    }

    @Test func unrelatedAppsAndSelfAreIgnored() {
        let others = [other(100, AppIdentity.productionID, stamped: false), other(300, "com.apple.TextEdit", stamped: false),
                      other(301, "com.long.meetingprompter.verify-x", stamped: false)]
        #expect(LegacyInstances.check(others, identity: production, selfPID: 100) == .clear)
        #expect(LegacyInstances.check([other(75241, AppIdentity.productionID, stamped: false)], identity: verify, selfPID: 100) == .clear)
        #expect(LegacyInstances.check([other(302, "com.long.meetingprompter.verify-c", stamped: false)], identity: verify, selfPID: 100) == .clear)
        #expect(LegacyInstances.check([other(303, "com.long.meetingprompter.verify-a", stamped: false)], identity: verify, selfPID: 100) == .legacy([303]))
    }

    @Test func aLegacyVerdictIsConfirmedAgainstLiveProcesses() throws {
        // The old instance just quit: still listed, but gone.
        #expect(LegacyInstances.stillRunning([75241, 75242], isAlive: { $0 == 75242 }) == [75242])
        #expect(LegacyInstances.stillRunning([75241], isAlive: { _ in false }).isEmpty)
        // The real check: this process is alive; a process that has exited is not.
        #expect(LegacyInstances.processExists(getpid()))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(!LegacyInstances.processExists(child.processIdentifier))
    }

    @Test func secondLaunchesEndBeforeTheyCouldLookLegacy() {
        #expect(SecondLaunchLifetime.deadline < SecondLaunchLifetime.hardStop)
        #expect(SecondLaunchLifetime.hardStop < LegacyInstances.secondLaunchLifetime)
    }

    // MARK: - Second launch lifetime

    @Test func aSecondLaunchGivesUpThenStopsCountingFromItsLaunch() {
        let launched = Date(timeIntervalSince1970: 1_000)
        let lifetime = SecondLaunchLifetime(launchedAt: launched)
        #expect(lifetime.action(at: launched.addingTimeInterval(10)) == .keepGoing)
        #expect(lifetime.action(at: launched.addingTimeInterval(15)) == .giveUp)
        #expect(lifetime.action(at: launched.addingTimeInterval(17)) == .exit)
        // Launching finished late (say 10 s after the process started): the limits keep their absolute times.
        #expect(lifetime.untilDeadline(at: launched.addingTimeInterval(10)) == 5)
        #expect(lifetime.untilHardStop(at: launched.addingTimeInterval(10)) == 7)
        #expect(lifetime.untilHardStop(at: launched.addingTimeInterval(30)) == 0)
    }

    @Test func aPromotedLaunchIsNeverStopped() {
        // The finding: a second launch that became the instance was killed 17 s after start.
        let launched = Date(timeIntervalSince1970: 1_000)
        var lifetime = SecondLaunchLifetime(launchedAt: launched)
        lifetime.promote()
        for seconds in [0.0, 15, 17, 60, 3_600] {
            #expect(lifetime.action(at: launched.addingTimeInterval(seconds)) == .keepGoing)
        }
    }

    @Test func forwardedDocumentsAreAlsoKeptInRecents() {
        // S4 of the verification run: a frozen instance takes the forward, then may be force-quit.
        var documents = SecondLaunchDocuments()
        documents.add(["/n/d.md"])
        let afterForward = documents.keep(in: ["/n/a.md", "/n/c.md"])
        #expect(afterForward == ["/n/d.md", "/n/a.md", "/n/c.md"])
        // Nothing new: the recent files are not written again.
        #expect(documents.keep(in: afterForward ?? []) == nil)
        // A document arriving later (e.g. while a notice is up) is kept on the way out, once.
        documents.add(["/n/e.md", "/n/d.md"])
        #expect(documents.keep(in: afterForward ?? []) == ["/n/e.md", "/n/d.md", "/n/a.md", "/n/c.md"])
    }

    @Test func aPromotedLaunchOpensItsDocumentsInsteadOfKeepingThem() {
        var documents = SecondLaunchDocuments()
        documents.add(["/n/a.md"])
        documents.clear()
        #expect(documents.isEmpty)
        #expect(documents.keep(in: ["/n/x.md"]) == nil)
    }

    @Test func fallbackPutsDocumentsFirstInRecents() {
        #expect(RecentFiles.prepending(["/n/b.md", "/n/c.docx"], to: ["/n/a.md", "/n/b.md"], limit: 10)
                == ["/n/b.md", "/n/c.docx", "/n/a.md"])
        #expect(RecentFiles.prepending(["/x"], to: (1...10).map { "/\($0)" }, limit: 10).count == 10)
    }
}
