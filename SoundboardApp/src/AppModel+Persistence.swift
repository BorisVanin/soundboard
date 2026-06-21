import Foundation
import MixerModel

@MainActor
extension AppModel {

    // MARK: - Persistence (levels/mutes/device/mic; MIDI maps live in AssignmentStore)

    static func loadConfig() -> PersistedConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let cfg = try? JSONDecoder().decode(PersistedConfig.self, from: data) else {
            return PersistedConfig()
        }
        return cfg
    }
    func currentConfig() -> PersistedConfig {
        let channels: [String: ChannelSetting] = [
            "mic": .init(level: micLevel.rawValue, isMuted: micMute.isOn),
            "mac": .init(level: macLevel.rawValue, isMuted: macMute.isOn),
            "monitor": .init(level: monitorLevel.rawValue, isMuted: monitorMute.isOn)
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
    func saveNow() {
        guard isLoaded else { return }
        if let data = try? JSONEncoder().encode(currentConfig()) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Whether to open the main window at launch — false when it was closed at the
    /// previous quit, so the app comes up as a menu-bar agent. Read by `AppDelegate`
    /// straight from the persisted config (no instance needed).
    static func shouldOpenMainWindowAtLaunch() -> Bool { loadConfig().mainWindowOpen }
}
