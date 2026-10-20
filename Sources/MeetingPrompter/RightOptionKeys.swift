import AppKit
import ApplicationServices
import os

/// Global shortcuts held with the right-hand Option key only.
///
/// Carbon hot keys cannot tell left from right Option, so this uses a CGEvent tap
/// and reads the device-dependent modifier bits. Matched keystrokes are swallowed,
/// so the focused app never receives them. The tap needs Accessibility access.
///
/// The tap runs on its own thread and only decides; actions run afterwards on the
/// main thread. Nothing the app does (a modal dialog, a slow load) can stall the
/// tap: a stalled tap is disabled by the system and lets keystrokes through to the
/// meeting app.
///
/// Everything the tap thread runs lives in `TapState`, which has no actor isolation.
/// A closure written inside this `@MainActor` class is main-actor isolated, and Swift 6
/// checks that at run time: called on the tap thread, it traps (crashed every keystroke).
@MainActor
final class RightOptionKeys {
    static let shared = RightOptionKeys()

    private struct Binding {
        let condition: ShortcutCondition
        let onPress: () -> Void
        let onRelease: (() -> Void)?
    }

    private let log = Logger(subsystem: "MeetingPrompter", category: "shortcuts")
    private var bindings: [Int64: Binding] = [:]
    /// Keys whose press ran, so their release runs too.
    private var pressed: Set<Int64> = []
    private var tap: CFMachPort?
    private var trustPoll: Timer?
    private var watchdog: Timer?
    private var onTrustChange: (() -> Void)?
    private var stateObserver: CFRunLoopObserver?
    /// The app state the conditions read, published to the tap thread.
    private var state: () -> TapState.Snapshot = { TapState.Snapshot(overlayVisible: false, pickerOpen: false) }

    var isActive: Bool { tap != nil }

    /// Registers right-⌥ + `keyCode`. When `condition` does not hold the keystroke
    /// passes through to the focused app untouched.
    func register(keyCode: Int, when condition: ShortcutCondition = .always,
                  onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
        bindings[Int64(keyCode)] = Binding(condition: condition, onPress: onPress, onRelease: onRelease)
        TapState.shared.setCondition(condition, for: Int64(keyCode))
    }

    /// Installs the tap, asking for Accessibility access first if needed and
    /// installing as soon as it is granted. `onChange` fires when the tap goes live.
    /// `state` is read on the main thread after every run loop pass.
    func start(state: @escaping () -> TapState.Snapshot, onChange: @escaping () -> Void) {
        self.state = state
        onTrustChange = onChange
        observeState()
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            installTap()
            return
        }
        trustPoll?.invalidate()
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let keys = RightOptionKeys.shared
                guard AXIsProcessTrusted() else { return }
                keys.trustPoll?.invalidate()
                keys.trustPoll = nil
                keys.installTap()
            }
        }
    }

    /// Publishes the state before the main thread sleeps, so every change reaches the tap.
    private func observeState() {
        guard stateObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { RightOptionKeys.shared.publishState() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        stateObserver = observer
        publishState()
    }

    private func publishState() {
        TapState.shared.publish(state())
    }

    private func installTap() {
        guard tap == nil else { return }
        guard let tap = TapState.shared.install() else {
            log.error("CGEvent.tapCreate failed")
            return
        }
        self.tap = tap
        // Backstop for a disable notice that never arrives: the tap re-enables itself on one.
        // Common modes, so it also runs during the open dialog, menus and window drags.
        let watchdog = Timer(timeInterval: 2, repeats: true, block: TapState.watchdogTick)
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
        onTrustChange?()
    }

    /// Runs on the main thread for each swallowed press or release, in order.
    fileprivate func deliver(keyCode: Int64, press: Bool) {
        guard let binding = bindings[keyCode] else { return }
        if press {
            // Re-checked here: the tap may have swallowed on a stale snapshot.
            guard binding.condition.holds(in: state()), !pressed.contains(keyCode) else { return }
            pressed.insert(keyCode)
            binding.onPress()
        } else if pressed.remove(keyCode) != nil {
            binding.onRelease?()
        }
        publishState()
    }
}

/// When a registered shortcut is ours; otherwise the keystroke reaches the focused app.
/// Read on the tap thread, so no actor isolation.
enum ShortcutCondition: Sendable {
    case always
    case overlayVisible
    case pickerOpen

    func holds(in state: TapState.Snapshot) -> Bool {
        switch self {
        case .always: true
        case .overlayVisible: state.overlayVisible
        case .pickerOpen: state.pickerOpen
        }
    }
}

/// The tap itself and what its thread knows: registered keys, the published app state,
/// and the keys it is holding. Touched by the tap thread and the main thread under a lock.
/// No actor isolation anywhere in here: this is the code the tap thread runs.
final class TapState: @unchecked Sendable {
    static let shared = TapState()

