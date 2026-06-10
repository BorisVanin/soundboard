import Foundation
import CoreAudio
import AppKit

/// A process that is currently producing audio output.
public struct AudioProcessInfo: Hashable, Sendable {
    public let pid: pid_t
    public let bundleID: String?
    public let name: String
}

/// Enumerates the system's audio-producing processes (macOS 14.2+ taps API).
public enum AudioProcesses {

    @available(macOS 14.2, *)
    public static func runningOutput() -> [AudioProcessInfo] {
        processObjects().compactMap { obj in
            guard boolProperty(obj, kAudioProcessPropertyIsRunningOutput) else { return nil }
            let pid = pidProperty(obj)
            let bundleID = cfStringProperty(obj, kAudioProcessPropertyBundleID)
            let name = displayName(pid: pid, bundleID: bundleID)
            // Skip our own process and anything we can't identify.
            guard pid != ProcessInfo.processInfo.processIdentifier, name != nil || bundleID != nil else { return nil }
            return AudioProcessInfo(pid: pid, bundleID: bundleID, name: name ?? bundleID ?? "pid \(pid)")
        }
    }

    // MARK: Internals

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func boolProperty(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func pidProperty(_ obj: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value)
        return value
    }

    private static func cfStringProperty(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &address, 0, nil, &size, $0) }
        let s = value as String
        return (status == noErr && !s.isEmpty) ? s : nil
    }

    private static func displayName(pid: pid_t, bundleID: String?) -> String? {
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
        if let bundleID { return bundleID.components(separatedBy: ".").last }
        return nil
    }
}
