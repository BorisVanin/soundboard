import Foundation

/// Which output the app targets. `.systemDefault` follows the current default
/// output; `.device` pins a specific device by UID.
public enum OutputSelection: Hashable, Codable, Sendable {
    case systemDefault
    case device(uid: String)

    public var deviceUID: String? {
        if case let .device(uid) = self { return uid }
        return nil
    }
}

/// Persisted level + mute for one control line, keyed by a stable line key.
public struct ChannelSetting: Codable, Sendable {
    public var level: Float
    public var isMuted: Bool
    public init(level: Float = 0.75, isMuted: Bool = false) {
        self.level = level
        self.isMuted = isMuted
    }
}

/// Everything that should survive an app restart. (MIDI assignments are persisted
/// separately, per control line, via `AssignmentStore`.)
public struct PersistedConfig: Codable, Sendable {
    /// UID of the first (listening) sub-device of the multi-output.
    public var firstOutputUID: String?
    /// Per-line level + mute, keyed by a stable line key ("mic"/"loopback"/"output").
    public var channels: [String: ChannelSetting]
    /// Remembered Output (listening device) volume per device UID.
    public var outputVolumes: [String: Float]
    /// UID of the selected microphone (input) device; nil = system default.
    public var inputUID: String?
    /// UID of the microphone being rendered ("monitored") to the output.
    /// nil = "None" (the mic is released, no recording indicator).
    public var monitorMicUID: String?
    /// Last non-None mic, so a MIDI toggle can re-engage it after "None".
    public var monitorLastMicUID: String?
    /// Channel indices (per mic UID) enabled for rendering.
    public var monitorChannels: [String: [Int]]
    /// Whether the live audio-level meters are shown.
    public var showLevels: Bool
    /// Whether the mix is being played to a monitoring output device.
    public var monitorEnabled: Bool
    /// UID of the output device the mix is monitored on; nil = system default.
    public var monitorOutputUID: String?
    /// Linear 0…1 monitoring volume.
    public var monitorOutputVolume: Float
    /// Whether the main window was open when the app last quit. When false, the app
    /// launches as a menu-bar agent without opening the window.
    public var mainWindowOpen: Bool

    public init(
        firstOutputUID: String? = nil,
        channels: [String: ChannelSetting] = [:],
        outputVolumes: [String: Float] = [:],
        inputUID: String? = nil,
        monitorMicUID: String? = nil,
        monitorLastMicUID: String? = nil,
        monitorChannels: [String: [Int]] = [:],
        showLevels: Bool = true,
        monitorEnabled: Bool = false,
        monitorOutputUID: String? = nil,
        monitorOutputVolume: Float = 0.5,
        mainWindowOpen: Bool = true
    ) {
        self.firstOutputUID = firstOutputUID
        self.channels = channels
        self.outputVolumes = outputVolumes
        self.inputUID = inputUID
        self.monitorMicUID = monitorMicUID
        self.monitorLastMicUID = monitorLastMicUID
        self.monitorChannels = monitorChannels
        self.showLevels = showLevels
        self.monitorEnabled = monitorEnabled
        self.monitorOutputUID = monitorOutputUID
        self.monitorOutputVolume = monitorOutputVolume
        self.mainWindowOpen = mainWindowOpen
    }

    // Tolerant of older saved data that lacks the newer keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstOutputUID = try container.decodeIfPresent(String.self, forKey: .firstOutputUID)
        channels = try container.decodeIfPresent([String: ChannelSetting].self, forKey: .channels) ?? [:]
        outputVolumes = try container.decodeIfPresent([String: Float].self, forKey: .outputVolumes) ?? [:]
        inputUID = try container.decodeIfPresent(String.self, forKey: .inputUID)
        monitorMicUID = try container.decodeIfPresent(String.self, forKey: .monitorMicUID)
        monitorLastMicUID = try container.decodeIfPresent(String.self, forKey: .monitorLastMicUID)
        monitorChannels = try container.decodeIfPresent([String: [Int]].self, forKey: .monitorChannels) ?? [:]
        showLevels = try container.decodeIfPresent(Bool.self, forKey: .showLevels) ?? true
        monitorEnabled = try container.decodeIfPresent(Bool.self, forKey: .monitorEnabled) ?? false
        monitorOutputUID = try container.decodeIfPresent(String.self, forKey: .monitorOutputUID)
        monitorOutputVolume = try container.decodeIfPresent(Float.self, forKey: .monitorOutputVolume) ?? 0.5
        mainWindowOpen = try container.decodeIfPresent(Bool.self, forKey: .mainWindowOpen) ?? true
    }
}
