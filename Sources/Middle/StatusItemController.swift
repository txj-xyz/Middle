import AppKit
import ServiceManagement

/// The menu bar item: on/off, gesture choice, permissions, settings.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let prefs = Preferences.shared
    private var isEngaged = false

    var onOpenSettings: (() -> Void)?
    var statusMessage: String?
    /// Name of the app Middle is currently standing down in, if any.
    var pausedIn: String?
    /// The app in front, so the menu can offer to ignore it. Middle itself is
    /// frontmost while the menu is open, hence asking rather than looking.
    var frontmostApp: (() -> FrontmostAppMonitor.App?)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    func setEngaged(_ engaged: Bool) {
        isEngaged = engaged
        updateIcon()
    }

    func refresh() {
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let live = prefs.enabled && statusMessage == nil && pausedIn == nil
        button.image = MiddleIcon.statusBarImage(engaged: isEngaged && live)
        button.appearsDisabled = !live
        button.toolTip = tooltip
    }

    private var tooltip: String {
        if let statusMessage { return statusMessage }
        guard prefs.enabled else { return "Middle (off)" }
        if let pausedIn { return "Middle is ignoring \(pausedIn)" }
        return "Middle click: \(prefs.gesture.title)"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let statusMessage {
            let item = NSMenuItem(title: statusMessage, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            if !Permissions.allGranted {
                menu.addItem(action("Open Privacy & Security…", #selector(openPermissions)))
            }
            menu.addItem(.separator())
        }

        let toggle = action(prefs.enabled ? "Middle Click: On" : "Middle Click: Off", #selector(toggleEnabled))
        toggle.state = prefs.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        let gestureItem = NSMenuItem(title: "Gesture", action: nil, keyEquivalent: "")
        let gestureMenu = NSMenu()
        for kind in GestureKind.allCases {
            let item = action(kind.title, #selector(selectGesture(_:)))
            item.representedObject = kind.rawValue
            item.state = prefs.gesture == kind ? .on : .off
            item.toolTip = kind.detail
            gestureMenu.addItem(item)
        }
        gestureItem.submenu = gestureMenu
        menu.addItem(gestureItem)

        if prefs.gesture != .bottomZoneClick {
            let countItem = NSMenuItem(title: "Fingers", action: nil, keyEquivalent: "")
            let countMenu = NSMenu()
            for count in 3...4 {
                let item = action("\(count) fingers", #selector(selectFingerCount(_:)))
                item.tag = count
                item.state = prefs.fingerCount == count ? .on : .off
                countMenu.addItem(item)
            }
            countItem.submenu = countMenu
            menu.addItem(countItem)
        }

        menu.addItem(ignoredAppsItem())

        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))

        let login = action("Open at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("Quit Middle", #selector(quit), key: "q"))
    }

    /// "Ignored Apps": a one-click toggle for whatever is in front, and the
    /// current list with a tick each, so removing is one click too.
    private func ignoredAppsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Ignored Apps", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if let front = frontmostApp?() {
            let ignored = prefs.isIgnored(front.bundleID)
            let toggle = action(ignored ? "Stop Ignoring \(front.name)" : "Ignore \(front.name)",
                                #selector(toggleFrontmostIgnored))
            toggle.state = ignored ? .on : .off
            submenu.addItem(toggle)
            submenu.addItem(.separator())
        }

        if prefs.ignoredApps.isEmpty {
            let empty = NSMenuItem(title: "No ignored apps", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for app in prefs.ignoredApps {
                let entry = action(app.name, #selector(removeIgnoredApp(_:)))
                entry.representedObject = app.bundleID
                entry.state = .on
                entry.toolTip = "Middle stands down while \(app.name) is in front. Click to remove."
                submenu.addItem(entry)
            }
        }

        item.submenu = submenu
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleEnabled() {
        prefs.enabled.toggle()
        updateIcon()
    }

    @objc private func selectGesture(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = GestureKind(rawValue: raw) else { return }
        prefs.gesture = kind
        updateIcon()
    }

    @objc private func selectFingerCount(_ sender: NSMenuItem) {
        prefs.fingerCount = sender.tag
    }

    @objc private func toggleFrontmostIgnored() {
        guard let front = frontmostApp?() else { return }
        if prefs.isIgnored(front.bundleID) {
            prefs.stopIgnoring(bundleIDs: [front.bundleID])
        } else {
            prefs.ignore(IgnoredApp(bundleID: front.bundleID, name: front.name))
        }
    }

    @objc private func removeIgnoredApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        prefs.stopIgnoring(bundleIDs: [bundleID])
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openPermissions() {
        if !Permissions.accessibility {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        } else {
            Permissions.requestInputMonitoring()
            Permissions.openInputMonitoringSettings()
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Middle: could not change login item: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
