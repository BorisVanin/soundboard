import Foundation
import CoreAudio
import MixerEngine

@MainActor
extension AppModel {

    // MARK: - Managed multi-output (monitoring plumbing)

    /// Plan A captures system audio with a process tap (the Mac lane), not an output
    /// mirror — so the app no longer creates a Multi-Output Device. Tear down any
    /// stale one left by older builds and restore a real default output device so the
    /// user keeps hearing audio.
    func cleanupLegacyMultiOutput() {
        guard let agg = AudioDevices.deviceID(forUID: Self.multiOutputUID) else { return }
        if AudioDevices.defaultOutputDeviceUID() == Self.multiOutputUID,
           let real = macSourceUID ?? availableOutputs.first?.uid,
           let dev = AudioDevices.deviceID(forUID: real) {
            AudioDevices.setDefaultOutputDevice(dev)
        }
        AudioDevices.destroyAggregate(agg)
    }

    /// Pick the system output device for the Mac lane. This now *sets the macOS default
    /// output* to `uid` (where your Mac audio plays): choose "Soundboard System" to route
    /// system audio through Soundboard. The Mac fader/mute then control that device's
    /// volume (driver-applied for "Soundboard System").
    func setMacSource(_ uid: String) {
        guard uid != Self.multiOutputUID, uid != loopbackUID else { return }
        macSourceUID = uid
        if let dev = AudioDevices.deviceID(forUID: uid) { AudioDevices.setDefaultOutputDevice(dev) }
        reconfigureMonitor()
        saveNow()
    }

    /// Whether the selected Mac (system output) device exposes a software volume control.
    /// The Mac fader + mute are disabled when it doesn't.
    var macSupportsVolume: Bool {
        guard let uid = macSourceUID, let dev = AudioDevices.deviceID(forUID: uid) else { return false }
        return AudioDevices.hasSettableVolume(dev)
    }

    /// Output devices eligible for the Monitor lane — everything except the system-output
    /// capture device (monitoring into it would loop the mix back into the capture).
    var monitorOutputs: [AudioOutputDevice] {
        availableOutputs.filter { $0.uid != Self.systemOutputUID }
    }

    // MARK: - Source / device discovery

    func refreshOutputs() {
        let devices = AudioDevices.outputDevices().filter {
            $0.uid != Self.multiOutputUID && $0.uid != loopbackUID && $0.uid != Self.legacyMonitorUID
        }
        if devices != availableOutputs { availableOutputs = devices }
    }

    func refreshInputs() {
        let devices = AudioDevices.inputDevices().filter {
            $0.uid != loopbackUID && $0.uid != Self.multiOutputUID && $0.uid != Self.legacyMonitorUID
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if devices != availableInputs { availableInputs = devices }
        if let sel = selectedMonitorMicUID, !devices.contains(where: { $0.uid == sel }) {
            selectMonitorMic(nil)
        }
    }

    func channelCount(forMic uid: String) -> Int {
        guard let dev = AudioDevices.deviceID(forUID: uid) else { return 0 }
        return AudioDevices.inputChannelCount(of: dev)
    }
    var selectedMicChannelCount: Int { selectedMonitorMicUID.map { channelCount(forMic: $0) } ?? 0 }

    /// Pick which mic is rendered, or nil for "None". Keeps the mic On/Off line's
    /// shown state in sync without firing its action.
    func selectMonitorMic(_ uid: String?) {
        selectedMonitorMicUID = uid
        if let uid {
            lastMonitorMicUID = uid
            if monitorChannelSelections[uid] == nil {
                monitorChannelSelections[uid] = Set(0..<max(channelCount(forMic: uid), 0))
            }
        }
        micOnOff?.setSilently(on: uid != nil)
        reconfigureMonitor()
        saveNow()
    }

    func isChannelEnabled(_ index: Int) -> Bool {
        guard let uid = selectedMonitorMicUID else { return false }
        return monitorChannelSelections[uid]?.contains(index) ?? false
    }
    func setChannel(_ index: Int, enabled: Bool) {
        guard let uid = selectedMonitorMicUID else { return }
        var set = monitorChannelSelections[uid] ?? []
        if enabled { set.insert(index) } else { set.remove(index) }
        monitorChannelSelections[uid] = set
        reconfigureMonitor()
        saveNow()
    }

    func reconfigureMonitor() {
        // Mic lane → mix ring; the Mac (system-tap) lane lives alongside the board.
        let chans = selectedMonitorMicUID.flatMap { monitorChannelSelections[$0] }.map(Array.init) ?? []
        mixEngine.configure(micUID: selectedMonitorMicUID, channels: chans)
        mixEngine.setMicGain(micLevel.rawValue, muted: micMute.isOn)
        // The Mac lane taps the chosen output device's audio (read-only), independent
        // of the mic — so its VU shows activity whether or not a mic is selected.
        mixEngine.setMacSource(macSourceUID)
        mixEngine.setMacGain(macLevel.rawValue, muted: macMute.isOn)
    }
}
