import SwiftUI
import AppKit

/// Two equal panes (mic | output+loopback) over a media-transport row. Every
/// fader/mute/transport control is driven by a `MIDIFader`/`MIDIButton`;
/// the View only reads/writes the line and never touches audio directly.
struct MixerPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                MicLane(model: model)
                Divider()
                MacLane(model: model)
            }
            Divider()
            mediaRow
        }
        .padding(16)
    }

    // MARK: Media transport

    private var mediaRow: some View {
        ZStack {
            // Transport, centered.
            HStack(spacing: 24) {
                MediaButton(model: model, line: model.mediaPrev, systemImage: "backward.fill", help: "Previous")
                MediaButton(model: model, line: model.mediaPlayPause,
                            systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                            help: "Play / Pause")
                MediaButton(model: model, line: model.mediaNext, systemImage: "forward.fill", help: "Next")
            }
            // Rec pinned to the left edge, Monitor to the right edge.
            HStack {
                RecordButton(model: model)
                Spacer()
                MonitorButton(model: model)
            }
        }
    }
}

// MARK: - Monitor button (transport row, far right)

/// Toggle playback of the mix to a chosen output device, so the operator hears
/// what Soundboard is sending. Left-click starts/stops; right-click opens a small
/// config popover (output device + a compact volume fader) anchored above it.
/// Assignable like any other control.
private struct MonitorButton: View {
    @Bindable var model: AppModel
    @State private var showConfig = false

    var body: some View {
        let on = model.monitorEnabled
        Button { model.toggleMonitor() } label: {
            Image(systemName: "headphones")
                .font(.title2)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .frame(width: 46, height: 30)
        }
        .buttonStyle(.bordered)
        .allowsHitTesting(!model.assigning)
        .overlay { if model.assigning { AssignLabel(model: model, line: model.monitorControl) } }
        .overlay { if !model.assigning { RightClickCatcher { showConfig = true } } }
        .popover(isPresented: $showConfig, arrowEdge: .bottom) { MonitorConfig(model: model) }
        .help(on ? "Monitoring the mix. Click to stop; right-click to configure."
                 : "Play the mix to an output device so you can hear it. Click to start; right-click to choose.")
    }
}

/// The slide-up config for the Monitor button: pick the output device and set a
/// compact volume fader (a third the height of the Mic/Mac faders).
private struct MonitorConfig: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Monitor").font(.caption.bold())
            Picker("Output", selection: Binding(
                get: { model.monitorOutputUID ?? "" },
                set: { if !$0.isEmpty { model.setMonitorOutput($0) } }
            )) {
                ForEach(model.availableOutputs) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()

            // Horizontal volume fader.
            let volume = Binding(get: { model.monitorVolume }, set: { model.setMonitorVolume($0) })
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(volume.wrappedValue) },
                                      set: { volume.wrappedValue = Float($0) }), in: 0...1)
                    .scrollAdjust(volume, axis: .horizontal)
                Text("\(Int(model.monitorVolume * 100))")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .frame(width: 240)
        .padding(14)
    }
}

// MARK: - Scroll-to-adjust (mouse wheel / trackpad over a fader)

extension View {
    /// Let the mouse wheel / trackpad move a 0…1 `value` while the pointer is over
    /// this view. `axis` is the scroll direction that drives it: `.vertical` for the
    /// upright faders, `.horizontal` for the horizontal tray sliders.
    func scrollAdjust(_ value: Binding<Float>, axis: Axis) -> some View {
        overlay(ScrollCatcher(axis: axis) { delta in
            value.wrappedValue = min(max(value.wrappedValue + delta, 0), 1)
        })
    }
}

/// Catches scroll-wheel events without stealing clicks/drags: `hitTest` claims the
/// point only while the current event is a scroll, so press-drag still reaches the
/// fader beneath. Reports a normalized 0…1 delta (sign follows the OS scroll model,
/// so "scroll up / right" increases regardless of the natural-scrolling setting).
struct ScrollCatcher: NSViewRepresentable {
    let axis: Axis
    let onScroll: (Float) -> Void
    func makeNSView(context: Context) -> NSView { CatcherView(axis: axis, onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? CatcherView)?.onScroll = onScroll }

