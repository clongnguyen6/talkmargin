import AppKit
import os
import PrompterCore

extension AppIdentity {
    static var current: AppIdentity { AppIdentity(bundleID: Bundle.main.bundleIdentifier) }

    /// Running apps that must not run next to this one (`conflicts(with:)`), other than this process,
    /// with what decides whether they are a build from before the lock (stamp, executable name).
    func otherInstances() -> [LegacyInstances.Other] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app -> LegacyInstances.Other? in
            guard app.processIdentifier != me, !app.isTerminated, conflicts(with: app.bundleIdentifier) else { return nil }
            return LegacyInstances.Other(app)
        }
    }
}

extension LegacyInstances.Other {
    init(_ app: NSRunningApplication) {
        let info = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
        self.init(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                  executableName: app.executableURL?.lastPathComponent, stamped: info?["MPGitCommit"] != nil)
    }
}

/// The delegate of any launch that cannot simply start as the instance. It creates no window
/// (other than a short notice), status item or tap until it is sure it is the only instance.
///
/// - `secondary`: another instance holds the lock (e.g. Open With on a second registered copy).
///   The documents go to the running copy with the same id, at that copy's bundle path, so
///   LaunchServices delivers them to that process; then this exits. The instance opens them like
///   any other document: the Claude session and the conversation shown are unchanged. A launch
///   that a forward started never forwards again, and only the holder itself answering counts
///   as success; otherwise, and after retries or the deadline, the documents go to the recent files.
///   A refusal (another build runs) is shown, not only logged.
/// - `checkLegacy`: this launch has the lock, but an instance of the same family runs without it:
///   a build from before the lock (it never answers a forward). Young ones may be a later build's
///   second launch and are waited out; an old one that is still alive a second later means: start
///   nothing, release the lock, tell the user to quit it, documents to the recent files.
/// - `noLock`: the lock cannot be used. Say so; if another instance runs, as for legacy; else start
///   without single-instance protection.
///
/// Times count from the process's launch (`SecondLaunchLifetime`); a launch that became the
/// instance is never stopped by them.
@MainActor
final class LaunchCoordinator: NSObject, NSApplicationDelegate {
    enum Mode {
        case secondary
        case checkLegacy(InstanceLock)
        case noLock(String)
    }

    private static let attempts = 6
    private static let retryDelay = 0.5
    /// Documents arrive in separate open events; wait this long after launch to batch them.
    private static let collectDelay = 0.3
    /// A legacy verdict is confirmed this much later (the old instance may just be quitting).
    private static let confirmDelay = 1.0

    private let mode: Mode
    private let identity: AppIdentity
    private let hooks: TestHooks
    private let forwarded: Bool
    private let log = Logger(subsystem: "MeetingPrompter", category: "instance")
    private var lifetime = SecondLaunchLifetime(launchedAt: NSRunningApplication.current.launchDate ?? Date())
    private var urls: [URL] = []
    /// The same documents for the recent files, kept on every way out (`SecondLaunchDocuments`).
    private var documents = SecondLaunchDocuments()
    private var attempt = 0
    private var finished = false
    /// Legacy pids seen once; blocking waits for a second look.
    private var suspectedLegacy: [Int32]?
    /// The notice on screen, if any; the decision is made and only its closing remains.
    private var notice: NoticePanel?
    /// Set when this launch became the instance after all.
    private var promoted: AppDelegate?

    init(mode: Mode, identity: AppIdentity, hooks: TestHooks, forwarded: Bool) {
        self.mode = mode
        self.identity = identity
        self.hooks = hooks
        self.forwarded = forwarded
        super.init()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let promoted { return promoted.application(application, open: urls) }
        self.urls += urls
        documents.add(urls.map { NotesPath.canonical($0).path })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        after(Self.collectDelay) { $0.step() }
        guard case .secondary = mode else { return }
        let now = Date()
        // A hung instance may never answer the forward; this launch must not linger without UI.
        after(lifetime.untilDeadline(at: now)) { $0.checkLifetime() }
        // Hard stop, so a second launch can never be mistaken for a legacy instance.
        after(lifetime.untilHardStop(at: now)) { $0.checkLifetime() }
    }

    private func checkLifetime() {
        guard !finished else { return }
        switch lifetime.action(at: Date()) {
        case .keepGoing: return
        case .giveUp:
            // Already decided while a notice is up; the hard stop still ends this launch.
            guard notice == nil else { return }
            giveUp("no answer from the running instance within \(Int(SecondLaunchLifetime.deadline)) s")
        case .exit:
            keepInRecents()
            log.error("Launch: stopped at the hard limit")
            exit(0)
        }
    }

