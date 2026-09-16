import Foundation

/// `Middle --diagnose` prints live trackpad contacts for a few seconds.
///
/// Useful for confirming the private multitouch API still reports sane data on
/// a new macOS release, and for checking that the trackpad is visible at all
/// before blaming the gesture logic.
enum Diagnose {
    static func run(seconds: Double = 8) -> Never {
        let reader = MultitouchReader()
        var frames = 0
        var maxFingers = 0
        var largest: Float = 0

        reader.onFrame = { frame in
            frames += 1
            maxFingers = max(maxFingers, frame.count)
            largest = max(largest, frame.largestSize)
            guard frame.count > 0 else { return }
            // size and axis are what the palm size limit in Settings compares
            // against, so print both: rest a palm and read the numbers.
            let described = frame.fingers
                .map { String(format: "#%d (%.2f, %.2f) size %.2f axis %.1fmm",
                              $0.id, $0.position.x, $0.position.y, $0.size, $0.majorAxis) }
                .joined(separator: "  ")
            print(String(format: "%2d finger(s): %@", frame.count, described))
        }

        do {
            try reader.start()
        } catch {
            print("Could not start: \(error.localizedDescription)")
            exit(1)
        }

        print("Reading trackpad for \(Int(seconds))s — move some fingers around.")
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        reader.stop()
        print(String(format: "\nSaw %d frames, up to %d simultaneous fingers, largest contact %.2f.",
                     frames, maxFingers, largest))
        if frames == 0 {
            print("No frames at all. Grant Input Monitoring to this terminal (or run the app bundle) and retry.")
            exit(1)
        }
        exit(0)
    }
}