    final class CatcherView: NSView {
        let axis: Axis
        var onScroll: (Float) -> Void
        init(axis: Axis, onScroll: @escaping (Float) -> Void) {
            self.axis = axis; self.onScroll = onScroll; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? self : nil
        }
        override func scrollWheel(with event: NSEvent) {
            // Vertical is inverted (scroll down raises the fader), per preference.
            let raw = axis == .vertical ? -event.scrollingDeltaY : event.scrollingDeltaX
            guard raw != 0 else { return }
            // Trackpad: smooth, scaled by the precise point delta. Mouse wheel: a fixed
            // step per notch (its raw delta varies wildly across devices).
            let delta: Float = event.hasPreciseScrollingDeltas ? Float(raw) * 0.0025
                                                               : (raw > 0 ? 0.04 : -0.04)
            onScroll(delta)
        }
    }
}

/// Catches a right-click without stealing left-clicks: `hitTest` claims the point
/// only while the current event is a right-mouse event, so left-clicks fall through
/// to the SwiftUI button beneath this overlay.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> NSView { CatcherView(action: action) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CatcherView: NSView {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func rightMouseDown(with event: NSEvent) { action() }
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return self
            default: return nil
            }
        }
    }
}

// MARK: - Record button (transport row, far left)

/// Start/stop recording of the selected output to a file. Sized to match the
/// media-transport buttons; a black circle that turns red while recording.
/// Assignable like any other control (its chip shows in assign mode).
private struct RecordButton: View {
    @Bindable var model: AppModel

    var body: some View {
        let recording = model.isRecording
        Button { model.toggleRecording() } label: {
            Image(systemName: "circle.fill")
                .font(.title2)
                .foregroundStyle(recording ? Color.red : Color.black)
                .frame(width: 46, height: 30)
        }
        .buttonStyle(.bordered)
        .allowsHitTesting(!model.assigning)
        .overlay { if model.assigning { AssignLabel(model: model, line: model.recordControl) } }
        .help(recording
              ? "Stop recording (saved to ~/Music/Soundboard)."
              : "Record the selected output to a file in ~/Music/Soundboard.")
    }
}

// MARK: - Volume strip (fader + mute, each driven by a control line)

struct VolumeStrip: View {
    var model: AppModel
    let title: String
    let systemImage: String
    let levelLine: MIDIFader
    let muteLine: MIDIButton
    var enabled: Bool = true
    /// Which meter on the model this strip shows. Passed as a key path (not the
    /// array value) so this view's body does NOT read the meter — only the leaf
    /// `MeterColumn` does, keeping 15 Hz meter ticks from re-rendering the strip.
    var meterKeyPath: KeyPath<AppModel, [Float]>? = nil

    var body: some View {
        let assigning = model.assigning
        let level = levelLine.rawValue          // read → observed → redraws on MIDI moves
        let muted = muteLine.isOn
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.caption2).foregroundStyle(.secondary)
            Text(title).font(.caption.bold())
            HStack(spacing: 3) {
                if let meterKeyPath { MeterColumn(model: model, keyPath: meterKeyPath) }
                VerticalFader(value: Binding(get: { levelLine.rawValue }, set: { levelLine.rawValue = $0 }))
                    .frame(height: 180)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.35)
            }
            .frame(height: 180)
            .allowsHitTesting(!assigning)
            .overlay { if assigning { AssignLabel(model: model, line: levelLine) } }
            Text("\(Int(level * 100))").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            MuteButton(isMuted: muted) { muteLine.isOn.toggle() }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
                .allowsHitTesting(!assigning)
                .overlay { if assigning { AssignLabel(model: model, line: muteLine) } }
        }
        .frame(width: 66)
        .help(enabled ? "" : "This device has no software volume control.")
    }
}