    private func step() {
        guard !finished, promoted == nil else { return }
        attempt += 1
        switch mode {
        case .secondary: stepSecondary()
        case .checkLegacy(let lock): checkLegacy(lock: lock)
        case .noLock(let reason): checkWithoutLock(reason)
        }
    }

    // MARK: - Secondary

    private func stepSecondary() {
        let lockURL = InstanceLock.url(identity: identity, hooks: hooks)
        let lock: InstanceLock? = if case .acquired(let lock) = InstanceLock.acquire(at: lockURL) { lock } else { nil }
        let holder = lock == nil ? holder(lockURL: lockURL) : nil
        switch InstanceGate.decide(lockAcquired: lock != nil, identity: identity, holder: holder, forwarded: forwarded) {
        case .primary:
            if let lock { promoteOrCheckLegacy(lock) }
        case .forward(let bundlePath):
            guard !urls.isEmpty else { return finish("already running at \(bundlePath); nothing to open") }
            guard let holder else { return retry(because: "holder vanished") }
            forward(to: URL(fileURLWithPath: bundlePath), holderPID: holder.pid)
        case .wait:
            retry(because: "the running instance could not be identified yet")
        case .refuse(let reason):
            giveUp(reason, notice: Self.refusedNotice(holder: holder, documents: !urls.isEmpty))
        }
    }

    private func holder(lockURL: URL) -> InstanceGate.Holder? {
        guard let pid = InstanceLock.holderPID(at: lockURL),
              let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else { return nil }
        return InstanceGate.Holder(pid: pid, bundleID: running.bundleIdentifier, bundlePath: running.bundleURL?.path)
    }

