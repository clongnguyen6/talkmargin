import Darwin
import Foundation

/// Which build is running, from its bundle id. Each build keeps its own settings (the
/// defaults domain follows the bundle id) and data folder.
public struct AppIdentity: Equatable, Sendable {
    public static let productionID = "com.long.meetingprompter"
    public static let devID = "com.long.meetingprompter.dev"
    /// Throwaway builds for agent verification runs; the only ones that honour `TestHooks`.
    public static let verifyPrefix = "com.long.meetingprompter.verify-"

    public enum Kind: Equatable, Sendable {
        case production
        /// `build-app.sh` without `--install`: `TalkMargin Dev.app`.
        case dev
        /// `com.long.meetingprompter.verify-*`: sandboxed verification builds.
        case verify
        /// `swift build` binary or any other id.
        case other
    }

    public let bundleID: String?

    public init(bundleID: String?) {
        self.bundleID = bundleID
    }

    public var kind: Kind {
        switch bundleID {
        case Self.productionID: .production
        case Self.devID: .dev
        case let id? where id.hasPrefix(Self.verifyPrefix): .verify
        default: .other
        }
    }

    /// Folder in Application Support for conversations.
    public var dataFolderName: String {
        switch kind {
        case .production: "MeetingPrompter"
        case .dev: "MeetingPrompter Dev"
        case .verify, .other: "MeetingPrompter (\(bundleID ?? "unbundled"))"
        }
    }

    /// A later launch hands its documents to the running copy with the same id.
    public var forwardsDocuments: Bool { kind == .production || kind == .verify }

    /// Another running app that must not run next to this one: the user's builds (production,
    /// dev) exclude each other. A verification build only excludes its own id: verification runs
    /// with separate ids (and lock files) may run side by side.
    public func conflicts(with otherBundleID: String?) -> Bool {
        let other = AppIdentity(bundleID: otherBundleID)
        switch kind {
        case .production, .dev, .other: return other.kind == .production || other.kind == .dev
        case .verify: return otherBundleID == bundleID
        }
    }
}

/// Whether the app's windows may appear in screen capture (`MP_ALLOW_CAPTURE=1`, for screenshots while
/// working on the UI). Only dev and verification builds honour it; production, and any other build,
/// always keeps every window out of screen sharing whatever the environment says.
public enum CapturePolicy {
    public static let environmentKey = "MP_ALLOW_CAPTURE"

    public static func allowsCapture(identity: AppIdentity, environment: [String: String]) -> Bool {
        (identity.kind == .dev || identity.kind == .verify) && environment[environmentKey] == "1"
    }
}

/// Environment switches for verification runs. Honoured only by `com.long.meetingprompter.verify-*`
/// builds; production and dev builds ignore the environment entirely.
public struct TestHooks: Equatable, Sendable {
    /// `MP_LOCK_PATH`: a sandbox lock file instead of the shared one.
    public var lockPath: String?
    /// `MP_HEADLESS=1`: no shortcut tap, status item, window or permission prompt; opened documents are logged.
    public var headless = false

    public static let none = TestHooks()

    public init(lockPath: String? = nil, headless: Bool = false) {
        self.lockPath = lockPath
        self.headless = headless
    }

    public static func from(identity: AppIdentity, environment: [String: String]) -> TestHooks {
        guard identity.kind == .verify else { return .none }
        return TestHooks(lockPath: environment["MP_LOCK_PATH"].flatMap { $0.isEmpty ? nil : $0 },
                         headless: environment["MP_HEADLESS"] == "1")
    }
}

/// One running TalkMargin per user, whichever build: an exclusive `flock` on a file
/// shared by every build. The system drops it when the process ends, so it never goes stale.
/// The holder writes its pid into the file so a later launch can find it.
public final class InstanceLock: @unchecked Sendable {
    public enum Attempt {
        case acquired(InstanceLock)
        /// Another process holds it (`EWOULDBLOCK`).
        case held
        /// The lock cannot be used at all (permissions, file system); the reason is for the user.
        case unavailable(String)
    }

    public let url: URL
    private var fd: Int32

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit { release() }

