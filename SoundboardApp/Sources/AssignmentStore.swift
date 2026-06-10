//  AssignmentStore.swift
//  Adapted from example/app/AssignmentStore.swift.
//
//  A control's value is transient (it follows the device); its MIDI ASSIGNMENT
//  (lineID -> deviceID/controlID) is configuration the user expects to persist.
//  This is that persistence, behind a protocol so it can be swapped (UserDefaults
//  in the app, in-memory in tests/previews). Keyed by `lineID`.

import Foundation

/// One line's persisted MIDI mapping. `lineID` ties it back to a control.
public struct LineAssignment: Codable, Hashable {
    public let lineID: Int32
    public var midiDeviceID: Int32?
    public var midiControlID: Int32?

    public init(lineID: Int32, midiDeviceID: Int32?, midiControlID: Int32?) {
        self.lineID = lineID
        self.midiDeviceID = midiDeviceID
        self.midiControlID = midiControlID
    }
}

/// Abstraction over app-level storage. Depend on a role, not a backend.
public protocol AssignmentStore {
    func load() -> [LineAssignment]
    func save(_ assignments: [LineAssignment])
}

/// Default: UserDefaults, JSON-encoded under a single key.
public final class UserDefaultsAssignmentStore: AssignmentStore {
    private let key = "midi.assignments.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> [LineAssignment] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([LineAssignment].self, from: data)
        else { return [] }
        return list
    }

    public func save(_ assignments: [LineAssignment]) {
        let data = try? JSONEncoder().encode(assignments)
        defaults.set(data, forKey: key)
    }
}

/// In-memory store — handy for tests/previews (no persistence side effects).
public final class InMemoryAssignmentStore: AssignmentStore {
    private var stored: [LineAssignment]
    public init(_ initial: [LineAssignment] = []) { self.stored = initial }
    public func load() -> [LineAssignment] { stored }
    public func save(_ assignments: [LineAssignment]) { stored = assignments }
}
