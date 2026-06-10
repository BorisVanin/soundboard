import Foundation
import Observation
import OSLog
import CoreAudio
import AppKit
import MixerModel
import MixerEngine
import MIDISurface
import DriverControl

private let midiLog = Logger(subsystem: "ca.borisvanin.soundboard", category: "MIDI")
private let recordLog = Logger(subsystem: "ca.borisvanin.soundboard", category: "Recording")

/// Composition root + router (the example's `MixerModel` role) on top of the real
/// audio engine. It owns:
///   • one `MIDISurface` (one callback for ALL MIDI),
///   • the audio sink (`MixEngine`: mic + system-tap → driver mix ring),
///   • one `MIDIFader`/`MIDIButton` per mappable control,
///   • a `MidiRouter` mapping (deviceID, controlID) → control,
///   • a single **clutch** (`clutchEngaged`) that gates every line's `onAction`:
///     engaged → actions reach audio/media; disengaged → everything still moves on
///     screen but goes nowhere. Assign mode disengages it.
///
/// System audio is captured by the Mac lane's process tap (`MacSoundLane`), so the
/// app no longer creates a Multi-Output Device or changes the system default output;
/// the Mac picker just chooses which output device's audio to tap (read-only).
@MainActor
@Observable
final class AppModel {

    // MARK: Control lines (one per mappable control)
    // Set once in init; the View observes each line's own @Observable members, so
    // the references themselves are ignored by Observation.
    @ObservationIgnored private(set) var micLevel: MIDIFader!
    @ObservationIgnored private(set) var macLevel: MIDIFader!     // system-audio lane (placeholder until tap)
    @ObservationIgnored private(set) var micMute: MIDIButton!
    @ObservationIgnored private(set) var macMute: MIDIButton!
    @ObservationIgnored private(set) var micOnOff: MIDIButton!
    @ObservationIgnored private(set) var mediaPlayPause: MIDIButton!
    @ObservationIgnored private(set) var mediaNext: MIDIButton!
    @ObservationIgnored private(set) var mediaPrev: MIDIButton!
    /// Assignable start/stop for recording the output mix to a file.
    @ObservationIgnored private(set) var recordControl: MIDIButton!
    /// Assignable on/off for monitoring the mix on an output device.
    @ObservationIgnored private(set) var monitorControl: MIDIButton!
    @ObservationIgnored private var lines: [any MIDIControl] = []

    /// Stable per-line identities (router/persistence keys).
    private enum Line {
        static let micLevel: Int32 = 0, micMute: Int32 = 1, micOnOff: Int32 = 2
        static let macLevel: Int32 = 3, macMute: Int32 = 4
        static let mediaPlayPause: Int32 = 5, mediaNext: Int32 = 6, mediaPrev: Int32 = 7
        static let record: Int32 = 8, monitor: Int32 = 9
    }

    // MARK: The clutch (single source of truth, req 3)
    /// When false, every line's `onAction` short-circuits: the UI and MIDI still
    /// move the controls, but nothing reaches audio/media. Assign mode opens it.
    var clutchEngaged = true

    /// Assign mode: the mixer becomes a MIDI-learn surface. Disengages the clutch
    /// (so feedback movements are audio-silent), snapshots the lines on entry, and
    /// restores them on exit.
    var assigning = false {
        didSet {
            guard assigning != oldValue else { return }
            clutchEngaged = !assigning
            if assigning { snapshot = makeSnapshot() }
            else { cancelLearning(); restoreSnapshot() }
        }
    }
    /// The line currently waiting to learn its next MIDI control (double-click).
    var learningLine: (any MIDIControl)?

    // MARK: Device / mic state
    /// The output device whose audio the Mac lane taps for recording. Selecting it
    /// only *reads* that device — it never changes the system's default output.
    var macSourceUID: String?
    var availableOutputs: [AudioOutputDevice] = []
    var availableInputs: [AudioOutputDevice] = []
    var selectedInputUID: String?

    // MARK: Monitor (play the mix to an output device so the operator can hear it)
    /// Whether the mix is currently being played to `monitorOutputUID`.
    var monitorEnabled = false
    /// Output device the mix is monitored on; defaults to the system output.
    var monitorOutputUID: String?
    /// Linear 0…1 monitor volume (a separate, smaller fader in the config popover).
    var monitorVolume: Float = 0.5