    /// Shared by production, dev and unbundled builds. From the account's real home, so
    /// `CFFIXED_USER_HOME` (used by test runs) cannot split it.
    public static func sharedURL(home: String = realHome()) -> URL {
        URL(fileURLWithPath: home).appending(path: "Library/Application Support/MeetingPrompter/instance.lock")
    }

    /// The lock this build uses: the shared one for the user's builds; for a verification build its
    /// `MP_LOCK_PATH`, or else a lock of its own id in the temporary folder, so it can never hold the
    /// lock the user's app needs.
    public static func url(identity: AppIdentity, hooks: TestHooks,
                           temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        guard identity.kind == .verify else { return sharedURL() }
        if let path = hooks.lockPath { return URL(fileURLWithPath: path) }
        return temporaryDirectory.appending(path: "\(identity.bundleID ?? "verify").instance.lock")
    }

    public static func realHome() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Only `EWOULDBLOCK` means another process holds the lock. A file that cannot be opened for
    /// writing is locked read-only (no pid is recorded then). Close-on-exec: child processes (the
    /// `claude` runs) must not keep it after the app quits.
    public static func acquire(at url: URL, pid: Int32 = getpid()) -> Attempt {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var writable = true
        var fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        if fd < 0 {
            let writeError = errno
            fd = open(url.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return .unavailable("cannot open \(url.path): \(String(cString: strerror(writeError)))") }
            writable = false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK { return .held }
            return .unavailable("cannot lock \(url.path): \(String(cString: strerror(error)))")
        }
        if writable {
            let text = "\(pid)\n"
            ftruncate(fd, 0)
            _ = text.withCString { pwrite(fd, $0, strlen($0), 0) }
        }
        return .acquired(InstanceLock(url: url, fd: fd))
    }

    /// The pid the current holder wrote; nil while it is still writing, or for a read-only holder.
    public static func holderPID(at url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}

/// What a launch that did not get the lock does.
public enum InstanceGate {
    /// Passed to a copy LaunchServices starts for a forward; such a launch never forwards again.
    public static let forwardedArgument = "--mp-forwarded-launch"

    public struct Holder: Equatable, Sendable {
        public let pid: Int32
        public let bundleID: String?
        public let bundlePath: String?

        public init(pid: Int32, bundleID: String?, bundlePath: String?) {
            self.pid = pid
            self.bundleID = bundleID
            self.bundlePath = bundlePath
        }
    }

    public enum Decision: Equatable, Sendable {
        /// This launch is the one instance.
        case primary
        /// Hand the documents to the running copy at this bundle path, then exit.
        case forward(bundlePath: String)
        /// The holder is starting or quitting and cannot be identified yet; try again shortly.
        case wait
        /// Do not run and do not forward; the documents go to the recent files and the reason is logged.
        case refuse(String)
    }

    public static func decide(lockAcquired: Bool, identity: AppIdentity, holder: Holder?, forwarded: Bool = false) -> Decision {
        if lockAcquired { return .primary }
        guard identity.forwardsDocuments else {
            return .refuse("another TalkMargin instance is running\(holder.map { " (pid \($0.pid))" } ?? ""); quit it first")
        }
        if forwarded { return .refuse("this launch was started by a forward and does not forward again") }
        guard let holder else { return .wait }
        guard holder.bundleID == identity.bundleID, let path = holder.bundlePath else {
            return .refuse("a different TalkMargin build is running (pid \(holder.pid), \(holder.bundleID ?? "unbundled")); quit it first")
        }
        return .forward(bundlePath: path)
    }

    /// A forward succeeded only when the running holder itself took the documents. Another pid
    /// means LaunchServices started a new copy (the holder had quit): a failure for the forwarder.
    public static func forwardReachedHolder(holderPID: Int32, answeredBy pid: Int32?) -> Bool {
        pid == holderPID
    }
}

/// Instances of the same family that run without the lock. Only a build from before the lock
/// counts: its bundle has no build stamp (`MPGitCommit`) or its executable still has the old name.
/// A current build's own second launch (stamped, `TalkMargin`) never does, however long it lives,
/// e.g. while a notice is up.
public enum LegacyInstances {
    /// The executable name of builds before the rename.
    public static let legacyExecutableName = "MeetingPrompter"

