import SwiftUI
import AppKit

@main
struct SoundboardApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(model: model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            SoundMenu(model: model)
        } label: {
            Image(systemName: "speaker.wave.3.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Toggles the Dock icon based on whether a real window is open: the app shows in
/// the Dock while the mixer window is up, and hides (acting like a menu-bar agent)
/// once it's closed. The `MenuBarExtra` panel is an `NSPanel`, so it's ignored.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True until we've dealt with the window SwiftUI auto-opens at launch when the
    /// previous session ended with the window closed (we close it before it shows).
    private var suppressInitialWindow = false
    private var handledInitialWindow = false

    // A menu-bar agent: closing the window (including the suppressed launch window)
    // leaves the app running in the tray; it quits only via the tray's Quit / Cmd-Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        suppressInitialWindow = !AppModel.shouldOpenMainWindowAtLaunch()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowsChanged),
                           name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(windowsChanged),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        if suppressInitialWindow {
            // `didUpdate` fires while the window is still being set up — the earliest
            // hook to close it, before it composites on screen.
            center.addObserver(self, selector: #selector(suppressWindowIfNeeded),
                               name: NSWindow.didUpdateNotification, object: nil)
            suppressWindowIfNeeded()
        }
        updatePolicy()
    }

    /// Close the auto-opened launch window once (the previous session was closed).
    @objc private func suppressWindowIfNeeded() {
        guard suppressInitialWindow, !handledInitialWindow, let win = mainWindow else { return }
        handledInitialWindow = true
        suppressInitialWindow = false
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        win.close()
        updatePolicy()
    }

    // Re-evaluate after the run loop settles so closing/opening windows is reflected.
    @objc private func windowsChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updatePolicy() }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
    }

    private func updatePolicy() {
        let hasWindow = NSApp.windows.contains { win in
            win.isVisible && win.canBecomeMain && !(win is NSPanel)
        }
        NSApp.setActivationPolicy(hasWindow ? .regular : .accessory)
    }
}

/// Top-level UI: a single mixer page under a thin toolbar strip.
struct RootView: View {
    @Bindable var model: AppModel
    /// Local key monitor so Esc cancels a MIDI-learn regardless of which control
    /// holds focus (a window-level `.onExitCommand` only fires for the focused view).
    @State private var escMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(model: model)
            Divider()
            MixerPage(model: model)
        }
        .frame(minWidth: 560, minHeight: 440)
        .onAppear {
            model.windowBecameVisible()
            installEscMonitor()
        }
        .onDisappear {
            model.windowBecameHidden()
            if let monitor = escMonitor { NSEvent.removeMonitor(monitor); escMonitor = nil }
        }
    }

    /// Esc (keyCode 53) cancels an in-progress learn ("Listening…") without touching
    /// the line's current assignment — `cancelLearning()` only clears the pending
    /// line. The event is consumed only when a learn was actually cancelled.
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, model.learningLine != nil else { return event }
            model.cancelLearning()
            return nil
        }
    }
}