    private func forward(to bundle: URL, holderPID: Int32) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        // Only seen if LaunchServices has to start a new copy (the holder quit): that copy must not forward again.
        configuration.arguments = [InstanceGate.forwardedArgument]
        NSWorkspace.shared.open(urls, withApplicationAt: bundle, configuration: configuration,
                                completionHandler: Self.forwardDone(count: urls.count, bundle: bundle, holderPID: holderPID))
    }

    /// Built outside the main actor: the completion runs on a background queue, and a closure
    /// written in this main-actor class would carry a main-thread check that traps there.
    private nonisolated static func forwardDone(count: Int, bundle: URL, holderPID: Int32) -> @Sendable (NSRunningApplication?, Error?) -> Void {
        { running, error in
            let pid = running?.processIdentifier
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let launch = NSApp.delegate as? LaunchCoordinator else { return }
                    if let message {
                        launch.retry(because: "forwarding to \(bundle.path) failed: \(message)")
                    } else if InstanceGate.forwardReachedHolder(holderPID: holderPID, answeredBy: pid) {
                        launch.finish("forwarded \(count) document(s) to pid \(holderPID) at \(bundle.path)")
                    } else {
                        // LaunchServices started a new copy (the holder had quit). That copy got the documents
                        // and never forwards; retrying here could open them twice.
                        launch.giveUp("pid \(pid.map(String.init) ?? "?") answered instead of the holder (pid \(holderPID))")
                    }
                }
            }
        }
    }

    private func retry(because reason: String) {
        guard attempt < Self.attempts else { return giveUp(reason) }
        log.info("Launch: \(reason, privacy: .public); retrying")
        after(Self.retryDelay) { $0.step() }
    }

    // MARK: - Legacy and no-lock

    private func checkLegacy(lock: InstanceLock) {
        switch LegacyInstances.check(identity.otherInstances(), identity: identity, selfPID: ProcessInfo.processInfo.processIdentifier) {
        case .clear:
            promote(lock)
        case .legacy(let pids):
            guard let seen = suspectedLegacy else {
                // The workspace can still list an instance that has just quit: look again shortly.
                suspectedLegacy = pids
                return after(Self.confirmDelay) { $0.step() }
            }
            let alive = LegacyInstances.stillRunning(Array(Set(seen).intersection(pids)))
            guard !alive.isEmpty else {
                suspectedLegacy = nil
                return step()
            }
            // Released before the notice: launches meanwhile then check for themselves instead of
            // forwarding to this one, which is about to exit.
            lock.release()
            block(Self.legacyNotice,
                  reason: "an older build (Meeting Prompter) without single-instance support is running (pid \(alive.map(String.init).joined(separator: ", ")))")
        }
    }

    private func checkWithoutLock(_ reason: String) {
        log.error("Launch: single-instance lock unavailable: \(reason, privacy: .public)")
        let others = identity.otherInstances()
        if !others.isEmpty {
            return block(Self.noLockNotice(reason, running: true),
                         reason: "lock unavailable and another instance runs (pid \(others.map { String($0.pid) }.joined(separator: ", ")))")
        }
        notify(Self.noLockNotice(reason, running: false)) {}
        promote(nil)
    }

    private func promoteOrCheckLegacy(_ lock: InstanceLock) {
        if identity.otherInstances().isEmpty { promote(lock) } else { checkLegacy(lock: lock) }
    }

    /// Starts nothing: the documents go to the recent files, the user is told why, and this exits.
    private func block(_ text: String, reason: String) {
        keepInRecents()
        log.error("Launch: not starting: \(reason, privacy: .public). \(self.urls.count) document(s) put first in the recent files.")
        notify(text) { [weak self] in self?.finish(nil) }
    }

    // MARK: - Shared

    /// Keeps the documents reachable: first in the recent files of this build's settings.
    private func giveUp(_ reason: String, notice text: String? = nil) {
        keepInRecents()
        log.error("Launch: not opening \(self.urls.count) document(s): \(reason, privacy: .public). They are first in the recent files.")
        guard let text = text ?? (urls.isEmpty ? nil : Self.keptNotice) else { return finish(nil) }
        notify(text) { [weak self] in self?.finish(nil) }
    }

    /// Adds documents not yet kept, e.g. ones that arrived while a notice was up.
    private func keepInRecents() {
        let defaults = UserDefaults.standard
        guard let recents = documents.keep(in: defaults.stringArray(forKey: "recentFiles") ?? []) else { return }
        defaults.set(recents, forKey: "recentFiles")
    }

    /// A non-activating notice (`NoticePanel`: the meeting app keeps the keyboard, nothing blocks) unless
    /// headless; `then` runs when it closes. Always logged by the caller.
    private func notify(_ text: String, then: @escaping @MainActor () -> Void) {
        guard !hooks.headless, notice == nil else { return then() }
        notice = NoticePanel.show(text, timeout: 60) { [weak self] in
            self?.notice = nil
            then()
        }
    }

    /// Exits; documents received after the decision (e.g. while a notice was up) are kept too.
    private func finish(_ message: String?) {
        if let message { log.info("Launch: \(message, privacy: .public)") }
        finished = true
        keepInRecents()
        NSApp.terminate(nil)
    }

    /// Runs as the instance, opening the documents as a normal launch would. The lifetime limits stop applying.
    private func promote(_ lock: InstanceLock?) {
        log.info("Launch: running as the instance\(lock == nil ? " (without the lock)" : "")")
        lifetime.promote()
        let delegate = AppDelegate(instanceLock: lock, hooks: hooks)
        promoted = delegate
        // Kept alive by `promoted` (the application holds its delegate weakly).
        NSApp.delegate = delegate
        NSApp.setActivationPolicy(.accessory)
        if !urls.isEmpty { delegate.application(NSApp, open: urls) }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        urls = []
        documents.clear()
    }

    /// A common-mode timer: it fires during menu tracking or any modal loop too.
    private func after(_ seconds: Double, _ action: @escaping @MainActor (LaunchCoordinator) -> Void) {
        let timer = Timer(timeInterval: max(0, seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static var legacyNotice: String {
        tr(.launchLegacyRunning) + " " + tr(.launchDocumentsKept)
    }

    private static var keptNotice: String { tr(.launchNotForwarded) }

    private static func refusedNotice(holder: InstanceGate.Holder?, documents: Bool) -> String {
        let which = holder.map { " (\($0.bundleID ?? tr(.launchUnbundled)), pid \($0.pid))" } ?? ""
        let lead = tr(.launchOtherRunning, which)
        return documents ? lead + " " + tr(.launchDocumentsKept) : lead
    }

    private static func noLockNotice(_ reason: String, running: Bool) -> String {
        let lead = tr(.launchNoLock, reason)
        return running
            ? lead + " " + tr(.launchNoLockOtherRunning) + " " + tr(.launchDocumentsKept)
            : lead + " " + tr(.launchNoLockAlone)
    }
}
