import AppKit
import Foundation

/// Borrows the macOS trackpad gestures that fight with ours, and gives them
/// back when we quit.
///
/// A CGEventTap cannot suppress Mission Control or app switching: those are
/// recognised from the multitouch stream by the system, well before anything
/// reaches the mouse event stream we tap. The only way to stop three fingers
/// being claimed twice is to turn the system's own gesture off for as long as
/// Middle is using those fingers.
///
/// Every value we overwrite is stashed first — including the fact that a key
/// was previously absent — and the stash is persisted immediately, so a crash
/// or a `kill` still leaves the user's settings recoverable on next launch.
final class SystemGestureCoordinator {

    /// One preference we may borrow. `previous == nil` means the key did not
    /// exist before we wrote it and should be removed again on restore.
    private struct Borrowed: Codable {
        var domain: String
        var key: String
        var currentHost: Bool
        var previous: Int?
    }

    private struct Target {
        var domain: String
        var key: String
        /// Where the value lives when nothing is set yet.
        var prefersCurrentHost: Bool
        /// What to write: 0 turns the gesture off, 2 turns it on.
        var value: Int
    }

    /// The two swipe gestures that compete with us, by the axis they use.
    private enum Axis {
        case vertical    // Mission Control (up) and App Exposé (down)
        case horizontal  // Swipe between full-screen applications

        func keys(fingers: Int) -> (trackpad: String, global: String) {
            let word = fingers == 4 ? "Four" : "Three"
            let lower = fingers == 4 ? "four" : "three"
            switch self {
            case .vertical:
                return ("Trackpad\(word)FingerVertSwipeGesture",
                        "com.apple.trackpad.\(lower)FingerVertSwipeGesture")
            case .horizontal:
                return ("Trackpad\(word)FingerHorizSwipeGesture",
                        "com.apple.trackpad.\(lower)FingerHorizSwipeGesture")
            }
        }
    }

    private static let gestureEnabledValue = 2

    private static let stashKey = "borrowedSystemGestures"
    private static let trackpadDomains = [
        "com.apple.AppleMultitouchTrackpad",                  // built-in
        "com.apple.driver.AppleBluetoothMultitouch.trackpad", // Magic Trackpad
    ]
    private static let globalDomain = kCFPreferencesAnyApplication as String

    private let defaults = UserDefaults.standard
    private var appliedIntent: String?

    /// Whether anything is currently borrowed.
    private(set) var isBorrowing = false

    /// Human-readable summary for the settings window.
    private(set) var summary: String?

    // MARK: - Public API

    /// Restore anything a previous run left behind. Call once at launch, before
    /// applying, so a crashed run never strands the user's settings.
    func recoverFromPreviousRun() {
        guard loadStash() != nil else { return }
        NSLog("Middle: restoring trackpad gestures left borrowed by a previous run.")
        restore(restartDock: false)
    }

    /// Borrow whatever the given configuration conflicts with. Re-applying the
    /// same configuration is free.
    func apply(for config: Config, prefs: Preferences) {
        // Cheap check first: nothing about the intent changed, so the values on
        // disk are already what we want.
        let intent = [
            prefs.manageSystemGestures ? "on" : "off",
            prefs.relocateSystemGestures ? "move" : "suspend",
            config.enabled ? "enabled" : "disabled",
            config.gesture.rawValue,
            String(config.fingerCount),
        ].joined(separator: "/")
        guard intent != appliedIntent else { return }

        // Hand back the previous borrow before reading anything: the plan has
        // to be computed from the user's real values, not from ours.
        restore(restartDock: false)
        appliedIntent = intent

        guard prefs.manageSystemGestures, config.enabled else {
            notifySystem(restartDock: prefs.restartDockOnChange)
            return
        }

        let targets = plan(for: config, relocate: prefs.relocateSystemGestures)
        guard !targets.isEmpty else {
            summary = nil
            return
        }

        var stash: [Borrowed] = []
        for target in targets {
            stash.append(contentsOf: borrow(target))
        }
        saveStash(stash)
        synchronize(domains: Set(targets.map(\.domain)))
        isBorrowing = true
        summary = Self.describe(targets, ours: config.fingerCount == 4 ? 4 : 3)
        notifySystem(restartDock: prefs.restartDockOnChange)
    }

    /// Put every borrowed setting back the way we found it.
    func restore(restartDock: Bool) {
        guard let stash = loadStash(), !stash.isEmpty else {
            isBorrowing = false
            summary = nil
            appliedIntent = nil
            return
        }

        for item in stash {
            write(item.previous, key: item.key, domain: item.domain, currentHost: item.currentHost)
        }
        synchronize(domains: Set(stash.map(\.domain)))
        clearStash()
        isBorrowing = false
        summary = nil
        appliedIntent = nil
        notifySystem(restartDock: restartDock)
    }

    // MARK: - Which settings conflict

