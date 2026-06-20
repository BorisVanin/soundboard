//  MidiRouter.swift
//  Adapted from the MidiRouter in example/app/MixerModel.swift.
//
//  (deviceID, controlID) -> control routing table. The composition root hops
//  every MIDI callback to the main actor and routes here, so this is a plain
//  main-actor table (no lock). Holds `any MIDIControl`, so faders and buttons
//  share one table.

import Foundation

@MainActor
final class MidiRouter {
    private var map: [MIDIKey: any MIDIControl] = [:]

    /// The control bound to a key, or nil if unmapped (→ event ignored).
    func control(for key: MIDIKey) -> (any MIDIControl)? { map[key] }

    /// Move a control from its old key (if any) to a new key. nil `to` unbinds.
    func rebind(_ control: any MIDIControl, from oldKey: MIDIKey?, to newKey: MIDIKey?) {
        if let oldKey { map[oldKey] = nil }
        if let newKey { map[newKey] = control }
    }
}
