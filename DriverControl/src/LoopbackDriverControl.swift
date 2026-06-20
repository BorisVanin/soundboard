import Foundation
import CoreAudio

/// Client-side API for controlling the Soundboard loopback driver from any
/// process. The driver lives in coreaudiod's out-of-process helper, so all
/// control goes through the public Core Audio HAL property API addressed to the
/// device object, using the custom selectors the driver registers.
///
/// This is the counterpart of `SoundboardControlProtocol.h` on the driver side —
/// the selector value MUST stay in sync with it.
public enum LoopbackDriverControl {

    /// Persistent UID of the Soundboard device (matches `kSoundboardDeviceUID`).
    public static let deviceUID = "ca.borisvanin.soundboard.device"

    /// Custom property selector `'sblv'` (matches `kSoundboardCustomProperty_Levels`).
    static let levelsSelector = AudioObjectPropertySelector(0x73626C76)

    /// Output level meters (0…1): current L/R and peak-hold L/R.
    public struct Levels: Equatable, Sendable {
        public var left: Float, right: Float
        public var peakLeft: Float, peakRight: Float
        public init(left: Float = 0, right: Float = 0, peakLeft: Float = 0, peakRight: Float = 0) {
            self.left = left; self.right = right
            self.peakLeft = peakLeft; self.peakRight = peakRight
        }
    }

    public enum ControlError: Error, CustomStringConvertible {
        case deviceNotFound
        case osStatus(OSStatus)
        public var description: String {
            switch self {
            case .deviceNotFound: return "Soundboard device not found (is the driver installed?)"
            case let .osStatus(status): return "Core Audio error \(status)"
            }
        }
    }

    // MARK: Public API

    /// True when the driver is installed and the device is present.
    public static var isAvailable: Bool { (try? deviceID()) != nil }

    /// Current output level meters, or nil if the device isn't available.
    public static func levels() -> Levels? {
        guard let device = try? deviceID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: levelsSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let data = unmanaged?.takeRetainedValue(),
              CFDataGetLength(data) >= 16 else { return nil }
        var floats = [Float32](repeating: 0, count: 4)
        floats.withUnsafeMutableBytes { raw in
            CFDataGetBytes(data, CFRange(location: 0, length: 16), raw.bindMemory(to: UInt8.self).baseAddress)
        }
        return Levels(left: floats[0], right: floats[1], peakLeft: floats[2], peakRight: floats[3])
    }

    // MARK: Lookup

    /// Resolve the device's `AudioDeviceID` from its persistent UID.
    public static func deviceID() throws -> AudioDeviceID {
        var cfUID = deviceUID as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr,
                &size, &deviceID
            )
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw ControlError.deviceNotFound
        }
        return deviceID
    }
}
