import AppKit

/// Watches which app the user is working in, so Middle can stand down in the
/// ones they have told it to ignore.
///
/// Middle itself is never reported: clicking the menu bar item or opening
/// Settings makes Middle frontmost, and "Ignore Safari" has to keep meaning the
/// app the user was actually in.
final class FrontmostAppMonitor {

    struct App: Equatable {
        var bundleID: String
        var name: String
    }

    /// The frontmost app, ignoring Middle itself. Read from the main thread.
    private(set) var frontmost: App?

    /// Called on the main thread whenever that changes.
    var onChange: ((App?) -> Void)?

    private var observer: NSObjectProtocol?
    private let ownBundleID = Bundle.main.bundleIdentifier

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.update(with: app)
        }
        update(with: NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    private func update(with running: NSRunningApplication?) {
        let bundleID = running?.bundleIdentifier
        guard bundleID != ownBundleID else { return }
        // Something without a bundle identifier cannot be on the list, so it
        // counts as "not ignored" rather than leaving the last app in place.
        let app = bundleID.map { App(bundleID: $0, name: running?.localizedName ?? $0) }
        guard app != frontmost else { return }
        frontmost = app
        onChange?(app)
    }
}
