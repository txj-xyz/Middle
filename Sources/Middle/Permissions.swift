import AppKit
import ApplicationServices
import CoreGraphics

/// The two TCC grants this app needs.
///
/// Accessibility lets us create an event tap and post synthetic mouse events;
/// Input Monitoring covers reading the raw HID stream the trackpad produces.
enum Permissions {

    static var accessibility: Bool {
        AXIsProcessTrusted()
    }

    static var inputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    static var allGranted: Bool {
        accessibility && inputMonitoring
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
