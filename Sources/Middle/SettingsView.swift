import AppKit
import Combine
import SwiftUI

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

    var body: some View {
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
                Text(monitor.frame.count == 0
                     ? "No fingers on the trackpad."
                     : "\(monitor.frame.count) finger\(monitor.frame.count == 1 ? "" : "s") detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Reset to Defaults") { prefs.resetToDefaults() }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
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

                ForEach(frame.fingers, id: \.id) { finger in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 16, height: 16)
                        .offset(x: finger.position.x * geo.size.width - 8,
                                y: (1 - finger.position.y) * geo.size.height - 8)
                }
            }
        }
    }
}
