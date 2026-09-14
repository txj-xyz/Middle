import Combine
import Foundation

enum GestureKind: String, CaseIterable, Identifiable {
    /// Rest N fingers on the trackpad without clicking.
    case multiFingerTap
    /// Physically click the trackpad with N fingers down.
    case multiFingerClick
    /// Physically click with a finger in the bottom-centre strip, like a Linux clickpad.
    case bottomZoneClick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .multiFingerTap: return "Multi-finger tap"
        case .multiFingerClick: return "Multi-finger click"
        case .bottomZoneClick: return "Bottom-centre click zone"
        }
    }

    var detail: String {
        switch self {
        case .multiFingerTap:
            return "Tap with the chosen number of fingers to middle-click; rest them and move to drag."
        case .multiFingerClick:
            return "Press the trackpad down with the chosen number of fingers; move to drag, release to let go."
        case .bottomZoneClick:
            return "Press the trackpad down with one finger in the bottom-centre strip; move to drag."
        }
    }

    /// Whether the gesture keeps several fingers planted while dragging. Those
    /// gestures need synthetic pointer motion, because macOS will not move the
    /// cursor for multi-finger contact.
    var usesSyntheticMotion: Bool {
        self != .bottomZoneClick
    }
}

/// User-facing settings, persisted in UserDefaults and mirrored into an
/// immutable `Config` snapshot that the gesture engine reads under its lock.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var enabled: Bool { didSet { save(enabled, "enabled") } }
    @Published var gesture: GestureKind { didSet { save(gesture.rawValue, "gesture") } }
    @Published var fingerCount: Int { didSet { save(fingerCount, "fingerCount") } }
    @Published var tapTimeout: Double { didSet { save(tapTimeout, "tapTimeout") } }
    @Published var holdDelay: Double { didSet { save(holdDelay, "holdDelay") } }
    @Published var tapSlop: Double { didSet { save(tapSlop, "tapSlop") } }
    @Published var pointerSpeed: Double { didSet { save(pointerSpeed, "pointerSpeed") } }
    @Published var zoneXMin: Double { didSet { save(zoneXMin, "zoneXMin") } }
    @Published var zoneXMax: Double { didSet { save(zoneXMax, "zoneXMax") } }
    @Published var zoneYMax: Double { didSet { save(zoneYMax, "zoneYMax") } }
    /// Turn off the macOS gestures that compete for the same fingers while
    /// Middle is running, and restore them when it quits.
    @Published var manageSystemGestures: Bool { didSet { save(manageSystemGestures, "manageSystemGestures") } }
    /// The Dock only reads those settings at startup, so restarting it is what
    /// makes borrowing and returning take effect without a log out.
    @Published var restartDockOnChange: Bool { didSet { save(restartDockOnChange, "restartDockOnChange") } }
    /// Withhold the gesture event stream from other processes while one of our
    /// gestures is in progress.
    @Published var suppressSystemGestures: Bool { didSet { save(suppressSystemGestures, "suppressSystemGestures") } }
    /// Move the conflicting swipes to the finger count Middle is not using,
    /// rather than switching them off outright.
    @Published var relocateSystemGestures: Bool { didSet { save(relocateSystemGestures, "relocateSystemGestures") } }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "enabled": true,
            "gesture": GestureKind.multiFingerTap.rawValue,
            "fingerCount": 3,
            "tapTimeout": 0.25,
            "holdDelay": 0.18,
            "tapSlop": 0.05,
            "pointerSpeed": 1700.0,
            "zoneXMin": 0.34,
            "zoneXMax": 0.66,
            "zoneYMax": 0.25,
            "manageSystemGestures": true,
            "restartDockOnChange": false,
            "suppressSystemGestures": true,
            "relocateSystemGestures": true,
        ])
        enabled = defaults.bool(forKey: "enabled")
        gesture = GestureKind(rawValue: defaults.string(forKey: "gesture") ?? "") ?? .multiFingerTap
        fingerCount = defaults.integer(forKey: "fingerCount")
        tapTimeout = defaults.double(forKey: "tapTimeout")
        holdDelay = defaults.double(forKey: "holdDelay")
        tapSlop = defaults.double(forKey: "tapSlop")
        pointerSpeed = defaults.double(forKey: "pointerSpeed")
        zoneXMin = defaults.double(forKey: "zoneXMin")
        zoneXMax = defaults.double(forKey: "zoneXMax")
        zoneYMax = defaults.double(forKey: "zoneYMax")
        manageSystemGestures = defaults.bool(forKey: "manageSystemGestures")
        restartDockOnChange = defaults.bool(forKey: "restartDockOnChange")
        suppressSystemGestures = defaults.bool(forKey: "suppressSystemGestures")
        relocateSystemGestures = defaults.bool(forKey: "relocateSystemGestures")
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .preferencesChanged, object: nil)
    }

    /// The single switch the settings window shows. The three mechanisms below
    /// it stay separately settable with `defaults` for debugging, but they move
    /// together for anyone using the UI.
    var handlesGestureConflicts: Bool {
        get { suppressSystemGestures }
        set {
            suppressSystemGestures = newValue
            manageSystemGestures = newValue
            relocateSystemGestures = newValue
        }
    }

    var config: Config {
        Config(enabled: enabled,
               gesture: gesture,
               fingerCount: fingerCount,
               tapTimeout: tapTimeout,
               holdDelay: holdDelay,
               tapSlop: tapSlop,
               pointerSpeed: pointerSpeed,
               zoneX: min(zoneXMin, zoneXMax)...max(zoneXMin, zoneXMax),
               zoneYMax: zoneYMax,
               suppressSystemGestures: suppressSystemGestures)
    }

    func resetToDefaults() {
        for key in ["enabled", "gesture", "fingerCount", "tapTimeout", "holdDelay",
                    "tapSlop", "pointerSpeed", "zoneXMin", "zoneXMax", "zoneYMax",
                    "manageSystemGestures", "restartDockOnChange",
                    "suppressSystemGestures", "relocateSystemGestures"] {
            defaults.removeObject(forKey: key)
        }
        enabled = defaults.bool(forKey: "enabled")
        gesture = GestureKind(rawValue: defaults.string(forKey: "gesture") ?? "") ?? .multiFingerTap
        fingerCount = defaults.integer(forKey: "fingerCount")
        tapTimeout = defaults.double(forKey: "tapTimeout")
        holdDelay = defaults.double(forKey: "holdDelay")
        tapSlop = defaults.double(forKey: "tapSlop")
        pointerSpeed = defaults.double(forKey: "pointerSpeed")
        zoneXMin = defaults.double(forKey: "zoneXMin")
        zoneXMax = defaults.double(forKey: "zoneXMax")
        zoneYMax = defaults.double(forKey: "zoneYMax")
        manageSystemGestures = defaults.bool(forKey: "manageSystemGestures")
        restartDockOnChange = defaults.bool(forKey: "restartDockOnChange")
        suppressSystemGestures = defaults.bool(forKey: "suppressSystemGestures")
        relocateSystemGestures = defaults.bool(forKey: "relocateSystemGestures")
    }
}

/// Immutable snapshot handed to the gesture engine.
struct Config {
    var enabled = true
    var gesture: GestureKind = .multiFingerTap
    var fingerCount = 3
    var tapTimeout = 0.25
    var holdDelay = 0.18
    var tapSlop = 0.05
    var pointerSpeed = 1700.0
    var zoneX: ClosedRange<Double> = 0.34...0.66
    var zoneYMax = 0.25
    var suppressSystemGestures = true
}

extension Notification.Name {
    static let preferencesChanged = Notification.Name("MiddlePreferencesChanged")
    static let engagementChanged = Notification.Name("MiddleEngagementChanged")
}