    struct Snapshot: Sendable {
        var overlayVisible: Bool
        var pickerOpen: Bool
    }

    // Device-dependent Option bits from IOKit's IOLLEvent.h.
    private static let leftOptionMask: UInt64 = 0x20  // NX_DEVICELALTKEYMASK
    private static let rightOptionMask: UInt64 = 0x40 // NX_DEVICERALTKEYMASK

    private let lock = NSLock()
    private var conditions: [Int64: ShortcutCondition] = [:]
    private var snapshot = Snapshot(overlayVisible: false, pickerOpen: false)
    /// Presses handed to the main thread and not yet run; the snapshot may predate them.
    private var pending = 0
    private var heldKeys: Set<Int64> = []
    /// Keys whose key-down was swallowed, so their key-up is swallowed too.
    private var swallowedUps: Set<Int64> = []
    /// Set once by `install` before the tap thread starts.
    private(set) var port: CFMachPort?

    /// The C callback. A static property's initializer runs outside any actor, so this
    /// closure carries no isolation check (one written in `RightOptionKeys` did).
    static let callback: CGEventTapCallBack = { _, type, event, _ in
        TapState.shared.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }

    /// Creates the tap and runs it on its own thread. Nil when the system refuses (no Accessibility).
    func install() -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: Self.callback, userInfo: nil) else { return nil }
        port = tap
        let thread = Thread(block: Self.runTapThread)
        thread.name = "RightOptionKeys tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return tap
    }

    private static let runTapThread: @Sendable () -> Void = {
        guard let tap = TapState.shared.port else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    static let watchdogTick: @Sendable (Timer) -> Void = { _ in
        guard let tap = TapState.shared.port, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        TapState.shared.releaseAll()
    }

    func setCondition(_ condition: ShortcutCondition, for keyCode: Int64) {
        lock.withLock { conditions[keyCode] = condition }
    }

    func publish(_ state: Snapshot) {
        lock.withLock { snapshot = state }
    }

    /// Ends held shortcuts whose key-up may have been lost while the tap was disabled.
    func releaseAll() {
        let held = lock.withLock {
            let held = heldKeys
            heldKeys.removeAll()
            return held
        }
        for keyCode in held { post(keyCode, press: false) }
    }

    /// Tap thread. Returns true when the event is ours and must not reach the focused app.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            releaseAll()
            return false
        }
        if type == .flagsChanged {
            // Letting go of right Option ends every held shortcut, whichever key goes up first.
            if event.flags.rawValue & Self.rightOptionMask == 0 { releaseAll() }
            return false
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags
        let rightOptionOnly = flags.rawValue & Self.rightOptionMask != 0
            && flags.rawValue & Self.leftOptionMask == 0
            && flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty

        enum Outcome { case pass, swallow, press, release }
        let outcome: Outcome = lock.withLock {
            guard let condition = conditions[keyCode] else { return .pass }
            if type == .keyUp {
                // A key-up is ours whenever its key-down was, even if Option went up first.
                let wasSwallowed = swallowedUps.remove(keyCode) != nil
                if heldKeys.remove(keyCode) != nil { return .release }
                return wasSwallowed ? .swallow : .pass
            }
            guard type == .keyDown else { return .pass }
            // Auto-repeat of a key we took, even after Option was released, must not type into the app.
            if heldKeys.contains(keyCode) || (isRepeat && swallowedUps.contains(keyCode)) { return .swallow }
            // A fresh press that is not ours: its key-up belongs to the app.
            guard rightOptionOnly else {
                swallowedUps.remove(keyCode)
                return .pass
            }
            // While presses are queued the snapshot may be stale; keep the key (the main thread re-checks).
            guard pending > 0 || condition.holds(in: snapshot) else {
                swallowedUps.remove(keyCode)
                return .pass
            }
            heldKeys.insert(keyCode)
            swallowedUps.insert(keyCode)
            pending += 1
            return .press
        }
        switch outcome {
        case .pass: return false
        case .swallow: return true
        case .press: post(keyCode, press: true); return true
        case .release: post(keyCode, press: false); return true
        }
    }

    /// Hands a press or release to the main thread, after whatever is already queued.
    /// A run loop block, not the main dispatch queue: an action may run a modal dialog,
    /// and a modal loop started inside a main-queue block would hold back every later
    /// main-queue job (main actor tasks included) until the dialog closes.
    private func post(_ keyCode: Int64, press: Bool) {
        RunLoop.main.perform(inModes: [.common]) {
            if press { self.lock.withLock { self.pending = max(0, self.pending - 1) } }
            MainActor.assumeIsolated { RightOptionKeys.shared.deliver(keyCode: keyCode, press: press) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