    public struct Other: Equatable, Sendable {
        public let pid: Int32
        public let bundleID: String?
        /// `CFBundleExecutable` of the running copy, from its bundle.
        public let executableName: String?
        /// Its bundle has `MPGitCommit` (stamped by the build script).
        public let stamped: Bool

        public init(pid: Int32, bundleID: String?, executableName: String?, stamped: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.executableName = executableName
            self.stamped = stamped
        }

        public var isLegacyBuild: Bool { !stamped || executableName == LegacyInstances.legacyExecutableName }
    }

    /// Upper bound of a second launch's life; the conflicting-copy watch looks again after it.
    public static let secondLaunchLifetime = 20.0

    public enum Verdict: Equatable, Sendable {
        case clear
        /// Running lock-less instances that must be quit first.
        case legacy([Int32])
    }

    /// The pids of a `.legacy` verdict that are still alive a moment later. Right after the old
    /// instance quits, the workspace may still list it although the process is gone.
    public static func stillRunning(_ pids: [Int32], isAlive: (Int32) -> Bool = processExists) -> [Int32] {
        pids.filter(isAlive)
    }

    public static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    public static func check(_ others: [Other], identity: AppIdentity, selfPID: Int32) -> Verdict {
        let legacy = others.filter { $0.pid != selfPID && identity.conflicts(with: $0.bundleID) && $0.isLegacyBuild }
        return legacy.isEmpty ? .clear : .legacy(legacy.map(\.pid))
    }
}

/// How long a launch that is not the instance may live, counted from the process's launch (not
/// from when launching finished). It gives up on forwarding at `deadline` and exits at `hardStop`,
/// both below `LegacyInstances.secondLaunchLifetime`; once promoted to the instance, never.
public struct SecondLaunchLifetime: Sendable {
    public static let deadline = 15.0
    public static let hardStop = 17.0

    public enum Action: Equatable, Sendable {
        case keepGoing
        case giveUp
        case exit
    }

    public let launchedAt: Date
    public private(set) var promoted = false

    public init(launchedAt: Date) {
        self.launchedAt = launchedAt
    }

    public mutating func promote() {
        promoted = true
    }

    public func action(at now: Date) -> Action {
        guard !promoted else { return .keepGoing }
        let age = now.timeIntervalSince(launchedAt)
        if age >= Self.hardStop { return .exit }
        if age >= Self.deadline { return .giveUp }
        return .keepGoing
    }

    /// Seconds from `now` until `deadline` and `hardStop` (zero when already past).
    public func untilDeadline(at now: Date) -> Double { max(0, Self.deadline - now.timeIntervalSince(launchedAt)) }
    public func untilHardStop(at now: Date) -> Double { max(0, Self.hardStop - now.timeIntervalSince(launchedAt)) }
}

/// The documents a launch that is not the instance was asked to open. Every one of them ends up in
/// the recent files, whatever happens next: forwarded (the instance may still lose it, e.g. if it was
/// frozen and is force-quit before handling the open), refused, given up, or arriving late while a
/// notice is up. Adding to the recent files never opens anything, so nothing opens twice.
public struct SecondLaunchDocuments: Sendable {
    public private(set) var paths: [String] = []
    private var kept = 0

    public init() {}

    public var isEmpty: Bool { paths.isEmpty }

    public mutating func add(_ newPaths: [String]) {
        paths += newPaths
    }

    /// `recents` with the documents not kept yet moved to the front, marking them kept; nil when none are new.
    public mutating func keep(in recents: [String], limit: Int = 10) -> [String]? {
        guard kept < paths.count else { return nil }
        let new = Array(paths[kept...])
        kept = paths.count
        return RecentFiles.prepending(new, to: recents, limit: limit)
    }

    /// After becoming the instance: the documents are opened instead.
    public mutating func clear() {
        paths = []
        kept = 0
    }
}

/// The recent-files list with `paths` moved to the front, each once.
public enum RecentFiles {
    public static func prepending(_ paths: [String], to recents: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return Array((paths + recents).filter { seen.insert($0).inserted }.prefix(limit))
    }
}