/// The toolbar-like strip at the top of the window: the VU (audio levels) toggle
/// and the sticky Assign button that flips the mixer into MIDI-learn mode.
struct Toolbar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $model.showLevels) {
                Label("VU", systemImage: "waveform")
            }
            .toggleStyle(.button)
            .help("Show live audio-level meters beside each fader.")

            Button {
                model.assigning.toggle()
            } label: {
                Label("Assign", systemImage: "pianokeys")
            }
            .buttonStyle(.borderedProminent)
            .tint(model.assigning ? .red : .accentColor)
            .help(model.assigning
                  ? "Assigning MIDI — controls don't affect audio. Double-click a label above a control to learn it."
                  : "Assign MIDI controls to faders and buttons.")

            Spacer()

            // The live MIDI read-out is only useful while assigning; on the main
            // page it's just clutter, so it's shown only in assign mode.
            if model.assigning {
                Label(model.lastEvent, systemImage: "dot.radiowaves.left.and.right")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .help("Most recent MIDI message (from any connected device).")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// The menu-bar (tray) panel — a near-copy of the macOS Sound menu: a "Sound"
/// title, a volume slider (with a mute-toggling speaker on the left), then the
/// "Output" device list with a checkmark on the current listening device.
struct SoundMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    static let appVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    static let appBuild: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

    var body: some View {

        VStack(alignment: .leading, spacing: 6) {
            Text("Sound").fontWeight(.medium)

            // Mac (system-audio tap) — pick which output device's audio to mix, set its level.
            Divider()
            Text("Mac").fontWeight(.medium)
            FaderRow(systemImage: "desktopcomputer",
                     value: Binding(get: { model.macLevel.rawValue }, set: { model.macLevel.rawValue = $0 }))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.availableOutputs) { device in
                    DeviceRow(name: device.name, selected: device.uid == model.macSourceUID) {
                        model.setMacSource(device.uid)
                    }
                }
            }

            // Mic — "None" releases the mic; a device selects it. Fader sets its level.
            Divider()
            Text("Mic").fontWeight(.medium)
            FaderRow(systemImage: "mic.fill",
                     value: Binding(get: { model.micLevel.rawValue }, set: { model.micLevel.rawValue = $0 }),
                     enabled: model.selectedMonitorMicUID != nil)
            VStack(alignment: .leading, spacing: 0) {
                DeviceRow(name: "None", selected: model.selectedMonitorMicUID == nil) {
                    model.selectMonitorMic(nil)
                }
                ForEach(model.availableInputs) { device in
                    DeviceRow(name: device.name, selected: device.uid == model.selectedMonitorMicUID) {
                        model.selectMonitorMic(device.uid)
                    }
                }
            }

            // Monitor — play the mix to an output device. "None" stops monitoring.
            Divider()
            Text("Monitor").fontWeight(.medium)
            FaderRow(systemImage: "headphones",
                     value: Binding(get: { model.monitorVolume }, set: { model.setMonitorVolume($0) }),
                     enabled: model.monitorEnabled)
            VStack(alignment: .leading, spacing: 0) {
                DeviceRow(name: "None", selected: !model.monitorEnabled) {
                    model.selectMonitorOutput(nil)
                }
                ForEach(model.availableOutputs) { device in
                    DeviceRow(
                        name: device.name,
                        selected: model.monitorEnabled && device.uid == model.monitorOutputUID
                    ) {
                        model.selectMonitorOutput(device.uid)
                    }
                }
            }

            Divider()
            Text("Version: \(Self.appVersion)  (\(Self.appBuild))")
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 0) {
                MenuRow(title: "Open Soundboard…") {
                    dismissTray()
                    showMainWindow()
                }
                MenuRow(title: "Sound Settings…") {
                    dismissTray()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                MenuRow(title: "Open Audio MIDI Setup…") {
                    dismissTray()
                    if let url = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: "com.apple.audio.AudioMIDISetup"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Divider()
            MenuRow(title: "Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(.all)
    }

    /// The app's real (non-panel) window, if one is currently open.
    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// The `NSStatusItem` backing our `MenuBarExtra`. SwiftUI keeps it private, so
    /// we reach it through its (private) `NSStatusBarWindow` via KVC.
    private var trayStatusItem: NSStatusItem? {
        NSApp.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .compactMap { $0.value(forKey: "statusItem") as? NSStatusItem }
            .first
    }

    /// Dismiss the MenuBarExtra panel. SwiftUI exposes no API to close a
    /// window-style `MenuBarExtra` programmatically (Apple FB10185203), and
    /// closing the panel directly leaves the icon highlighted and its open/closed
    /// state stale. Instead we toggle the status-item button — exactly what
    /// clicking the menu-bar icon does — so MenuBarExtra runs its own teardown and
    /// the icon un-highlights. Selecting a device/mic deliberately doesn't call
    /// this, so the menu stays open there.
    private func dismissTray() {
        guard let button = trayStatusItem?.button, button.state != .off else { return }
        button.performClick(button)
        button.isHighlighted = button.state != .off
    }

    /// Bring the mixer window to the front, creating it only if it isn't already
    /// open. Either way the app is activated and the window ordered front, so it
    /// never gets stuck behind other apps (e.g. when reopened from the tray after
    /// being closed without ever taking focus).
    private func showMainWindow() {
        // Become a regular app first so activation/ordering actually takes effect.
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            openWindow(id: "main")
        }
        bringMainWindowFront(attempt: 0)
    }

    /// SwiftUI creates the `NSWindow` asynchronously, so retry across runloop ticks
    /// until it exists, then force it frontmost.
    private func bringMainWindowFront(attempt: Int) {
        if let win = mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        } else if attempt < 20 {
            DispatchQueue.main.async { bringMainWindowFront(attempt: attempt + 1) }
        }
    }
}

/// A grey section caption ("Output"), matching the macOS Sound menu.
private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }
}

/// A horizontal volume fader for a tray section: a leading section icon and a
/// native slider, dimmed when the section is inactive (no mic / not monitoring).
private struct FaderRow: View {
    let systemImage: String
    @Binding var value: Float
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: Binding(get: { Double(value) }, set: { value = Float($0) }), in: 0...1)
                .scrollAdjust($value, axis: .horizontal)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// A selectable output-device row: a leading checkmark when it's the current one.
private struct DeviceRow: View {
    let name: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 14)
                Text(name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Color.gray.opacity(0.38) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A plain footer action row (Open / Quit), styled like the device rows.
private struct MenuRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .padding(.vertical, 8).padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Color.gray.opacity(0.38) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
