import AppKit
import PrompterCore

// One instance per user, whichever build (`InstanceLock`). Decided before anything else
// exists: unless this launch holds the lock and nothing of the same family runs without it,
// `LaunchCoordinator` takes over and creates no settings, overlay, status item or tap until
// it is sure this is the only instance.
let app = NSApplication.shared
let identity = AppIdentity.current
let hooks = TestHooks.from(identity: identity, environment: ProcessInfo.processInfo.environment)
let forwarded = CommandLine.arguments.contains(InstanceGate.forwardedArgument)
let delegate: NSApplicationDelegate
switch InstanceLock.acquire(at: InstanceLock.url(identity: identity, hooks: hooks)) {
case .acquired(let lock) where identity.otherInstances().isEmpty:
    delegate = AppDelegate(instanceLock: lock, hooks: hooks)
    app.setActivationPolicy(.accessory)
case .acquired(let lock):
    delegate = LaunchCoordinator(mode: .checkLegacy(lock), identity: identity, hooks: hooks, forwarded: forwarded)
    app.setActivationPolicy(.prohibited)
case .held:
    delegate = LaunchCoordinator(mode: .secondary, identity: identity, hooks: hooks, forwarded: forwarded)
    app.setActivationPolicy(.prohibited)
case .unavailable(let reason):
    delegate = LaunchCoordinator(mode: .noLock(reason), identity: identity, hooks: hooks, forwarded: forwarded)
    app.setActivationPolicy(.prohibited)
}
app.delegate = delegate
app.run()