// MARK: - Media transport button

private struct MediaButton: View {
    var model: AppModel
    let line: MIDIButton
    let systemImage: String
    let help: String

    var body: some View {
        Button { line.press() } label: {
            Image(systemName: systemImage).font(.title2).frame(width: 46, height: 30)
        }
        .buttonStyle(.bordered)
        .allowsHitTesting(!model.assigning)
        .overlay { if model.assigning { AssignLabel(model: model, line: line) } }
        .help(help)
    }
}

// MARK: - Assign chip

/// Shown over a control in assign mode: the line's bound control ("CC 7" /
/// "Note 48"), or "Assign to" when unmapped. Double-click to (re)learn; right-click
/// to clear.
struct AssignLabel: View {
    var model: AppModel
    let line: any MIDIControl

    var body: some View {
        let learning = model.isLearning(line)
        let bound = model.assignmentLabel(for: line)
        Text(learning ? "Listening…" : (bound ?? "Assign to"))
            .font(.caption2.monospaced())
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(learning ? Color.orange : (bound == nil ? .secondary : .primary))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.background)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(learning ? Color.orange : Color.secondary.opacity(0.45)))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { learning ? model.cancelLearning() : model.startLearning(line) }
            .contextMenu {
                if bound != nil { Button("Clear assignment") { model.clearAssignment(line) } }
            }
            .help("Double-click to assign a MIDI control" + (bound.map { " (currently \($0))" } ?? ""))
    }
}

// MARK: - Meter column (isolated observer)

/// Reads the meter array itself — the *only* place that touches `model.<meter>`,
/// so a meter update invalidates just these 1–2 bars, not the whole mixer.
private struct MeterColumn: View {
    let model: AppModel
    let keyPath: KeyPath<AppModel, [Float]>
    var body: some View {
        let meter = model.showLevels ? model[keyPath: keyPath] : []
        HStack(spacing: 3) {
            if meter.count >= 1 { MeterBar(level: meter[0]) }
            if meter.count >= 2 { MeterBar(level: meter[1]) }
        }
    }
}

// MARK: - Meter bar

/// Segmented LED-style level meter. Far cheaper than a masked gradient: just
/// `segmentCount` solid rounded rects whose fill flips lit/dim. Combined with the
/// poller's segment-level dedup, it redraws only when a segment lights or darkens.
private struct MeterBar: View {
    let level: Float
    private static let count = AppModel.meterSegmentCount   // bottom → top
    private static let greenCount = count - 2               // then 1 yellow, 1 red (top)

    var body: some View {
        let lit = AppModel.litSegments(level)
        VStack(spacing: 2) {
            ForEach(0..<Self.count, id: \.self) { idx in
                let pos = Self.count - 1 - idx               // VStack is top→bottom
                let color = Self.color(at: pos)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(pos < lit ? color : color.opacity(0.16))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 6, height: 180)
    }

    private static func color(at pos: Int) -> Color {
        if pos >= count - 1 { return .red }
        if pos >= greenCount { return .yellow }
        return .green
    }
}

private struct MuteButton: View {
    let isMuted: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Mute", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 20)
        }
        .buttonStyle(.bordered)
        .tint(isMuted ? .red : .accentColor)
        .help(isMuted ? "Unmute" : "Mute")
    }
}

// MARK: - Vertical fader (custom, reliable hit area)

struct VerticalFader: View {
    @Binding var value: Float
    var knobSize: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let travel = max(h - knobSize, 1)
            let v = CGFloat(min(max(value, 0), 1))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 6)
                Capsule().fill(Color.accentColor).frame(width: 6, height: max(knobSize / 2, v * h))
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08)))
                    .shadow(radius: 1.5)
                    .frame(width: knobSize, height: knobSize)
                    .offset(y: -v * travel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let frac = 1 - (g.location.y / h)
                        value = Float(min(max(frac, 0), 1))
                    }
            )
        }
        .frame(width: 44)
        .scrollAdjust($value, axis: .vertical)
    }
}
