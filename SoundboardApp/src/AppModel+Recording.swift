import Foundation
import AppKit

@MainActor
extension AppModel {

    // MARK: - Recording (the output mix → a .wav file)

    /// Toggle recording from the UI (drives the same assignable control as MIDI).
    func toggleRecording() { recordControl.press() }

    /// Record the finished mix — the same stream fed to the Soundboard loopback driver
    /// and the monitor — to a .wav file (a tee inside `MixEngine`, not a device round-trip).
    func startRecording() {
        guard !isRecording else { return }
        let url = Self.makeRecordingURL()
        do {
            try mixEngine.startRecording(to: url)
            lastRecordingURL = url
            isRecording = true
        } catch {
            recordLog.error("Failed to start recording: \(String(describing: error))")
            isRecording = false
            recordControl.setSilently(on: false)   // revert the toggle without re-firing
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        mixEngine.stopRecording()
        isRecording = false
        if let url = lastRecordingURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// `~/Music/Soundboard/Soundboard YYYY-MM-DD HH.mm.ss.wav` (folder created lazily).
    static func makeRecordingURL() -> URL {
        let base = (FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Soundboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return base.appendingPathComponent("Soundboard \(fmt.string(from: Date())).wav")
    }
}
