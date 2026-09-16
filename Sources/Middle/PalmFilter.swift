import Foundation

/// Sorts trackpad contacts into fingertips and things that are not fingertips —
/// a palm, the heel of a hand, a forearm resting on the front edge.
///
/// This matters more here than it looks. Every gesture Middle recognises is
/// "exactly N fingers", so one stray contact breaks it in both directions: two
/// fingers plus a palm look like the three-finger tap the user did not make,
/// and three fingers plus a palm look like a four-finger swipe, so the tap they
/// did make is dropped.
///
/// The trackpad reports a size and an ellipse for every contact, and a palm is
/// simply much larger than a fingertip. Three rules, cheapest first:
///
/// 1. An ellipse wider than any fingertip could be — nothing else on a hand is
///    that broad.
/// 2. A contact over the size limit, which is the one number the user tunes.
/// 3. A contact far bigger than the others in the same frame. Absolute sizes
///    vary between trackpads and between people; "the odd one out" does not.
///    Only contacts already well above fingertip size qualify, so a firmly
///    pressed finger among three light ones is not mistaken for a palm.
///
/// A contact stays a palm until it lifts, as in libinput: palms change shape as
/// they settle, and a contact that flickers between palm and finger would keep
/// re-arming gestures underneath the hand that is resting on them.
struct PalmFilter {

    var enabled = true
    /// Contacts at or above this reported size are palms. Tuned in Settings
    /// against the live readout, because the units are the trackpad's own.
    var sizeLimit = 3.5

    /// Ellipse width, in millimetres, that no fingertip reaches.
    private static let impossibleMajorAxis = 22.0
    /// How much bigger than the rest of the frame counts as the odd one out.
    private static let oddOneOutRatio = 2.5
    /// …and the fraction of `sizeLimit` a contact must already exceed before
    /// that comparison is allowed to reject it.
    private static let oddOneOutFloor = 0.7

    /// Contacts already ruled palms, by contact id, for as long as they last.
    private var palmIDs: Set<Int> = []

    /// Splits `frame` into fingers and palms. Mutating, because the decision is
    /// sticky for the life of each contact.
    mutating func apply(to frame: TouchFrame) -> TouchFrame {
        // Contact ids are reused once a contact lifts, so forget them first.
        palmIDs.formIntersection(frame.fingers.map(\.id))

        guard enabled, !frame.fingers.isEmpty else { return frame }

        let sizes = frame.fingers.map { Double($0.size) }.sorted()
        let median = sizes[sizes.count / 2]

        var fingers: [Finger] = []
        var palms: [Finger] = []
        for contact in frame.fingers {
            if isPalm(contact, median: median, contacts: frame.fingers.count) {
                palmIDs.insert(contact.id)
            }
            if palmIDs.contains(contact.id) {
                palms.append(contact)
            } else {
                fingers.append(contact)
            }
        }
        return TouchFrame(time: frame.time, fingers: fingers, palms: palms)
    }

    private func isPalm(_ contact: Finger, median: Double, contacts: Int) -> Bool {
        if Double(contact.majorAxis) >= Self.impossibleMajorAxis { return true }
        let size = Double(contact.size)
        if size >= sizeLimit { return true }
        guard contacts > 1, median > 0, size >= sizeLimit * Self.oddOneOutFloor else { return false }
        return size > median * Self.oddOneOutRatio
    }
}