    var selectedMonitorMicUID: String?
    var lastMonitorMicUID: String?
    var monitorChannelSelections: [String: Set<Int>] = [:]
    var lastEvent = "—"
    var showLevels = true {
        didSet {
            guard isLoaded, showLevels != oldValue else { return }
            if showLevels { startMeterTimer() } else { stopMeterTimer() }
            saveNow()
        }
    }
    var micMeter: [Float] = []
    var macMeter: [Float] = []
    // Continuously-decaying peak state, updated every poll tick. The *Meter arrays
    // are republished from these only when their segment count changes.
    @ObservationIgnored private var micSmoothed: [Float] = []
    @ObservationIgnored private var macSmoothed: [Float] = []
    /// Whether any other process is currently producing audio output — a public-API
    /// proxy for the system play/pause state, driving the transport button's icon.
    private(set) var isPlaying = false

    // MARK: Recording
    /// Whether a recording is currently in progress (the UI source of truth).
    private(set) var isRecording = false
    /// File the most recent recording was (or is being) written to.
    private(set) var lastRecordingURL: URL?

    // MARK: Collaborators
    @ObservationIgnored private let midi = MIDISurface()
    @ObservationIgnored private let router = MidiRouter()
    @ObservationIgnored private let store: AssignmentStore
    /// The driver's loopback ("Soundboard") device — recorded to capture the full mix.
    @ObservationIgnored private let loopbackUID = LoopbackDriverControl.deviceUID
    // Plan A: captures the mic into the driver's shared mix ring (the device's input).
    // It also tees the finished mix to the monitor and the recorder.
    @ObservationIgnored private let mixEngine = MixEngine()
    @ObservationIgnored private var midiConnected = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var playingPollTimer: Timer?
    @ObservationIgnored private var isLoaded = false
    /// Whether the main window is currently open — persisted so a closed window stays
    /// closed across launches. `isTerminating` suppresses the close write on quit, so
    /// quitting with the window open is remembered as "open", not "closed".
    @ObservationIgnored private var mainWindowOpen = true
    @ObservationIgnored private var isTerminating = false

    private struct Snapshot {
        var micLevel: Float, macLevel: Float
        var micMute: Bool, macMute: Bool
        var micOn: Bool, mic: String?, lastMic: String?, record: Bool, monitor: Bool
    }
    @ObservationIgnored private var snapshot: Snapshot?

    private static let configKey = "SoundboardConfig"
    private static let multiOutputUID = "ca.borisvanin.soundboard.multiout"
    /// Legacy private-aggregate UID (MicMonitor's old device); kept only to filter
    /// any stale instance out of the device lists.
    private static let legacyMonitorUID = "ca.borisvanin.soundboard.micmonitor"

