import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Polls the gesture engine so the settings window can show live contacts.
/// Handy for tuning the click zone, and it doubles as a sanity check that the
/// private multitouch API is still reporting what we think it is.
final class TouchMonitor: ObservableObject {
    @Published var frame = TouchFrame.empty
    private weak var engine: GestureEngine?
    private var timer: Timer?

    init(engine: GestureEngine?) {
        self.engine = engine
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            self.frame = engine.snapshot
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var monitor: TouchMonitor
    let systemGestures: SystemGestureCoordinator

    @State private var selectedIgnored = Set<String>()

    var body: some View {
        ScrollView {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable middle click", isOn: $prefs.enabled)
                .toggleStyle(.switch)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Picker("Gesture", selection: $prefs.gesture) {
                    ForEach(GestureKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(prefs.gesture.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if prefs.gesture != .bottomZoneClick {
                Picker("Fingers", selection: $prefs.fingerCount) {
                    Text("3").tag(3)
                    Text("4").tag(4)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            Divider()

            Group {
                if prefs.gesture == .multiFingerTap {
                    slider("Tap must finish within", value: $prefs.tapTimeout,
                           range: 0.1...0.6, format: "%.2f s")
                    slider("Hold to start dragging after", value: $prefs.holdDelay,
                           range: 0.05...0.5, format: "%.2f s")
                    slider("Movement tolerance", value: $prefs.tapSlop,
                           range: 0.01...0.2, format: "%.2f")
                }
                if prefs.gesture.usesSyntheticMotion {
                    slider("Drag speed", value: $prefs.pointerSpeed,
                           range: 400...4000, format: "%.0f px")
                }
                if prefs.gesture == .bottomZoneClick {
                    slider("Zone left edge", value: $prefs.zoneXMin, range: 0...0.5, format: "%.2f")
                    slider("Zone right edge", value: $prefs.zoneXMax, range: 0.5...1, format: "%.2f")
                    slider("Zone height", value: $prefs.zoneYMax, range: 0.05...0.5, format: "%.2f")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle(relocateLabel, isOn: $prefs.handlesGestureConflicts)
                    .disabled(prefs.gesture == .bottomZoneClick)
                Text(conflictExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            palmRejection

            Divider()

            ignoredApps

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Trackpad")
                    .font(.headline)
                TrackpadView(frame: monitor.frame,
                             zone: prefs.gesture == .bottomZoneClick
                                ? CGRect(x: prefs.zoneXMin, y: 0,
                                         width: max(0, prefs.zoneXMax - prefs.zoneXMin),
                                         height: prefs.zoneYMax)
                                : nil)
                    .frame(height: 130)
                Text(trackpadCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Reset to Defaults") { prefs.resetToDefaults() }
                    .help("Restores every setting, including the list of ignored apps.")
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    /// Palm rejection. The live trackpad view below doubles as the calibration
    /// aid for the size limit, which is why the two sit next to each other.
    private var palmRejection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Ignore palms and resting hands", isOn: $prefs.palmRejection)
            Text("Every gesture is a count of fingers, so one palm resting on the pad breaks it "
                 + "either way. Contacts too big to be a fingertip are left out of the count.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if prefs.palmRejection {
                slider("Palm size limit", value: $prefs.palmSizeLimit,
                       range: 1.5...8, format: "%.1f")
                Text(sizeReadout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Toggle("Ignore gestures just after typing", isOn: $prefs.ignoreAfterTyping)
                .padding(.top, 4)
            if prefs.ignoreAfterTyping {
                slider("Wait after a keystroke", value: $prefs.typingDelay,
                       range: 0.1...1.0, format: "%.2f s")
            }
        }
    }

    /// What the trackpad is reporting right now, so the limit above can be set
    /// by resting a palm on the pad and reading the number.
    private var sizeReadout: String {
        let frame = monitor.frame
        guard !frame.contacts.isEmpty else {
            return "Rest a palm on the trackpad to see what it measures."
        }
        return String(format: "Largest contact now: %.1f  ·  %d finger(s), %d ignored",
                      frame.largestSize, frame.count, frame.palms.count)
    }

    /// Apps Middle leaves alone. Useful for anything that already does
    /// something of its own with three or four fingers.
    private var ignoredApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ignore these apps")
                .font(.headline)
            Text("Middle stands down while one of these is in front, and the trackpad behaves "
                 + "as if it were not running.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selectedIgnored) {
                ForEach(prefs.ignoredApps) { app in
                    HStack(spacing: 6) {
                        Image(nsImage: icon(for: app))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(app.name)
                    }
                    .tag(app.bundleID)
                }
            }
            .frame(height: 110)
            .overlay {
                if prefs.ignoredApps.isEmpty {
                    Text("No ignored apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Menu("Add…") {
                    ForEach(runningApps, id: \.bundleID) { app in
                        Button(app.name) { prefs.ignore(app) }
                    }
                    Divider()
                    Button("Choose from Applications…") { chooseApps() }
                }
                .frame(width: 100)

                Button("Remove") {
                    prefs.stopIgnoring(bundleIDs: selectedIgnored)
                    selectedIgnored.removeAll()
                }
                .disabled(selectedIgnored.isEmpty)
            }
        }
    }

    /// Running apps with a UI, minus the ones already listed and Middle itself.
    private var runningApps: [IgnoredApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !prefs.isIgnored(bundleID) else { return nil }
                return IgnoredApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func icon(for app: IgnoredApp) -> NSImage {
        guard let url = app.url else {
            return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// For apps that are installed but not running, which the list above cannot
    /// offer.
    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            prefs.ignore(IgnoredApp(bundleID: bundleID, name: name))
        }
    }

    private var trackpadCaption: String {
        let frame = monitor.frame
        if frame.contacts.isEmpty { return "No fingers on the trackpad." }
        let fingers = "\(frame.count) finger\(frame.count == 1 ? "" : "s") detected"
        guard !frame.palms.isEmpty else { return fingers + "." }
        return fingers + ", \(frame.palms.count) ignored as a palm."
    }

    private var relocateLabel: String {
        let other = prefs.fingerCount == 4 ? "three" : "four"
        return "Move Mission Control and app switching to \(other) fingers"
    }

    private var conflictExplanation: String {
        guard prefs.gesture != .bottomZoneClick else {
            return "This gesture does not collide with anything macOS uses, so nothing needs suspending."
        }
        let ours = prefs.fingerCount == 4 ? "Four" : "Three"
        let other = prefs.fingerCount == 4 ? "three" : "four"
        return "\(ours)-finger swipes become Middle's while it runs, and Mission Control and full-screen "
            + "app switching move to \(other) fingers. Everything is restored when Middle quits. A gesture "
            + "you already had switched off stays off."
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(label)
                .frame(width: 170, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 58, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

/// Top-down view of the trackpad surface with live contacts.
struct TrackpadView: View {
    let frame: TouchFrame
    let zone: CGRect?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .underPageBackgroundColor))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.4))

                if let zone {
                    // Trackpad y grows upwards, the view's grows downwards.
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: zone.width * geo.size.width,
                               height: zone.height * geo.size.height)
                        .offset(x: zone.minX * geo.size.width,
                                y: (1 - zone.height) * geo.size.height)
                }

                // Contacts are drawn at the size the trackpad reports, so a
                // palm looks like one, and rejected contacts are hollow.
                ForEach(frame.fingers, id: \.id) { finger in
                    contact(finger, in: geo.size, palm: false)
                }
                ForEach(frame.palms, id: \.id) { palm in
                    contact(palm, in: geo.size, palm: true)
                }
            }
        }
    }

    private func contact(_ finger: Finger, in size: CGSize, palm: Bool) -> some View {
        let diameter = 14 + CGFloat(min(finger.size, 6)) * 4
        return Circle()
            .strokeBorder(Color.secondary, lineWidth: palm ? 1.5 : 0)
            .background(Circle().fill(palm ? Color.secondary.opacity(0.15) : Color.accentColor))
            .frame(width: diameter, height: diameter)
            .offset(x: finger.position.x * size.width - diameter / 2,
                    y: (1 - finger.position.y) * size.height - diameter / 2)
    }
}
