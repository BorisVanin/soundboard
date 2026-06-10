//  MIDIControl.swift
//  Adapted from example/app/ControlLine.swift.
//
//  One control, end to end. A control owns its MIDI assignment and a single
//  injected `onAction` sink; both MIDI input and UI input funnel through the same
//  `rawValue` (faders) or press (buttons), so there is exactly one path to audio.
//  Controls don't know about audio, the router, or the clutch — those live in the
//  composition root (AppModel).
//
//  Two concrete kinds, unified by `MIDIControl` so the router / store / clutch
//  treat them alike:
//    • MIDIFader<Float> — a continuous fader (0…1).
//    • MIDIButton       — a momentary button, either .toggle (mute / mic on-off)
//                            or .trigger (media transport).

import Foundation
import Observation
import OSLog

// MARK: - Addressing

/// Which physical (device, control) a MIDI message targets.
public struct MIDIKey: Hashable, Sendable {
    public let deviceID: Int32
    public let controlID: Int32
    public init(deviceID: Int32, controlID: Int32) {
        self.deviceID = deviceID
        self.controlID = controlID
    }
}

/// The non-generic surface the router, AssignmentStore, and clutch need — so a
/// single table/array can hold faders and buttons together (the example's
/// `MidiAddressable` escape hatch).
@MainActor
public protocol MIDIControl: AnyObject {
    nonisolated var lineID: Int32 { get }
    var midiDeviceID: Int32? { get }
    var midiControlID: Int32? { get }
    /// Bind/unbind the control's MIDI assignment (router keeps its table in sync).
    func assign(to key: MIDIKey?)
    /// Apply a raw MIDI value (0…127). The composition root hops the MIDI callback
    /// to the main actor and routes here, so this is main-actor isolated.
    func onMidiEvent(_ raw: Int32)
}

public extension MIDIControl {
    /// The (device, control) this line is bound to, or nil while unmapped.
    var midiKey: MIDIKey? {
        guard let d = midiDeviceID, let c = midiControlID else { return nil }
        return MIDIKey(deviceID: d, controlID: c)
    }
}

// MARK: - The value abstraction (faders)

/// Explains how a fader's value bridges the two fixed edges: a 7-bit MIDI input
/// and a SwiftUI Slider (which speaks Double).
public protocol MIDIScalar {
    static func fromMIDI(_ raw: Int32) -> Self      // 0…127 -> value
    static func fromSlider(_ d: Double) -> Self     // Slider -> value
    var sliderValue: Double { get }                 // value  -> Slider
    static var sliderRange: ClosedRange<Double> { get }
}

extension Float: MIDIScalar {
    public static func fromMIDI(_ raw: Int32) -> Float { Float(raw) / 127 }
    public static func fromSlider(_ d: Double) -> Float { Float(d) }
    public var sliderValue: Double { Double(self) }
    public static var sliderRange: ClosedRange<Double> { 0...1 }
}

// MARK: - Continuous control (fader)

/// Concrete `Float` fader. Deliberately **not** generic: a generic
/// `@Observable @MainActor final class` crashes the Swift SIL optimizer's
/// inliner under `-O` (in this class's synthesized deinit), forcing the whole
/// app to build `-Onone` — which makes SwiftUI/Observation ~10× slower. Every
/// call site only ever used `MIDIFader<Float>`, so the value type is fixed to
/// `Float`; the `MIDIScalar` helpers on `Float` keep the MIDI/slider bridges.
@MainActor
@Observable
public final class MIDIFader: MIDIControl, Identifiable {

    public nonisolated let lineID: Int32
    public nonisolated var id: Int32 { lineID }

    public private(set) var midiDeviceID: Int32?
    public private(set) var midiControlID: Int32?

    /// The audio sink. The line has no idea this reaches audio (or that a clutch
    /// may gate it). Setting `rawValue` in `init` does not fire didSet.
    @ObservationIgnored private let onAction: (Float) -> Void

    public var rawValue: Float {
        didSet { if !silent { onAction(rawValue) } }
    }

    /// Slider bridge (Float <-> Double via MIDIScalar).
    public var valueSlider: Double {
        get { rawValue.sliderValue }
        set { rawValue = Float.fromSlider(newValue) }
    }
    public var sliderRange: ClosedRange<Double> { Float.sliderRange }

    public init(lineID: Int32, initial: Float, onAction: @escaping (Float) -> Void) {
        self.lineID = lineID
        self.rawValue = initial
        self.onAction = onAction
    }

    /// Set `rawValue` without firing the sink — used to restore the UI position
    /// after assign mode without driving audio.
    public func setSilently(_ value: Float) {
        silent = true
        rawValue = value
        silent = false
    }
    @ObservationIgnored private var silent = false

    public func assign(to key: MIDIKey?) {
        midiDeviceID = key?.deviceID
        midiControlID = key?.controlID
    }

    public func onMidiEvent(_ raw: Int32) {
        rawValue = Float.fromMIDI(raw)
    }
}

// MARK: - Momentary control (button)

@MainActor
@Observable
public final class MIDIButton: MIDIControl, Identifiable {

    public enum Kind: Sendable {
        case toggle    // mute / mic on-off — a press flips `isOn`
        case trigger   // media transport — a press fires once, no persistent state
    }

    public nonisolated let lineID: Int32
    public nonisolated var id: Int32 { lineID }
    public nonisolated let kind: Kind

    public private(set) var midiDeviceID: Int32?
    public private(set) var midiControlID: Int32?

    @ObservationIgnored private let onAction: (Bool) -> Void
    @ObservationIgnored private static let log = Logger(subsystem: "ca.borisvanin.soundboard", category: "MIDI.Button")

    /// A button fires on the press edge: ANY non-zero MIDI value counts as a press
    /// (note velocity / CC value), and 0 is a release. After firing, further
    /// non-zero values are ignored until a release arrives OR this interval passes
    /// — so one physical press (which can emit a burst of values, or no note-off)
    /// triggers exactly once.
    public var retriggerInterval: TimeInterval = 0.25
    @ObservationIgnored private var armed = true
    @ObservationIgnored private var lastTrigger = Date.distantPast

    /// Persistent on/off for `.toggle` controls (the mute/engaged state the UI
    /// shows). Unused by `.trigger`. Writing it fires the sink.
    public var isOn: Bool {
        didSet {
            guard kind == .toggle, !silent else { return }
            onAction(isOn)
        }
    }
    @ObservationIgnored private var silent = false

    public init(lineID: Int32, kind: Kind, initialOn: Bool = false, onAction: @escaping (Bool) -> Void) {
        self.lineID = lineID
        self.kind = kind
        self.isOn = initialOn
        self.onAction = onAction
    }

    /// A momentary press, from a UI Button or a MIDI note-on.
    public func press() {
        switch kind {
        case .toggle:  isOn.toggle()        // didSet fires onAction(isOn)
        case .trigger: onAction(true)       // fire once; value is ignored
        }
    }

    /// Set the toggle state without firing the sink (seed/restore).
    public func setSilently(on: Bool) {
        silent = true
        isOn = on
        silent = false
    }

    public func assign(to key: MIDIKey?) {
        midiDeviceID = key?.deviceID
        midiControlID = key?.controlID
    }

    public func onMidiEvent(_ raw: Int32) {
        // Release (0) re-arms so the next press fires immediately.
        if raw <= 0 {
            armed = true
            return
        }
        let now = Date()
        let timedOut = now.timeIntervalSince(lastTrigger) >= retriggerInterval
        guard armed || timedOut else {
            return
        }
        armed = false
        lastTrigger = now
        press()
    }
}
