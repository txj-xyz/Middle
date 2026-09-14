import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = GestureEngine()
    private let reader = MultitouchReader()
    private lazy var eventTap = EventTapController(engine: engine)
    private lazy var statusItem = StatusItemController()
    private lazy var monitor = TouchMonitor(engine: engine)
    private let systemGestures = SystemGestureCoordinator()

    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hand back anything a crashed or force-quit run left borrowed before
        // we read the current values and borrow again.
        systemGestures.recoverFromPreviousRun()
        installSignalHandlers()

        engine.update(config: Preferences.shared.config)
        engine.onEngagementChange = { [weak self] engaged in
            self?.statusItem.setEngaged(engaged)
        }
        reader.onFrame = { [weak self] frame in
            self?.engine.handle(frame: frame)
        }

        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .preferencesChanged, object: nil)

        startServices()
        systemGestures.apply(for: Preferences.shared.config, prefs: Preferences.shared)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.forceRelease()
        eventTap.stop()
        reader.stop()
        systemGestures.restore(restartDock: Preferences.shared.restartDockOnChange)
    }

    /// A `kill` or a crash would otherwise leave the user's trackpad gestures
    /// switched off, so catch the signals we can and hand them back.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.systemGestures.restore(restartDock: false)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Services

    private func startServices() {
        guard Permissions.allGranted else {
            requestPermissions()
            return
        }
        do {
            try eventTap.start()
            try reader.start()
            statusItem.statusMessage = nil
        } catch {
            statusItem.statusMessage = error.localizedDescription
            NSLog("Middle: \(error.localizedDescription)")
            // A denied event tap is nearly always a missing grant that the user
            // is about to add, so keep checking rather than making them relaunch.
            scheduleRetry()
        }
        statusItem.refresh()
    }

    private func requestPermissions() {
        statusItem.statusMessage = "Waiting for Accessibility and Input Monitoring permission"
        statusItem.refresh()
        if !Permissions.accessibility { Permissions.requestAccessibility() }
        if !Permissions.inputMonitoring { Permissions.requestInputMonitoring() }
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return }
            guard Permissions.allGranted else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.startServices()
        }
    }

    @objc private func preferencesChanged() {
        engine.update(config: Preferences.shared.config)
        systemGestures.apply(for: Preferences.shared.config, prefs: Preferences.shared)
        statusItem.refresh()
    }

    // MARK: - Settings window

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(prefs: Preferences.shared, monitor: monitor,
                                    systemGestures: systemGestures)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Middle"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
