import Foundation
import AppKit
import MixerModel
import MIDISurface

@MainActor
extension AppModel {

    // MARK: - Remote control (soundboardctl via DistributedNotificationCenter)

    /// Observe one-way control commands from the `soundboardctl` CLI. App-side
    /// only — cannot affect coreaudiod. Commands arrive as the notification's
    /// string `object` (e.g. "mic:on", "gain:0.6", "status", "quit").
    func setupRemoteControl() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("ca.borisvanin.soundboard.cmd"),
            object: nil, queue: .main) { [weak self] note in
            let cmd = note.object as? String
            Task { @MainActor [weak self] in
                guard let self, let cmd else { return }
                self.handleRemoteCommand(cmd)
            }
        }
    }

    func handleRemoteCommand(_ cmd: String) {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "mic":
            let isOn = parts.count > 1 && parts[1] == "on"
            selectMonitorMic(isOn ? (lastMonitorMicUID ?? availableInputs.first?.uid) : nil)
            micOnOff.setSilently(on: selectedMonitorMicUID != nil)
        case "gain":
            if parts.count > 1, let value = Float(parts[1]) {
                micLevel.setSilently(value)
                mixEngine.setMicGain(value, muted: micMute.isOn)
            }
        case "status":
            midiLog.info("""
                remote status: mic=\(self.selectedMonitorMicUID ?? "off", privacy: .public) \
                gain=\(self.micLevel.rawValue) engineRunning=\(self.mixEngine.isRunning)
                """)
        case "quit":
            NSApplication.shared.terminate(nil)
        default:
            break
        }
    }

    // MARK: - MIDI input / routing

    func connectMIDI() {
        guard !midiConnected else { return }
        midi.onValue = { deviceID, controlID, value in
            // CoreMIDI thread → hop to main, then route (or learn).
            Task { @MainActor [weak self] in
                self?.handleMidi(MIDIKey(deviceID: deviceID, controlID: controlID), value: value)
            }
        }
        midi.start()
        midiConnected = true
    }

    func handleMidi(_ key: MIDIKey, value: Int32) {
        lastEvent = Self.describe(key, value)
        if let line = learningLine {           // assign this physical control to the line
            guard value > 0 else { return }    // wait for an actual press / move, not a release
            assign(line, to: key)
            learningLine = nil
            return
        }
        router.control(for: key)?.onMidiEvent(value)
    }

    // MARK: - MIDI-learn / assignment (per line, persisted via AssignmentStore)

    func startLearning(_ line: any MIDIControl) { learningLine = line }
    func cancelLearning() { learningLine = nil }
    func isLearning(_ line: any MIDIControl) -> Bool { learningLine === line }

    /// Bind a line to a (device, control), ensuring one control per key, and persist.
    func assign(_ line: any MIDIControl, to key: MIDIKey?) {
        if let key, let prev = router.control(for: key), prev !== line {
            let prevOld = prev.midiKey
            prev.assign(to: nil)
            router.rebind(prev, from: prevOld, to: nil)
        }
        let old = line.midiKey
        line.assign(to: key)
        router.rebind(line, from: old, to: key)
        persistAssignments()
    }
    func clearAssignment(_ line: any MIDIControl) { assign(line, to: nil) }

    /// The chip label for a line: its bound control, or nil when unmapped.
    func assignmentLabel(for line: any MIDIControl) -> String? {
        guard let key = line.midiKey else { return nil }
        if key.controlID & MIDISurface.noteFlag != 0 { return "Note \(key.controlID & 0x7F)" }
        return "CC \(key.controlID)"
    }

    func restoreAssignments() {
        let saved = Dictionary(store.load().map { ($0.lineID, $0) }, uniquingKeysWith: { saved, _ in saved })
        for line in lines {
            guard let assignment = saved[line.lineID],
                  let device = assignment.midiDeviceID,
                  let controlID = assignment.midiControlID else { continue }
            let key = MIDIKey(deviceID: device, controlID: controlID)
            line.assign(to: key)
            router.rebind(line, from: nil, to: key)
        }
    }
    func persistAssignments() {
        store.save(lines.map {
            LineAssignment(lineID: $0.lineID, midiDeviceID: $0.midiDeviceID, midiControlID: $0.midiControlID)
        })
    }

    // MARK: - Assign-mode snapshot (restore feedback movements on exit)

    func makeSnapshot() -> Snapshot {
        Snapshot(micLevel: micLevel.rawValue, macLevel: macLevel.rawValue,
                 micMute: micMute.isOn, macMute: macMute.isOn,
                 micOn: micOnOff.isOn, mic: selectedMonitorMicUID, lastMic: lastMonitorMicUID,
                 record: recordControl.isOn, monitor: monitorControl.isOn)
    }
    func restoreSnapshot() {
        guard let snapshot else { return }
        self.snapshot = nil
        micLevel.setSilently(snapshot.micLevel); macLevel.setSilently(snapshot.macLevel)
        micMute.setSilently(on: snapshot.micMute); macMute.setSilently(on: snapshot.macMute)
        micOnOff.setSilently(on: snapshot.micOn); recordControl.setSilently(on: snapshot.record)
        monitorControl.setSilently(on: snapshot.monitor)
        selectedMonitorMicUID = snapshot.mic; lastMonitorMicUID = snapshot.lastMic
    }

    static func describe(_ key: MIDIKey, _ value: Int32) -> String {
        if key.controlID & MIDISurface.noteFlag != 0 { return "Note \(key.controlID & 0x7F) (\(value))" }
        return "CC \(key.controlID) = \(value)"
    }
}
