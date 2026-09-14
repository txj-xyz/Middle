import AppKit
import CMultitouch
import Foundation
import QuartzCore

/// Reads raw finger contacts from every attached multitouch device.
///
/// MultitouchSupport is a private framework, so it is resolved lazily with
/// dlopen/dlsym: if a future macOS removes it, `start()` returns an error we can
/// show in the menu bar instead of failing to launch.
final class MultitouchReader {

    enum StartError: LocalizedError {
        case frameworkUnavailable
        case symbolsUnavailable
        case noDevices

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable:
                return "MultitouchSupport.framework could not be loaded on this system."
            case .symbolsUnavailable:
                return "MultitouchSupport.framework is missing the expected entry points."
            case .noDevices:
                return "No multitouch trackpad was found."
            }
        }
    }

    /// Called on a private multitouch thread, once per frame, whenever fingers
    /// are on the surface. Keep the work in here short.
    var onFrame: ((TouchFrame) -> Void)?

    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutablePointer<MTTouch>?, Int32, Double, Int32
    ) -> Int32
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    private typealias UnregisterFn = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias IsRunningFn = @convention(c) (UnsafeMutableRawPointer) -> Bool

    private var handle: UnsafeMutableRawPointer?
    private var createList: CreateListFn?
    private var register: RegisterFn?
    private var unregister: UnregisterFn?
    private var startDevice: StartFn?
    private var stopDevice: StopFn?
    private var isRunning: IsRunningFn?

    private var devices: [UnsafeMutableRawPointer] = []
    private var watchdog: Timer?
    private var didWarnAboutLayout = false

    /// The contact callback is a bare C function pointer with no context
    /// parameter we can trust, so the live reader is reachable through a global.
    static var shared: MultitouchReader?

    init() {
        MultitouchReader.shared = self
    }

    // MARK: - Lifecycle

    func start() throws {
        try loadFramework()
        attachDevices()
        guard !devices.isEmpty else { throw StartError.noDevices }
        scheduleWatchdog()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        detachDevices()
    }

    private func loadFramework() throws {
        guard handle == nil else { return }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let h = dlopen(path, RTLD_LAZY) else { throw StartError.frameworkUnavailable }
        handle = h

        func symbol<T>(_ name: String) -> T? {
            guard let sym = dlsym(h, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }
        createList = symbol("MTDeviceCreateList")
        register = symbol("MTRegisterContactFrameCallback")
        unregister = symbol("MTUnregisterContactFrameCallback")
        startDevice = symbol("MTDeviceStart")
        stopDevice = symbol("MTDeviceStop")
        isRunning = symbol("MTDeviceIsRunning")

        guard createList != nil, register != nil, startDevice != nil, stopDevice != nil else {
            throw StartError.symbolsUnavailable
        }
    }

    private func attachDevices() {
        guard let createList, let register, let startDevice else { return }
        guard let list = createList()?.takeRetainedValue() else { return }
        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, multitouchContactCallback)
            startDevice(device, 0)
            devices.append(device)
        }
    }

    private func detachDevices() {
        for device in devices {
            stopDevice?(device)
            unregister?(device, multitouchContactCallback)
        }
        devices.removeAll()
    }

    /// Trackpads stop feeding the callback after sleep, and an external Magic
    /// Trackpad can show up long after launch, so re-attach periodically.
    private func scheduleWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.reattachIfNeeded()
        }
    }

    @objc private func systemDidWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.restart()
        }
    }

    private func reattachIfNeeded() {
        guard let isRunning else { return }
        let stalled = devices.isEmpty || devices.contains { !isRunning($0) }
        if stalled { restart() }
    }

    func restart() {
        detachDevices()
        attachDevices()
    }

    // MARK: - Frame decoding

    fileprivate func deliver(touches: UnsafeMutablePointer<MTTouch>?, count: Int32) {
        var fingers: [Finger] = []
        fingers.reserveCapacity(Int(count))
        var suspect = false
        if let touches {
            for i in 0..<Int(count) {
                let t = touches[i]
                if t.state < 0 || t.state > 7 || !(-0.1...1.1).contains(Double(t.normalized.position.x)) {
                    suspect = true
                    continue
                }
                guard t.state == MT_STATE_MAKE_TOUCH || t.state == MT_STATE_TOUCHING
                    || t.state == MT_STATE_BREAK_TOUCH else { continue }
                fingers.append(Finger(
                    id: Int(t.identifier),
                    position: CGPoint(x: CGFloat(t.normalized.position.x),
                                      y: CGFloat(t.normalized.position.y)),
                    size: t.size))
            }
        }
        if suspect && !didWarnAboutLayout {
            didWarnAboutLayout = true
            NSLog("Middle: unexpected multitouch frame contents — the private MTTouch layout may have changed in this macOS release.")
        }
        onFrame?(TouchFrame(time: CACurrentMediaTime(), fingers: fingers))
    }
}

/// C entry point for MTRegisterContactFrameCallback.
private let multitouchContactCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutablePointer<MTTouch>?, Int32, Double, Int32
) -> Int32 = { _, touches, count, _, _ in
    MultitouchReader.shared?.deliver(touches: touches, count: count)
    return 0
}