    init(store: AssignmentStore? = nil) {
        let config = Self.loadConfig()
        // Default is constructed here (in the main-actor init body) rather than as
        // a default argument, which would evaluate in a nonisolated context.
        self.store = store ?? UserDefaultsAssignmentStore()
        macSourceUID = config.firstOutputUID
        selectedInputUID = config.inputUID
        selectedMonitorMicUID = config.monitorMicUID
        lastMonitorMicUID = config.monitorLastMicUID ?? config.monitorMicUID
        monitorChannelSelections = config.monitorChannels.mapValues(Set.init)
        showLevels = config.showLevels
        mainWindowOpen = config.mainWindowOpen
        monitorEnabled = config.monitorEnabled
        monitorOutputUID = config.monitorOutputUID
        monitorVolume = config.monitorOutputVolume

        // All stored properties are initialized → self may now escape into the
        // lines' onAction closures.
        buildLines(config: config)

        refreshOutputs()
        refreshInputs()
        if selectedInputUID == nil, let d = AudioDevices.defaultInputDevice() {
            selectedInputUID = AudioDevices.uid(of: d)
        }
        cleanupLegacyMultiOutput()
        if macSourceUID == nil || AudioDevices.deviceID(forUID: macSourceUID!) == nil {
            macSourceUID = AudioDevices.defaultOutputDeviceUID()   // default: tap what you hear
        }
        if monitorOutputUID == nil || AudioDevices.deviceID(forUID: monitorOutputUID!) == nil {
            monitorOutputUID = AudioDevices.defaultOutputDeviceUID()   // default: where you're listening
        }
        restoreAssignments()             // re-apply saved MIDI maps (by lineID)
        isLoaded = true
        reconfigureMonitor()
        applyMonitor()                   // resume a persisted monitor on the chosen device
        connectMIDI()                    // always listen to every MIDI source
        startRefreshTimer()
        if showLevels { startMeterTimer() }

        // Mark termination so the window's onDisappear (if it fires during quit) is not
        // recorded as the user closing the window — quitting with it open stays "open".
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isTerminating = true }
        }
    }

    /// Whether to open the main window at launch — false when it was closed at the
    /// previous quit, so the app comes up as a menu-bar agent. Read by `AppDelegate`
    /// straight from the persisted config (no instance needed).
    static func shouldOpenMainWindowAtLaunch() -> Bool { loadConfig().mainWindowOpen }

    // MARK: - Build the control lines (the audio/media sinks, gated by the clutch)

    private func buildLines(config: PersistedConfig) {
        let mic = config.channels["mic"]
        let mac = config.channels["mac"]

        micLevel = MIDIFader(lineID: Line.micLevel, initial: mic?.level ?? 0.85) { [weak self] v in
            guard let self, self.clutchEngaged else { return }
            self.mixEngine.setMicGain(v, muted: self.micMute.isOn); self.scheduleSave()
        }
        // System ("Mac") lane — the system-audio tap; gain feeds the mixer.
        macLevel = MIDIFader(lineID: Line.macLevel, initial: mac?.level ?? 0.85) { [weak self] v in
            guard let self, self.clutchEngaged else { return }
            self.mixEngine.setMacGain(v, muted: self.macMute.isOn); self.scheduleSave()
        }

        micMute = MIDIButton(lineID: Line.micMute, kind: .toggle, initialOn: mic?.isMuted ?? false) { [weak self] muted in
            guard let self, self.clutchEngaged else { return }
            self.mixEngine.setMicGain(self.micLevel.rawValue, muted: muted); self.scheduleSave()
        }
        macMute = MIDIButton(lineID: Line.macMute, kind: .toggle, initialOn: mac?.isMuted ?? false) { [weak self] muted in
            guard let self, self.clutchEngaged else { return }
            self.mixEngine.setMacGain(self.macLevel.rawValue, muted: muted); self.scheduleSave()
        }
        micOnOff = MIDIButton(lineID: Line.micOnOff, kind: .toggle, initialOn: selectedMonitorMicUID != nil) { [weak self] on in
            guard let self, self.clutchEngaged else { return }
            self.selectMonitorMic(on ? (self.lastMonitorMicUID ?? self.availableInputs.first?.uid) : nil)
        }

        mediaPlayPause = MIDIButton(lineID: Line.mediaPlayPause, kind: .trigger) { [weak self] _ in
            guard self?.clutchEngaged == true else { return }; MediaControl.playPause()
        }
        mediaNext = MIDIButton(lineID: Line.mediaNext, kind: .trigger) { [weak self] _ in
            guard self?.clutchEngaged == true else { return }; MediaControl.next()
        }
        mediaPrev = MIDIButton(lineID: Line.mediaPrev, kind: .trigger) { [weak self] _ in
            guard self?.clutchEngaged == true else { return }; MediaControl.previous()
        }

        recordControl = MIDIButton(lineID: Line.record, kind: .toggle, initialOn: false) { [weak self] on in
            guard let self, self.clutchEngaged else { return }
            if on { self.startRecording() } else { self.stopRecording() }
        }

        monitorControl = MIDIButton(lineID: Line.monitor, kind: .toggle, initialOn: monitorEnabled) { [weak self] on in
            guard let self, self.clutchEngaged else { return }
            self.monitorEnabled = on
            self.applyMonitor()
            self.saveNow()
        }

        lines = [micLevel, micMute, micOnOff, macLevel, macMute,
                 mediaPlayPause, mediaNext, mediaPrev, recordControl, monitorControl]
        setupRemoteControl()
    }

    // MARK: - Remote control (soundboardctl via DistributedNotificationCenter)

    /// Observe one-way control commands from the `soundboardctl` CLI. App-side
    /// only — cannot affect coreaudiod. Commands arrive as the notification's
    /// string `object` (e.g. "mic:on", "gain:0.6", "status", "quit").
    private func setupRemoteControl() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("ca.borisvanin.soundboard.cmd"),
            object: nil, queue: .main) { [weak self] note in
            let cmd = note.object as? String
            Task { @MainActor in
                guard let self, let cmd else { return }
                self.handleRemoteCommand(cmd)
            }
        }
    }

    private func handleRemoteCommand(_ cmd: String) {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "mic":
            let on = parts.count > 1 && parts[1] == "on"
            selectMonitorMic(on ? (lastMonitorMicUID ?? availableInputs.first?.uid) : nil)
            micOnOff.setSilently(on: selectedMonitorMicUID != nil)
        case "gain":
            if parts.count > 1, let v = Float(parts[1]) {
                micLevel.setSilently(v)
                mixEngine.setMicGain(v, muted: micMute.isOn)
            }
        case "status":
            midiLog.info("remote status: mic=\(self.selectedMonitorMicUID ?? "off", privacy: .public) gain=\(self.micLevel.rawValue) engineRunning=\(self.mixEngine.isRunning)")
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

    private func handleMidi(_ key: MIDIKey, value: Int32) {
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

    private func restoreAssignments() {
        let saved = Dictionary(store.load().map { ($0.lineID, $0) }, uniquingKeysWith: { a, _ in a })
        for line in lines {
            guard let a = saved[line.lineID], let d = a.midiDeviceID, let c = a.midiControlID else { continue }
            let key = MIDIKey(deviceID: d, controlID: c)
            line.assign(to: key)
            router.rebind(line, from: nil, to: key)
        }
    }
    private func persistAssignments() {
        store.save(lines.map { LineAssignment(lineID: $0.lineID, midiDeviceID: $0.midiDeviceID, midiControlID: $0.midiControlID) })
    }

    // MARK: - Assign-mode snapshot (restore feedback movements on exit)

    private func makeSnapshot() -> Snapshot {
        Snapshot(micLevel: micLevel.rawValue, macLevel: macLevel.rawValue,
                 micMute: micMute.isOn, macMute: macMute.isOn,
                 micOn: micOnOff.isOn, mic: selectedMonitorMicUID, lastMic: lastMonitorMicUID,
                 record: recordControl.isOn, monitor: monitorControl.isOn)
    }
    private func restoreSnapshot() {
        guard let s = snapshot else { return }
        snapshot = nil
        micLevel.setSilently(s.micLevel); macLevel.setSilently(s.macLevel)
        micMute.setSilently(on: s.micMute); macMute.setSilently(on: s.macMute)
        micOnOff.setSilently(on: s.micOn); recordControl.setSilently(on: s.record)
        monitorControl.setSilently(on: s.monitor)
        selectedMonitorMicUID = s.mic; lastMonitorMicUID = s.lastMic
    }

    // MARK: - Managed multi-output (monitoring plumbing)

    /// Plan A captures system audio with a process tap (the Mac lane), not an output
    /// mirror — so the app no longer creates a Multi-Output Device. Tear down any
    /// stale one left by older builds and restore a real default output device so the
    /// user keeps hearing audio.
    private func cleanupLegacyMultiOutput() {
        guard let agg = AudioDevices.deviceID(forUID: Self.multiOutputUID) else { return }
        if AudioDevices.defaultOutputDeviceUID() == Self.multiOutputUID,
           let real = macSourceUID ?? availableOutputs.first?.uid,
           let dev = AudioDevices.deviceID(forUID: real) {
            AudioDevices.setDefaultOutputDevice(dev)
        }
        AudioDevices.destroyAggregate(agg)
    }

    /// Pick which output device's audio the Mac lane records. This only *reads* that
    /// device's stream via the process tap — it never changes the system's default
    /// output device or any other system audio setting.
    func setMacSource(_ uid: String) {
        guard uid != Self.multiOutputUID, uid != loopbackUID else { return }
        macSourceUID = uid
        reconfigureMonitor()
        saveNow()
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

    private func reconfigureMonitor() {
        // Mic lane → mix ring; the Mac (system-tap) lane lives alongside the board.
        let chans = selectedMonitorMicUID.flatMap { monitorChannelSelections[$0] }.map(Array.init) ?? []
        mixEngine.configure(micUID: selectedMonitorMicUID, channels: chans)
        mixEngine.setMicGain(micLevel.rawValue, muted: micMute.isOn)
        // The Mac lane taps the chosen output device's audio (read-only), independent
        // of the mic — so its VU shows activity whether or not a mic is selected.
        mixEngine.setMacSource(macSourceUID)
        mixEngine.setMacGain(macLevel.rawValue, muted: macMute.isOn)
    }

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
        if let uid { monitorOutputUID = uid; monitorEnabled = true }
        else { monitorEnabled = false }
        monitorControl?.setSilently(on: monitorEnabled)
        applyMonitor()
        saveNow()
    }

    /// Set the (smaller) monitor volume fader. Live to the engine; debounced save.
    func setMonitorVolume(_ v: Float) {
        monitorVolume = v
        mixEngine.setMonitorVolume(v)
        scheduleSave()
    }

    /// Start or stop the monitor to match `monitorEnabled` on the chosen device.
    private func applyMonitor() {
        mixEngine.setMonitorEnabled(monitorEnabled, deviceUID: monitorOutputUID, volume: monitorVolume)
    }

    // MARK: - Recording (the output mix → a .wav file)

    /// Toggle recording from the UI (drives the same assignable control as MIDI).
    func toggleRecording() { recordControl.press() }

    /// Record the finished mix — the same stream fed to the Soundboard loopback driver
    /// and the monitor — to a .wav file (a tee inside `MixEngine`, not a device round-trip).
    private func startRecording() {
        guard !isRecording else { return }
        let url = Self.makeRecordingURL()
        do {
            try mixEngine.startRecording(to: url)
            lastRecordingURL = url
            isRecording = true
        } catch {
            recordLog.error("Failed to start recording: \(String(describing: error))")
            isRecording = false
            recordControl.setSilently(on: false)   // revert the toggle without re-firing
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        mixEngine.stopRecording()
        isRecording = false
        if let url = lastRecordingURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// `~/Music/Soundboard/Soundboard YYYY-MM-DD HH.mm.ss.wav` (folder created lazily).
    private static func makeRecordingURL() -> URL {
        let base = (FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Soundboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return base.appendingPathComponent("Soundboard \(fmt.string(from: Date())).wav")
    }

    // MARK: - Persistence (levels/mutes/device/mic; MIDI maps live in AssignmentStore)

    private static func loadConfig() -> PersistedConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let cfg = try? JSONDecoder().decode(PersistedConfig.self, from: data) else { return PersistedConfig() }
        return cfg
    }
    private func currentConfig() -> PersistedConfig {
        let channels: [String: ChannelSetting] = [
            "mic": .init(level: micLevel.rawValue, isMuted: micMute.isOn),
            "mac": .init(level: macLevel.rawValue, isMuted: macMute.isOn),
        ]
        // The persisted `firstOutputUID` field now stores the Mac tap-source device.
        return PersistedConfig(firstOutputUID: macSourceUID, channels: channels,
                               outputVolumes: [:], inputUID: selectedInputUID,
                               monitorMicUID: selectedMonitorMicUID,
                               monitorLastMicUID: lastMonitorMicUID,
                               monitorChannels: monitorChannelSelections.mapValues { Array($0).sorted() },
                               showLevels: showLevels,
                               monitorEnabled: monitorEnabled,
                               monitorOutputUID: monitorOutputUID,
                               monitorOutputVolume: monitorVolume,
                               mainWindowOpen: mainWindowOpen)
    }
    private func saveNow() {
        guard isLoaded else { return }
        if let data = try? JSONEncoder().encode(currentConfig()) { UserDefaults.standard.set(data, forKey: Self.configKey) }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    // MARK: - Timers / meters

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refreshOutputs(); self?.refreshInputs()
            }
        }
    }
    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollLevels() }
        }
    }
    private func stopMeterTimer() {
        meterTimer?.invalidate(); meterTimer = nil
        micMeter = []; micSmoothed = []; macMeter = []; macSmoothed = []
    }

    // MARK: - Play/pause state (transport button icon)

    /// Poll the "is any process producing output" signal every 0.5 s while the main
    /// window (and its transport button) is visible. Deliberately a bounded poll,
    /// not CoreAudio property listeners: those fire per-process on the main actor
    /// and, under load, can flood it and starve MIDI handling (which also hops to
    /// the main actor). Two cheap reads per second can't. Stopped when the window
    /// closes — the icon isn't shown then, so there's nothing to keep fresh.
    func windowBecameVisible() {
        playingPollTimer?.invalidate()
        updateIsPlaying()
        playingPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.updateIsPlaying() }
        }
        setMainWindowOpen(true)
    }

    func windowBecameHidden() {
        playingPollTimer?.invalidate(); playingPollTimer = nil
        // Don't record a close that's just the app quitting with the window open.
        if !isTerminating { setMainWindowOpen(false) }
    }

    /// Persist the window's open/closed state so it can be restored at next launch.
    private func setMainWindowOpen(_ open: Bool) {
        guard isLoaded, open != mainWindowOpen else { return }
        mainWindowOpen = open
        saveNow()
    }

    private func updateIsPlaying() {
        guard #available(macOS 14.2, *) else { return }
        let playing = !AudioProcesses.runningOutput().isEmpty
        if playing != isPlaying { isPlaying = playing }
    }
    private func smooth(_ raw: [Float], into old: [Float]) -> [Float] {
        raw.enumerated().map { i, v in
            let prev = i < old.count ? old[i] : 0
            return max(min(v, 1), prev * 0.80)
        }
    }
    /// Per-segment lower thresholds in dBFS, bottom → top. A segment lights when the
    /// (smoothed) peak reaches its threshold. dB spacing matches perceived loudness
    /// far better than a linear split — the top two are the yellow/red headroom band.
    static let meterThresholdsDB: [Float] = [-42, -36, -30, -24, -18, -10, -3]
    static var meterSegmentCount: Int { meterThresholdsDB.count }
    private static let meterThresholdsLinear: [Float] = meterThresholdsDB.map { powf(10, $0 / 20) }

    /// How many segments a linear-amplitude peak lights (0…segmentCount).
    static func litSegments(_ level: Float) -> Int {
        let v = min(max(level, 0), 1)
        var n = 0
        for t in meterThresholdsLinear where v >= t { n += 1 }
        return n
    }

    private static func segments(_ a: [Float]) -> [Int] { a.map(litSegments) }

    /// Assign a meter only if its segment-quantized form changed; otherwise the
    /// stored value (and the views observing it) stay put — no redraw.
    private func publishMeter(_ value: [Float], to keyPath: ReferenceWritableKeyPath<AppModel, [Float]>) {
        if Self.segments(value) != Self.segments(self[keyPath: keyPath]) {
            self[keyPath: keyPath] = value
        }
    }

    private func pollLevels() {
        let m = mixEngine.consumeMicMeters()
        let micRaw: [Float] = m.count == 0 ? [] : (m.count == 1 ? [m.left] : [m.left, m.right])
        micSmoothed = smooth(micRaw, into: micSmoothed)
        publishMeter(micSmoothed, to: \.micMeter)

        let mac = mixEngine.consumeMacMeters()
        let macRaw: [Float] = mac.count == 0 ? [] : (mac.count == 1 ? [mac.left] : [mac.left, mac.right])
        macSmoothed = smooth(macRaw, into: macSmoothed)
        publishMeter(macSmoothed, to: \.macMeter)
    }

    static func describe(_ key: MIDIKey, _ value: Int32) -> String {
        if key.controlID & MIDISurface.noteFlag != 0 { return "Note \(key.controlID & 0x7F) (\(value))" }
        return "CC \(key.controlID) = \(value)"
    }
}
