import CoreGraphics
import Foundation

/// One finger as reported by the trackpad, in normalized trackpad coordinates
/// (0...1 on both axes, origin at the bottom-left of the surface).
struct Finger {
    var id: Int
    var position: CGPoint
    var size: Float
}

/// One frame from the trackpad: every finger currently in contact.
struct TouchFrame {
    var time: CFTimeInterval
    var fingers: [Finger]

    var count: Int { fingers.count }

    var centroid: CGPoint {
        guard !fingers.isEmpty else { return .zero }
        var sum = CGPoint.zero
        for f in fingers {
            sum.x += f.position.x
            sum.y += f.position.y
        }
        return CGPoint(x: sum.x / CGFloat(fingers.count), y: sum.y / CGFloat(fingers.count))
    }

    /// Mean movement of the fingers that are present in *both* frames.
    ///
    /// Averaging per-finger deltas rather than differencing the centroids keeps
    /// the drag from jumping when a finger lands or lifts mid-gesture.
    func meanDelta(since previous: TouchFrame) -> CGVector? {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var matched = 0
        for f in fingers {
            guard let p = previous.fingers.first(where: { $0.id == f.id }) else { continue }
            dx += f.position.x - p.position.x
            dy += f.position.y - p.position.y
            matched += 1
        }
        guard matched > 0 else { return nil }
        return CGVector(dx: dx / CGFloat(matched), dy: dy / CGFloat(matched))
    }

    func contains(fingerIn xRange: ClosedRange<Double>, yBelow: Double) -> Bool {
        fingers.contains { xRange.contains(Double($0.position.x)) && Double($0.position.y) <= yBelow }
    }

    static let empty = TouchFrame(time: 0, fingers: [])
}
