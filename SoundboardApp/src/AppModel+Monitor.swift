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

    /// Set the (smaller) monitor volume fader. Live to the engine; debounced save.
    func setMonitorVolume(_ value: Float) {
        monitorVolume = value
        mixEngine.setMonitorVolume(value)
        scheduleSave()
    }

    /// Start or stop the monitor to match `monitorEnabled` on the chosen device.
    func applyMonitor() {
        mixEngine.setMonitorEnabled(monitorEnabled, deviceUID: monitorOutputUID, volume: monitorVolume)
    }
}
