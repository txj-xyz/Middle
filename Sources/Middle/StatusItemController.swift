import AppKit
import ServiceManagement

/// The menu bar item: on/off, gesture choice, permissions, settings.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let prefs = Preferences.shared
    private var isEngaged = false

    var onOpenSettings: (() -> Void)?
    var statusMessage: String?

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
        let name: String
        if !prefs.enabled || statusMessage != nil {
            name = "computermouse"
        } else if isEngaged {
            name = "computermouse.fill"
        } else {
            name = "computermouse"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Middle")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !prefs.enabled || statusMessage != nil
        button.toolTip = statusMessage ?? (prefs.enabled ? "Middle click: \(prefs.gesture.title)" : "Middle (off)")
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

        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))

        let login = action("Open at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("Quit Middle", #selector(quit), key: "q"))
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