    /// Work out what to write.
    ///
    /// Rather than simply switching the conflicting swipes off, we move them to
    /// the finger count Middle is not using — so three-finger mode leaves you
    /// Mission Control and full-screen app switching on four fingers, and vice
    /// versa. A gesture you already had turned off stays off: we relocate what
    /// exists, we never add a gesture you did not have.
    private func plan(for config: Config, relocate: Bool) -> [Target] {
        // A single finger in the click zone collides with nothing.
        guard config.gesture != .bottomZoneClick else { return [] }

        let ours = config.fingerCount == 4 ? 4 : 3
        let other = ours == 3 ? 4 : 3
        var targets: [Target] = []

        for axis in [Axis.vertical, .horizontal] {
            let ourKeys = axis.keys(fingers: ours)
            let previous = canonicalValue(for: ourKeys)
            targets += Self.expand(ourKeys, value: 0)

            if relocate, let previous, previous != 0 {
                // Carry the setting across at the value it already had.
                targets += Self.expand(axis.keys(fingers: other), value: previous)
            }
        }

        // Resting fingers also collides with three-finger tap (Look up) and
        // with the accessibility three-finger drag; clicking does not. Neither
        // has a four-finger equivalent to move to, so they are simply off.
        if config.gesture == .multiFingerTap && ours == 3 {
            targets += Self.expand(
                ("TrackpadThreeFingerTapGesture", "com.apple.trackpad.threeFingerTapGesture"), value: 0)
            targets += Self.expand(
                ("TrackpadThreeFingerDrag", "com.apple.trackpad.threeFingerDragGesture"), value: 0)
        }
        return targets
    }

    /// One logical setting lives in several places: both trackpad domains and
    /// the ByHost global mirror.
    private static func expand(_ keys: (trackpad: String, global: String), value: Int) -> [Target] {
        var targets = trackpadDomains.map {
            Target(domain: $0, key: keys.trackpad, prefersCurrentHost: false, value: value)
        }
        targets.append(Target(domain: globalDomain, key: keys.global,
                              prefersCurrentHost: true, value: value))
        return targets
    }

    /// The value the system is really using, preferring the built-in trackpad
    /// domain and falling back to the global mirror.
    private func canonicalValue(for keys: (trackpad: String, global: String)) -> Int? {
        read(key: keys.trackpad, domain: Self.trackpadDomains[0], currentHost: false)
            ?? read(key: keys.global, domain: Self.globalDomain, currentHost: true)
            ?? Self.gestureEnabledValue  // absent means the macOS default: on
    }

    private static func describe(_ targets: [Target], ours: Int) -> String {
        let other = ours == 3 ? "four" : "three"
        let moved = targets.contains { $0.value != 0 }
        let ourWord = ours == 3 ? "Three" : "Four"
        if moved {
            return "\(ourWord)-finger swipes moved to \(other) fingers while Middle runs"
        }
        return "\(ourWord)-finger swipes suspended while Middle runs"
    }

    // MARK: - Preference plumbing

    /// Write one target's value, recording what was there before.
    ///
    /// CFPreferences prefers a per-host value over an any-host one, so a value
    /// sitting in the current-host scope has to be neutralised too or it would
    /// shadow ours.
    private func borrow(_ target: Target) -> [Borrowed] {
        var results: [Borrowed] = []
        let anyHost = read(key: target.key, domain: target.domain, currentHost: false)
        let currentHost = read(key: target.key, domain: target.domain, currentHost: true)

        if currentHost != nil || target.prefersCurrentHost {
            results.append(Borrowed(domain: target.domain, key: target.key,
                                    currentHost: true, previous: currentHost))
            write(target.value, key: target.key, domain: target.domain, currentHost: true)
        }
        if anyHost != nil || !target.prefersCurrentHost {
            results.append(Borrowed(domain: target.domain, key: target.key,
                                    currentHost: false, previous: anyHost))
            write(target.value, key: target.key, domain: target.domain, currentHost: false)
        }
        return results
    }

    private func read(key: String, domain: String, currentHost: Bool) -> Int? {
        let value = CFPreferencesCopyValue(
            key as CFString, domain as CFString,
            kCFPreferencesCurrentUser,
            currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost)
        return (value as? NSNumber)?.intValue
    }

    private func write(_ value: Int?, key: String, domain: String, currentHost: Bool) {
        let plist: CFPropertyList? = value.map { NSNumber(value: $0) }
        CFPreferencesSetValue(
            key as CFString, plist, domain as CFString,
            kCFPreferencesCurrentUser,
            currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost)
    }

    private func synchronize(domains: Set<String>) {
        for domain in domains {
            CFPreferencesAppSynchronize(domain as CFString)
        }
    }

    /// Nudge the processes that act on these settings. The Dock is what turns a
    /// recognised swipe into Mission Control, and it only reads the preference
    /// at startup — so restarting it is what makes the change take effect
    /// without logging out.
    private func notifySystem(restartDock: Bool) {
        let center = CFNotificationCenterGetDistributedCenter()
        for name in ["com.apple.MultitouchSupport.HID.deviceSettingsChanged",
                     "com.apple.dock.prefchanged"] {
            CFNotificationCenterPostNotification(
                center, CFNotificationName(name as CFString), nil, nil, true)
        }
        guard restartDock else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
    }

    // MARK: - Stash

    private func loadStash() -> [Borrowed]? {
        guard let data = defaults.data(forKey: Self.stashKey),
              let stash = try? JSONDecoder().decode([Borrowed].self, from: data),
              !stash.isEmpty else { return nil }
        return stash
    }

    private func saveStash(_ stash: [Borrowed]) {
        guard let data = try? JSONEncoder().encode(stash) else { return }
        defaults.set(data, forKey: Self.stashKey)
        // Persist now: if we are killed a moment later, the stash is what lets
        // the next launch give the settings back.
        defaults.synchronize()
    }

    private func clearStash() {
        defaults.removeObject(forKey: Self.stashKey)
        defaults.synchronize()
    }
}
