import Foundation
import CoreMIDI
import OSLog

/// The FAST PRODUCER (the example's `MidiSource` role, on real CoreMIDI). Wraps
/// the OS input and forwards every decoded control as `(deviceID, controlID,
/// value)` to a single `onValue` callback — it knows nothing about SwiftUI,
/// audio, routing, or assignment. The owner (AppModel) hops actors and routes.
///
///  - `deviceID`  : the source endpoint's stable `kMIDIPropertyUniqueID`.
///  - `controlID` : the physical control on that device — a CC number as-is, a
///                  note number OR-ed with `noteFlag` so notes and CCs of the same
///                  number don't collide.
///  - `value`     : CC value, or note velocity (note-off / release = 0), 0…127.
///
/// Uses the modern MIDI 1.0 universal-packet API (`MIDIInputPortCreateWithProtocol`).
public final class MIDISurface {

    /// OR-ed into `controlID` for note messages, so Note n and CC n stay distinct.
    public static let noteFlag: Int32 = 0x100

    private let logger = Logger(subsystem: "ca.borisvanin.soundboard", category: "MIDI")
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()

    /// The single sink for decoded control values. Called on the MIDI thread.
    public var onValue: ((_ deviceID: Int32, _ controlID: Int32, _ value: Int32) -> Void)?

    public init() {}

    public func start() {
        var status = MIDIClientCreateWithBlock("Soundboard" as CFString, &client) { [weak self] notification in
            self?.handleSetupChange(notification)
        }
        guard status == noErr else { logger.error("MIDIClientCreate failed: \(status)"); return }

        status = MIDIInputPortCreateWithProtocol(
            client, "Soundboard In" as CFString, ._1_0, &inputPort
        ) { [weak self] eventList, srcConnRefCon in
            let deviceID = Int32(truncatingIfNeeded: Int(bitPattern: srcConnRefCon))
            self?.handle(eventList, deviceID: deviceID)
        }
        guard status == noErr else { logger.error("MIDIInputPortCreate failed: \(status)"); return }

        connectAllSources()
    }

    public func stop() {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
        inputPort = 0; client = 0
    }

    // MARK: Source wiring

    /// Connect every input source, tagging each connection with the source's
    /// unique ID via the refCon so the read block can report which device fired.
    private func connectAllSources() {
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            let uid = Self.uniqueID(of: source)
            let refCon = UnsafeMutableRawPointer(bitPattern: Int(uid))   // nil when uid == 0
            if MIDIPortConnectSource(inputPort, source, refCon) == noErr {
                logger.info("Connected MIDI source #\(index) (uid \(uid))")
            }
        }
    }

    private func reconnect() {
        guard inputPort != 0 else { return }
        for index in 0..<MIDIGetNumberOfSources() {
            MIDIPortDisconnectSource(inputPort, MIDIGetSource(index))
        }
        connectAllSources()
    }

    private func handleSetupChange(_ notification: UnsafePointer<MIDINotification>) {
        if notification.pointee.messageID == .msgObjectAdded { reconnect() }
    }

    private static func uniqueID(of obj: MIDIObjectRef) -> Int32 {
        var value: Int32 = 0
        MIDIObjectGetIntegerProperty(obj, kMIDIPropertyUniqueID, &value)
        return value
    }

    // MARK: Decoding

    private func handle(_ eventList: UnsafePointer<MIDIEventList>, deviceID: Int32) {
        let list = eventList.pointee
        var packet = list.packet
        for _ in 0..<list.numPackets {
            for word in Mirror(reflecting: packet.words).children.prefix(Int(packet.wordCount)) {
                if let word = word.value as? UInt32 { decode(word, deviceID: deviceID) }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    /// Decode one 32-bit Universal MIDI Packet (MIDI 1.0 channel-voice) and
    /// forward it to `onValue`.
    private func decode(_ word: UInt32, deviceID: Int32) {
        let messageType = (word >> 28) & 0xF
        guard messageType == 0x2 else { return }          // 0x2 = MIDI 1.0 channel voice
        let statusNibble = (word >> 20) & 0xF
        let data1 = Int32((word >> 8) & 0x7F)
        let data2 = Int32(word & 0x7F)

        switch statusNibble {
        case 0xB:  onValue?(deviceID, data1, data2)                 // control change
        case 0x9:  onValue?(deviceID, Self.noteFlag | data1, data2) // note on (velocity 0 = release)
        case 0x8:  onValue?(deviceID, Self.noteFlag | data1, 0)     // note off
        default:   break
        }
    }
}
