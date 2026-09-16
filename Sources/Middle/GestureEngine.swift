import CoreGraphics
import Foundation
import QuartzCore

/// Turns trackpad contacts and raw mouse events into middle-button behaviour.
///
/// Two inputs arrive on two different threads — multitouch frames on the
/// framework's own thread, CGEvents on the event tap thread — so every entry
/// point takes the same recursive lock. It is recursive because posting an
/// event from inside a tap callback can re-enter the callback on the same
/// thread; the magic-stamp check in EventTapController normally catches that
/// first, but the lock makes the ordering safe either way.
final class GestureEngine {

    enum Motion {
        /// We move the pointer ourselves from finger motion, because macOS
        /// will not move it while several fingers are planted.
        case synthetic
        /// macOS is moving the pointer; we only rewrite its move events into
        /// middle-drags.
        case system
    }

    /// Rotate, begin/end gesture, gesture, magnify, swipe, smart magnify.
    /// CGEventType declares no constants for these, so they are raw values.
    static let gestureEventTypes: [UInt32] = [18, 19, 20, 29, 30, 31, 32]

    private let lock = NSRecursiveLock()
    private let button = MiddleButton()
    private var config = Config()
    private var palmFilter = PalmFilter()
    /// Set while the frontmost app is one the user has told Middle to ignore.
    private var suspended = false

    private var lastFrame = TouchFrame.empty
    private var latestFrame = TouchFrame.empty

    // Multi-finger tap candidate.
    private var candidateStart: CFTimeInterval?
    private var candidateOrigin: CGPoint = .zero
    private var candidateMoved: CGFloat = 0
    private var candidateAborted = false

    // Engagement.
    private(set) var isEngaged = false
    private var motion: Motion = .synthetic
    private var holdsPhysicalClick = false
    private var lastFrameTime: CFTimeInterval = 0

    private var watchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.joeyfinelli.middle.watchdog")

    /// Fires whenever the middle button engages or disengages, for the menu bar.
    var onEngagementChange: ((Bool) -> Void)?

    init() {
        startWatchdog()
    }

    // MARK: - Configuration

    func update(config newConfig: Config) {
        lock.lock()
        defer { lock.unlock() }
        config = newConfig
        palmFilter.enabled = newConfig.palmRejection
        palmFilter.sizeLimit = newConfig.palmSizeLimit
        if !isActive && isEngaged { disengage() }
    }

    /// Stand down — or start again — because the frontmost app changed. A
    /// gesture in flight is dropped, so switching into an ignored app mid-drag
    /// cannot leave the button held.
    func setSuspended(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard suspended != newValue else { return }
        suspended = newValue
        if suspended {
            disengage()
            resetCandidate()
        }
    }

    /// Whether the engine acts on input at all: switched on, and not standing
    /// down for the frontmost app.
    private var isActive: Bool {
        config.enabled && !suspended
    }

