import CoreGraphics
import Foundation

/// Synthesises the middle mouse button: click, press-and-hold, and the drag
/// events that apps actually listen for while it is held.
///
/// The interesting part is motion. If we post an `otherMouseDown` and never
/// release it, macOS has no idea a button is held and keeps emitting plain
/// `mouseMoved` events — so apps that care about middle-drag (Blender, CAD,
/// Figma, terminal autoscroll) see nothing. Every pointer movement during a
/// hold therefore has to reach the system as `otherMouseDragged`, either
/// rewritten from a real event (see EventTapController) or generated here from
/// raw finger motion.
final class MiddleButton {

    /// Stamped on every event we create so our own event tap can recognise and
    /// ignore them instead of reprocessing them.
    static let eventMagic: Int64 = 0x4D49_4444_4C45  // "MIDDLE"

    private(set) var isDown = false
    private var cursor: CGPoint = .zero
    private var residual = CGVector(dx: 0, dy: 0)

    private lazy var source: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = MiddleButton.eventMagic
        return source
    }()

    // MARK: - Button

    /// A plain middle click at the current pointer location.
    func click() {
        let point = currentLocation()
        post(.otherMouseDown, at: point)
        post(.otherMouseUp, at: point)
    }

    func press() {
        guard !isDown else { return }
        cursor = currentLocation()
        residual = CGVector(dx: 0, dy: 0)
        isDown = true
        post(.otherMouseDown, at: cursor)
    }

    func release() {
        guard isDown else { return }
        isDown = false
        post(.otherMouseUp, at: cursor)
    }

    // MARK: - Motion

    /// Drive the pointer from raw trackpad motion, for gestures that keep
    /// several fingers planted (macOS will not move the cursor for those).
    /// `delta` is in normalized trackpad units; y grows upwards on the
    /// trackpad and downwards on screen.
    func move(byNormalized delta: CGVector, speed: Double) {
        guard isDown else { return }
        let dx = delta.dx * CGFloat(speed) + residual.dx
        let dy = -delta.dy * CGFloat(speed) + residual.dy
        let stepX = dx.rounded(.towardZero)
        let stepY = dy.rounded(.towardZero)
        residual = CGVector(dx: dx - stepX, dy: dy - stepY)
        guard stepX != 0 || stepY != 0 else { return }

        cursor = MiddleButton.clampToDisplays(CGPoint(x: cursor.x + stepX, y: cursor.y + stepY))
        post(.otherMouseDragged, at: cursor, deltaX: Int64(stepX), deltaY: Int64(stepY))
    }

    /// Keep our idea of the pointer in sync when the system moved it for us
    /// (the single-finger click-zone gesture).
    func syncCursor(to point: CGPoint) {
        cursor = point
    }

    // MARK: - Plumbing

    private func post(_ type: CGEventType, at point: CGPoint, deltaX: Int64 = 0, deltaY: Int64 = 0) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .center) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        if deltaX != 0 || deltaY != 0 {
            event.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
            event.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
        }
        event.post(tap: .cghidEventTap)
    }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? cursor
    }

    /// Clamp to the union of the active displays so a long drag cannot walk the
    /// pointer off into nowhere.
    static func clampToDisplays(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return point }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        var bounds: CGRect = .null
        var containing: CGRect?
        for id in ids {
            let frame = CGDisplayBounds(id)
            bounds = bounds.union(frame)
            if frame.contains(point) { containing = frame }
        }
        // Inside a display: nothing to do. Otherwise pull back into the union.
        if containing != nil { return point }
        guard !bounds.isNull else { return point }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }
}
