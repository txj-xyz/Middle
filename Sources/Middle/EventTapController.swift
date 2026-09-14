import CoreGraphics
import Foundation

/// Owns the CGEventTap that lets us claim trackpad clicks and turn pointer
/// motion into middle-drags.
///
/// The tap lives on its own thread with its own run loop: if it ran on the main
/// thread, anything that blocked the UI (a menu being tracked, a slow redraw)
/// would make the tap miss its deadline and get disabled by the system.
final class EventTapController {

    enum StartError: LocalizedError {
        case permissionDenied

        var errorDescription: String? {
            "Middle needs Accessibility permission to read and post mouse events."
        }
    }

    private let engine: GestureEngine
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var thread: Thread?

    init(engine: GestureEngine) {
        self.engine = engine
    }

    func start() throws {
        guard thread == nil else { return }
        var startupError: Error?
        let ready = DispatchSemaphore(value: 0)

        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            do {
                try self.installTap()
            } catch {
                startupError = error
                ready.signal()
                return
            }
            self.tapRunLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.joeyfinelli.middle.eventtap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        ready.wait()
        if let startupError {
            self.thread = nil
            throw startupError
        }
    }

    func stop() {
        engine.forceRelease()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapRunLoop {
            CFRunLoopStop(tapRunLoop)
        }
        if let source, let tapRunLoop {
            CFRunLoopRemoveSource(tapRunLoop, source, .commonModes)
        }
        tap = nil
        source = nil
        tapRunLoop = nil
        thread = nil
    }

    private func installTap() throws {
        var mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue)
        // The gesture family has no constants in CGEventType, so the bits are
        // set by raw value. See GestureEngine.gestureEventTypes.
        for raw in GestureEngine.gestureEventTypes {
            mask |= (1 << CGEventMask(raw))
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            throw StartError.permissionDenied
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    fileprivate func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func process(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // Our own synthesised events must never be reprocessed — posting from
        // inside a tap callback re-enters this function on the same thread.
        if event.getIntegerValueField(.eventSourceUserData) == MiddleButton.eventMagic {
            return Unmanaged.passUnretained(event)
        }
        guard let result = engine.handle(event: event, type: type) else { return nil }
        return Unmanaged.passUnretained(result)
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()

    // The system disables a tap that takes too long, or on a user-input switch.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        controller.reenable()
        return nil
    }
    return controller.process(event: event, type: type)
}
