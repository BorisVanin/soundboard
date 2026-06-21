import Foundation

@MainActor
extension AppModel {

    // MARK: - Monitor (play the mix to an output device)

    /// Toggle monitoring from the UI (drives the same assignable control as MIDI).
    func toggleMonitor() { monitorControl.press() }

    /// Pick which output device the mix is monitored on (config popover).
    func setMonitorOutput(_ uid: String) {
        guard uid != monitorOutputUID else { return }
        monitorOutputUID = uid
        applyMonitor()
        saveNow()
    }

    /// Tray: choose the monitor output (turning monitoring on), or `nil` to stop —
    /// mirroring the "None" rows used for the mic. Keeps the Monitor button in sync.
    func selectMonitorOutput(_ uid: String?) {
        if let uid { monitorOutputUID = uid; monitorEnabled = true } else { monitorEnabled = false }
        monitorControl?.setSilently(on: monitorEnabled)
        applyMonitor()
        saveNow()
    }

    /// Set the monitor volume. Routes through the monitor fader line so the lane fader,
    /// the tray, and persistence stay in sync (its onAction updates the engine + save).
    func setMonitorVolume(_ value: Float) { monitorLevel.rawValue = value }

    /// Start or stop the monitor to match `monitorEnabled` on the chosen device, at the
    /// mute-adjusted volume.
    func applyMonitor() {
        let volume = monitorMute.isOn ? 0 : monitorVolume
        mixEngine.setMonitorEnabled(monitorEnabled, deviceUID: monitorOutputUID, volume: volume)
    }
}
