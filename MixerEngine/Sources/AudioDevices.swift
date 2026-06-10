import Foundation
import CoreAudio

/// A selectable output device.
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

/// Enumeration + lookup of Core Audio devices. Stateless HAL wrappers, callable
/// from any thread (the volume writers run off the main actor), so `nonisolated`.
public nonisolated enum AudioDevices {

    public static func outputDevices() -> [AudioOutputDevice] {
        devices(scope: kAudioObjectPropertyScopeOutput)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func inputDevices() -> [AudioOutputDevice] {
        devices(scope: kAudioObjectPropertyScopeInput)
    }
    private static func devices(scope: AudioObjectPropertyScope) -> [AudioOutputDevice] {
        allDevices().compactMap { dev in
            // Match what the macOS Sound menu shows: a device must have streams in
            // this scope AND be eligible as the system default for it. The latter
            // drops virtual routing endpoints (e.g. NoMachine's adapters) that
            // publish a stream but flag themselves as not-selectable.
            guard streamCount(dev, scope: scope) > 0,
                  canBeDefaultDevice(dev, scope: scope),
                  let uid = uid(of: dev) else { return nil }
            return AudioOutputDevice(id: dev, uid: uid, name: name(of: dev))
        }
    }

    /// Whether the device advertises itself as eligible to be the system default
    /// device for `scope` (`kAudioDevicePropertyDeviceCanBeDefaultDevice`). This is
    /// the same gate the macOS Sound menu applies.
    static func canBeDefaultDevice(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        // If the property is absent, don't filter the device out.
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return true }
        return value != 0
    }

    public static func defaultOutputDevice() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }
    public static func defaultInputDevice() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    public static func defaultOutputDeviceUID() -> String? {
        guard let dev = defaultOutputDevice() else { return nil }
        return uid(of: dev)
    }

    /// Make `device` the system default output. Reversible.
    @discardableResult
    public static func setDefaultOutputDevice(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
    }

    /// Create a **Multi-Output Device** (a "stacked" aggregate) that mirrors
    /// output to `mainDeviceUID` (the clock master / what you keep hearing) and
    /// `otherDeviceUID`. Returns its AudioDeviceID.
    public static func createMultiOutput(name: String, uid: String,
                                         mainDeviceUID: String, otherDeviceUID: String) -> AudioDeviceID? {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsStackedKey: 1,          // 1 => Multi-Output (mirrors to all)
            kAudioAggregateDeviceIsPrivateKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: mainDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: mainDeviceUID],
                [kAudioSubDeviceUIDKey: otherDeviceUID],
            ],
        ]
        var aggregate = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        return (status == noErr && aggregate != 0) ? aggregate : nil
    }

    public static func destroyAggregate(_ device: AudioDeviceID) {
        _ = AudioHardwareDestroyAggregateDevice(device)
    }

    /// Create a **private aggregate** (NOT stacked/multi-output) that exposes the
    /// union of its sub-devices' streams under one clock. Used by the mic monitor:
    /// the sub-list is `[mics… , output]`, so the mic input channels form a
    /// contiguous block at the start of the aggregate's input scope. `masterUID`
    /// is the clock master (the output device); every other sub-device is
    /// drift-compensated to follow it. Private => never shown in other apps.
    public static func createAggregate(name: String, uid: String, masterUID: String,
                                       subDeviceUIDs: [String]) -> AudioDeviceID? {
        let subList: [[String: Any]] = subDeviceUIDs.map { sub in
            [kAudioSubDeviceUIDKey: sub,
             kAudioSubDeviceDriftCompensationKey: sub == masterUID ? 0 : 1]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsStackedKey: 0,          // 0 => real aggregate
            kAudioAggregateDeviceIsPrivateKey: 1,          // hidden from other apps
            kAudioAggregateDeviceMainSubDeviceKey: masterUID,
            kAudioAggregateDeviceSubDeviceListKey: subList,
        ]
        var aggregate = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        return (status == noErr && aggregate != 0) ? aggregate : nil
    }

    /// Number of channels a device exposes in the given scope (summed across all
    /// its streams), via the stream configuration buffer list.
    public static func channelCount(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let abl = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { abl.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, abl) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(abl.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func inputChannelCount(of device: AudioDeviceID) -> Int {
        channelCount(of: device, scope: kAudioObjectPropertyScopeInput)
    }
    public static func outputChannelCount(of device: AudioDeviceID) -> Int {
        channelCount(of: device, scope: kAudioObjectPropertyScopeOutput)
    }

    /// Request a small hardware buffer for low latency (best-effort; the device
    /// clamps to its supported range).
    @discardableResult
    public static func setBufferFrameSize(_ frames: UInt32, of device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = frames
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &device)
        }
        return (status == noErr && device != AudioDeviceID(kAudioObjectUnknown)) ? device : nil
    }

    // MARK: Internals

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return (status == noErr && device != 0) ? device : nil
    }

    static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func streamCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    public static func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    @discardableResult
    public static func setNominalSampleRate(_ rate: Double, of device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = Float64(rate)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }

    public static func uid(of device: AudioDeviceID) -> String? {
        cfStringProperty(device, kAudioDevicePropertyDeviceUID)
    }
    public static func name(of device: AudioDeviceID) -> String {
        cfStringProperty(device, kAudioObjectPropertyName) ?? "Unknown"
    }

    private static func cfStringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? (value as String) : nil
    }
}
