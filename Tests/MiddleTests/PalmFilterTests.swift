import CoreGraphics
import XCTest
@testable import Middle

/// The palm thresholds are heuristics, so these pin down what each rule is for
/// — and, just as importantly, what must *not* be rejected.
final class PalmFilterTests: XCTestCase {

    private func contact(_ id: Int, size: Float, axis: Float = 10) -> Finger {
        Finger(id: id, position: CGPoint(x: 0.5, y: 0.5), size: size, majorAxis: axis)
    }

    private func frame(_ fingers: [Finger]) -> TouchFrame {
        TouchFrame(time: 0, fingers: fingers)
    }

    func testFingertipsArePassedThrough() {
        var filter = PalmFilter()
        let result = filter.apply(to: frame([contact(1, size: 0.9),
                                             contact(2, size: 1.0),
                                             contact(3, size: 1.1)]))
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.palms.isEmpty)
    }

    /// The false positive this exists to stop: a palm turning two fingers into
    /// the three-finger gesture.
    func testPalmIsNotCountedAsAFinger() {
        var filter = PalmFilter()
        let result = filter.apply(to: frame([contact(1, size: 1.0),
                                             contact(2, size: 1.1),
                                             contact(3, size: 5.0)]))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.palms.map(\.id), [3])
    }

    /// And the false negative: a palm turning the three-finger gesture into a
    /// four-finger swipe.
    func testPalmDoesNotInflateTheCountPastTheGesture() {
        var filter = PalmFilter()
        let result = filter.apply(to: frame([contact(1, size: 0.9), contact(2, size: 1.0),
                                             contact(3, size: 1.1), contact(4, size: 4.5)]))
        XCTAssertEqual(result.count, 3)
    }

    func testOddOneOutIsRejectedBelowTheAbsoluteLimit() {
        var filter = PalmFilter()
        let result = filter.apply(to: frame([contact(1, size: 0.9),
                                             contact(2, size: 1.0),
                                             contact(3, size: 3.0)]))
        XCTAssertEqual(result.palms.map(\.id), [3])
    }

    /// Pressing one finger harder than the others must stay a gesture.
    func testFirmFingerAmongLightOnesIsNotAPalm() {
        var filter = PalmFilter()
        let result = filter.apply(to: frame([contact(1, size: 0.5),
                                             contact(2, size: 0.6),
                                             contact(3, size: 1.6)]))
        XCTAssertEqual(result.count, 3)
    }

    func testLonePalmIsRejectedOnAbsoluteSize() {
        var filter = PalmFilter()
        XCTAssertEqual(filter.apply(to: frame([contact(1, size: 5.0)])).count, 0)
    }

    func testEllipseWiderThanAnyFingertipIsAPalm() {
        var filter = PalmFilter()
        XCTAssertEqual(filter.apply(to: frame([contact(1, size: 2.0, axis: 25)])).count, 0)
    }

    /// Palms settle and change shape; one that flickered back to finger would
    /// re-arm gestures under a resting hand.
    func testPalmStaysAPalmUntilItLifts() {
        var filter = PalmFilter()
        _ = filter.apply(to: frame([contact(1, size: 5.0), contact(2, size: 1.0)]))
        XCTAssertEqual(filter.apply(to: frame([contact(1, size: 1.0),
                                               contact(2, size: 1.0)])).count, 1)

        // Lifting releases the id, which the trackpad will reuse.
        _ = filter.apply(to: frame([contact(2, size: 1.0)]))
        XCTAssertEqual(filter.apply(to: frame([contact(1, size: 1.0),
                                               contact(2, size: 1.0)])).count, 2)
    }

    func testDisabledFilterCountsEverything() {
        var filter = PalmFilter()
        filter.enabled = false
        let result = filter.apply(to: frame([contact(1, size: 9.0), contact(2, size: 1.0)]))
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.palms.isEmpty)
    }

    func testSizeLimitIsHonoured() {
        var filter = PalmFilter()
        filter.sizeLimit = 2.0
        XCTAssertEqual(filter.apply(to: frame([contact(1, size: 2.5)])).count, 0)
        filter = PalmFilter()
        filter.sizeLimit = 6.0
        XCTAssertEqual(filter.apply(to: frame([contact(1, size: 2.5)])).count, 1)
    }
}