    var currentConfig: Config {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    /// Most recent trackpad frame, for the settings window's live view.
    var snapshot: TouchFrame {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame
    }

    // MARK: - Trackpad input

    func handle(frame raw: TouchFrame) {
        lock.lock()
        defer { lock.unlock() }

        // Everything below counts fingers, so palms come out of the frame
        // first — they stay in `palms` for the settings window to draw.
        let frame = palmFilter.apply(to: raw)
        latestFrame = frame
        lastFrameTime = frame.time
        defer { lastFrame = frame }

        guard isActive else {
            if isEngaged { disengage() }
            return
        }

        if isEngaged {
            if motion == .synthetic, let delta = frame.meanDelta(since: lastFrame) {
                button.move(byNormalized: delta, speed: config.pointerSpeed)
            }
            // A gesture held by a physical click ends on mouse-up, not on lift.
            if frame.count == 0 && !holdsPhysicalClick {
                disengage()
            }
            return
        }

        if config.gesture == .multiFingerTap {
            updateTapCandidate(frame)
        }
    }

    /// Tap gesture: N fingers resting on the pad.
    ///
    /// A quick lift is a middle click. Holding still past `holdDelay` presses
    /// and holds the button so the same gesture becomes a drag. Moving before
    /// either of those happens means the user is swiping — we bail out and let
    /// Mission Control have the gesture.
    private func updateTapCandidate(_ frame: TouchFrame) {
        let n = frame.count

        if n == config.fingerCount {
            guard let start = candidateStart else {
                // Arm only once the count has held for two consecutive frames.
                // Fingers never land together, so a four-finger gesture shows
                // up as a three-finger frame on the way down; waiting a frame
                // (~10ms) keeps us from claiming it.
                //
                // An aborted sequence stays aborted until every finger lifts,
                // otherwise lifting one finger from a four-finger swipe would
                // arm a three-finger candidate in the middle of that swipe.
                guard !candidateAborted, lastFrame.count == config.fingerCount else { return }
                // A hand that has just been typing is usually resting, not
                // gesturing. Fingers that land inside that window are aborted
                // rather than merely delayed, so a hand left on the pad stays
                // ignored until it lifts instead of arming the instant the
                // window expires. Only arming is guarded: a gesture already
                // under way is the user's, and a physical click is deliberate.
                guard !typingIsRecent else {
                    candidateAborted = true
                    return
                }
                candidateStart = frame.time
                candidateOrigin = frame.centroid
                candidateMoved = 0
                return
            }
            guard !candidateAborted else { return }
            let drift = hypot(frame.centroid.x - candidateOrigin.x,
                              frame.centroid.y - candidateOrigin.y)
            candidateMoved = max(candidateMoved, drift)
            if Double(candidateMoved) > config.tapSlop {
                candidateAborted = true
            } else if frame.time - start >= config.holdDelay {
                engage(motion: .synthetic)
                resetCandidate()
            }
        } else if n > config.fingerCount {
            candidateAborted = true
        } else if n == 0 {
            if let start = candidateStart, !candidateAborted,
               frame.time - start <= config.tapTimeout,
               Double(candidateMoved) <= config.tapSlop {
                button.click()
            }
            resetCandidate()
        }
        // 0 < n < fingerCount: fingers still landing or lifting, keep waiting.
    }

    private func resetCandidate() {
        candidateStart = nil
        candidateMoved = 0
        candidateAborted = false
    }

    // MARK: - Mouse input
    //
    // Returns the event to pass along, or nil to swallow it.

    func handle(event: CGEvent, type: CGEventType) -> CGEvent? {
        lock.lock()
        defer { lock.unlock() }

        // Pass everything through untouched while standing down, so an ignored
        // app sees exactly what it would with Middle not running.
        guard isActive else { return event }

        // Mission Control is recognised inside WindowServer, not from any
        // swipe event we could intercept — a diagnostic run saw type 29 and 30
        // in bulk but never a type 31. Withholding the gesture stream while one
        // of our gestures is in progress is the only interception point left;
        // it is scoped to the gesture so normal pinch and rotate keep working.
        if Self.gestureEventTypes.contains(type.rawValue) {
            if config.suppressSystemGestures && gestureIsActive {
                return nil
            }
            return event
        }

        switch type {
        case .leftMouseDown:
            return handleLeftDown(event)

        case .leftMouseUp:
            if holdsPhysicalClick {
                holdsPhysicalClick = false
                disengage()
                return nil
            }
            return event

        case .mouseMoved, .leftMouseDragged:
            guard isEngaged else { return event }
            switch motion {
            case .system:
                rewriteAsMiddleDrag(event)
                return event
            case .synthetic:
                // We are driving the pointer from finger motion; anything the
                // system also produces would fight with it.
                return nil
            }

        default:
            return event
        }
    }

    private func handleLeftDown(_ event: CGEvent) -> CGEvent? {
        guard !isEngaged else { return event }

        switch config.gesture {
        case .multiFingerClick:
            guard fingersAreFresh, latestFrame.count >= config.fingerCount else { break }
            holdsPhysicalClick = true
            engage(motion: .synthetic)
            return nil

        case .bottomZoneClick:
            guard fingersAreFresh, latestFrame.count == 1,
                  latestFrame.contains(fingerIn: config.zoneX, yBelow: config.zoneYMax) else { break }
            holdsPhysicalClick = true
            button.syncCursor(to: event.location)
            engage(motion: .system)
            return nil

        case .multiFingerTap:
            // A real click is not a tap.
            candidateAborted = true
        }
        return event
    }

    /// True only while a gesture of ours is genuinely in play.
    ///
    /// Fingers do not land at the same instant, so a four-finger swipe passes
    /// through a three-finger frame on its way down and briefly arms the
    /// candidate. That candidate is aborted as soon as the fourth finger
    /// arrives, and an aborted candidate must stop blocking immediately —
    /// otherwise we would swallow the whole swipe, since the candidate is not
    /// cleared until every finger lifts. The finger-count check is a stateless
    /// backstop for the frame in between.
    private var gestureIsActive: Bool {
        if isEngaged { return true }
        guard candidateStart != nil, !candidateAborted else { return false }
        return latestFrame.count <= config.fingerCount
    }

    /// Time since the last keystroke, from the system's own event timing —
    /// nothing about the key itself, and no keyboard tap of our own.
    private var typingIsRecent: Bool {
        guard config.typingGuard > 0 else { return false }
        let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return since < config.typingGuard
    }

    /// Frames only arrive while fingers are on the pad, so a stale frame means
    /// the trackpad is not in use (an external mouse, say).
    private var fingersAreFresh: Bool {
        CACurrentMediaTime() - lastFrameTime < 0.25
    }

    private func rewriteAsMiddleDrag(_ event: CGEvent) {
        button.syncCursor(to: event.location)
        event.type = .otherMouseDragged
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    }

    // MARK: - Engagement

    private func engage(motion newMotion: Motion) {
        guard !isEngaged else { return }
        motion = newMotion
        button.press()
        isEngaged = true
        notifyEngagement()
    }

    private func disengage() {
        guard isEngaged else { return }
        button.release()
        isEngaged = false
        holdsPhysicalClick = false
        resetCandidate()
        notifyEngagement()
    }

    func forceRelease() {
        lock.lock()
        defer { lock.unlock() }
        disengage()
    }

    private func notifyEngagement() {
        let engaged = isEngaged
        DispatchQueue.main.async { [weak self] in
            self?.onEngagementChange?(engaged)
        }
    }

    /// A middle button stuck down would be miserable to recover from, so if we
    /// are holding one with fingers on the pad and the frames stop arriving,
    /// let go.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.isEngaged, !self.holdsPhysicalClick else { return }
            if CACurrentMediaTime() - self.lastFrameTime > 0.6 {
                self.disengage()
            }
        }
        timer.resume()
        watchdog = timer
    }
}
