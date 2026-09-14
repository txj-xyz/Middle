import AppKit
import CoreGraphics
import Foundation

/// `Middle --diagnose-conflict` — investigates why macOS keeps its three-finger
/// gestures despite our preference writes.
///
/// It answers two questions at once:
///
///  1. Does a Mission Control swipe reach us as a CGEvent? If it does, we can
///     swallow it in the event tap and never touch the user's settings at all.
///  2. What does System Settings post when the same gesture is toggled by hand?
///     Whatever that is, it is the notification that makes the change take
///     effect live.
///
/// The tap is listen-only, so running this cannot break anything.
enum ConflictDiagnostic {

    private static var eventCounts: [Int64: Int] = [:]
    private static var firstSeen: [Int64: String] = [:]
    private static var notifications: [String] = []
    private static var log: FileHandle?
    private static let start = Date()

    // Keyboard events are excluded from the tap mask entirely: we have no
    // business seeing keystrokes, even in a diagnostic.
    private static let excluded: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]

    static func run(seconds: Double, path: String) -> Never {
        FileManager.default.createFile(atPath: path, contents: nil)
        log = FileHandle(forWritingAtPath: path)
        write("Middle conflict diagnostic — \(Date())")
        write("")

        guard installTap() else {
            write("Could not create an event tap. Launch this through the app bundle")
            write("so it inherits Middle's Accessibility grant:")
            write("  open -n build/Middle.app --args --diagnose-conflict")
            finish()
        }
        observeNotifications()

        write("Watching for \(Int(seconds)) seconds. Please, in this order:")
        write("  1. Swipe up with THREE fingers (let Mission Control open and close)")
        write("  2. Swipe left/right with THREE fingers")
        write("  3. Open System Settings > Trackpad > More Gestures and toggle")
        write("     'Mission Control' off, then on again")
        write("")

        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        finish()
    }

    // MARK: - Events

    private static func installTap() -> Bool {
        var mask = CGEventMask(bitPattern: ~0)
        for type in excluded {
            mask &= ~(1 << CGEventMask(type.rawValue))
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                ConflictDiagnostic.record(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil)
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private static func record(type: CGEventType, event: CGEvent) {
        let raw = Int64(type.rawValue)
        // Pointer motion and scrolling drown out everything else.
        if [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged].contains(type) { return }

        eventCounts[raw, default: 0] += 1
        if firstSeen[raw] == nil {
            firstSeen[raw] = String(format: "%.1fs", Date().timeIntervalSince(start))
            // Undocumented gesture types carry their detail in these fields.
            let subtype = event.getIntegerValueField(.eventSourceUserData)
            write(String(format: "  event type %3d  first seen at %@  (subtype field %d)",
                         raw, firstSeen[raw] ?? "?", subtype))
        }
    }

    // MARK: - Notifications

    private static func observeNotifications() {
        DistributedNotificationCenter.default().addObserver(
            forName: nil, object: nil, queue: .main
        ) { note in
            let name = note.name.rawValue
            // Only the ones plausibly about input devices; the session posts a
            // constant background hum otherwise.
            let interesting = ["trackpad", "multitouch", "gesture", "mouse", "hid",
                               "dock", "spaces", "mission"]
            guard interesting.contains(where: { name.lowercased().contains($0) }) else { return }
            notifications.append(name)
            write(String(format: "  notification at %.1fs: %@",
                         Date().timeIntervalSince(start), name))
        }
    }

    // MARK: - Output

    private static func write(_ line: String) {
        print(line)
        log?.write((line + "\n").data(using: .utf8)!)
    }

    private static func finish() -> Never {
        write("")
        write("=== Event types seen ===")
        for (type, count) in eventCounts.sorted(by: { $0.key < $1.key }) {
            write(String(format: "  type %3d  x%-5d  first at %@", type, count, firstSeen[type] ?? "?"))
        }
        write("")
        write("=== Input-related distributed notifications ===")
        if notifications.isEmpty {
            write("  (none)")
        } else {
            for name in notifications { write("  \(name)") }
        }
        try? log?.close()
        exit(0)
    }
}
