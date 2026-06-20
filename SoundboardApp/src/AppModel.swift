import Foundation
import Observation
import OSLog
import CoreAudio
import AppKit
import MixerModel
import MixerEngine
import MIDISurface
import DriverControl

let midiLog = Logger(subsystem: "ca.borisvanin.soundboard", category: "MIDI")
let recordLog = Logger(subsystem: "ca.borisvanin.soundboard", category: "Recording")

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
    @ObservationIgnored var lines: [any MIDIControl] = []

    /// Stable per-line identities (router/persistence keys).
    enum Line {
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
            if assigning { snapshot = makeSnapshot() } else { cancelLearning(); restoreSnapshot() }
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
    @ObservationIgnored var micSmoothed: [Float] = []
    @ObservationIgnored var macSmoothed: [Float] = []
    /// Whether any other process is currently producing audio output — a public-API
    /// proxy for the system play/pause state, driving the transport button's icon.
    var isPlaying = false

    // MARK: Recording
    /// Whether a recording is currently in progress (the UI source of truth).
    var isRecording = false
    /// File the most recent recording was (or is being) written to.
    var lastRecordingURL: URL?

    // MARK: Collaborators
    @ObservationIgnored let midi = MIDISurface()
    @ObservationIgnored let router = MidiRouter()
    @ObservationIgnored let store: AssignmentStore
    /// The driver's loopback ("Soundboard") device — recorded to capture the full mix.
    @ObservationIgnored let loopbackUID = LoopbackDriverControl.deviceUID
    // Plan A: captures the mic into the driver's shared mix ring (the device's input).
    // It also tees the finished mix to the monitor and the recorder.
    @ObservationIgnored let mixEngine = MixEngine()
    @ObservationIgnored var midiConnected = false
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var refreshTimer: Timer?
    @ObservationIgnored var meterTimer: Timer?
    @ObservationIgnored var playingPollTimer: Timer?
    @ObservationIgnored var isLoaded = false
    /// Whether the main window is currently open — persisted so a closed window stays
    /// closed across launches. `isTerminating` suppresses the close write on quit, so
    /// quitting with the window open is remembered as "open", not "closed".
    @ObservationIgnored var mainWindowOpen = true
    @ObservationIgnored var isTerminating = false

    struct Snapshot {
        var micLevel: Float, macLevel: Float
        var micMute: Bool, macMute: Bool
        var micOn: Bool, mic: String?, lastMic: String?, record: Bool, monitor: Bool
    }
    @ObservationIgnored var snapshot: Snapshot?

    static let configKey = "SoundboardConfig"
    static let multiOutputUID = "ca.borisvanin.soundboard.multiout"
    /// Legacy private-aggregate UID (MicMonitor's old device); kept only to filter
    /// any stale instance out of the device lists.
    static let legacyMonitorUID = "ca.borisvanin.soundboard.micmonitor"

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
        if selectedInputUID == nil, let device = AudioDevices.defaultInputDevice() {
            selectedInputUID = AudioDevices.uid(of: device)
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

    // MARK: - Build the control lines (the audio/media sinks, gated by the clutch)

    private func buildLines(config: PersistedConfig) {
        buildMicLines(config: config)
        buildMediaLines()
        buildTransportLines()
        lines = [micLevel, micMute, micOnOff, macLevel, macMute,
                 mediaPlayPause, mediaNext, mediaPrev, recordControl, monitorControl]
        setupRemoteControl()
    }

    /// Mic + system ("Mac") lanes: faders and mutes that feed the mixer, plus the
    /// mic On/Off line that selects the rendered mic.
    private func buildMicLines(config: PersistedConfig) {
        let mic = config.channels["mic"]
        let mac = config.channels["mac"]

        micLevel = MIDIFader(lineID: Line.micLevel, initial: mic?.level ?? 0.85) { [weak self] value in
            guard let self, self.clutchEngaged else { return }
            self.mixEngine.setMicGain(value, muted: self.micMute.isOn); self.scheduleSave()
        }
        // System ("Mac") lane — the system-audio tap; gain feeds the mixer.
        macLevel = MIDIFader(lineID: Line.macLevel, initial: mac?.level ?? 0.85) { [weak self] value in
            guard let self, self.clutchEngaged else { return }
            self.mixEngine.setMacGain(value, muted: self.macMute.isOn); self.scheduleSave()
        }

        micMute = MIDIButton(lineID: Line.micMute, kind: .toggle,
                             initialOn: mic?.isMuted ?? false) { [weak self] muted in
            guard let self, self.clutchEngaged else { return }
            self.mixEngine.setMicGain(self.micLevel.rawValue, muted: muted); self.scheduleSave()
        }
        macMute = MIDIButton(lineID: Line.macMute, kind: .toggle,
                             initialOn: mac?.isMuted ?? false) { [weak self] muted in
            guard let self, self.clutchEngaged else { return }
            self.mixEngine.setMacGain(self.macLevel.rawValue, muted: muted); self.scheduleSave()
        }
        micOnOff = MIDIButton(lineID: Line.micOnOff, kind: .toggle,
                              initialOn: selectedMonitorMicUID != nil) { [weak self] isOn in
            guard let self, self.clutchEngaged else { return }
            self.selectMonitorMic(isOn ? (self.lastMonitorMicUID ?? self.availableInputs.first?.uid) : nil)
        }
    }

    /// Media transport triggers (play/pause, next, previous).
    private func buildMediaLines() {
        mediaPlayPause = MIDIButton(lineID: Line.mediaPlayPause, kind: .trigger) { [weak self] _ in
            guard self?.clutchEngaged == true else { return }; MediaControl.playPause()
        }
        mediaNext = MIDIButton(lineID: Line.mediaNext, kind: .trigger) { [weak self] _ in
            guard self?.clutchEngaged == true else { return }; MediaControl.next()
        }
        mediaPrev = MIDIButton(lineID: Line.mediaPrev, kind: .trigger) { [weak self] _ in
            guard self?.clutchEngaged == true else { return }; MediaControl.previous()
        }
    }

    /// Record and monitor toggles.
    private func buildTransportLines() {
        recordControl = MIDIButton(lineID: Line.record, kind: .toggle, initialOn: false) { [weak self] isOn in
            guard let self, self.clutchEngaged else { return }
            if isOn { self.startRecording() } else { self.stopRecording() }
        }

        monitorControl = MIDIButton(lineID: Line.monitor, kind: .toggle,
                                    initialOn: monitorEnabled) { [weak self] isOn in
            guard let self, self.clutchEngaged else { return }
            self.monitorEnabled = isOn
            self.applyMonitor()
            self.saveNow()
        }
    }
}
