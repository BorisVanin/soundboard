import Foundation
import MixerEngine

@MainActor
extension AppModel {

    // MARK: - Timers / meters

    func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refreshOutputs(); self?.refreshInputs()
            }
        }
    }
    func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollLevels() }
        }
    }
    func stopMeterTimer() {
        meterTimer?.invalidate(); meterTimer = nil
        micMeter = []; micSmoothed = []; macMeter = []; macSmoothed = []
    }

    // MARK: - Play/pause state (transport button icon)

    /// Poll the "is any process producing output" signal every 0.5 s while the main
    /// window (and its transport button) is visible. Deliberately a bounded poll,
    /// not CoreAudio property listeners: those fire per-process on the main actor
    /// and, under load, can flood it and starve MIDI handling (which also hops to
    /// the main actor). Two cheap reads per second can't. Stopped when the window
    /// closes — the icon isn't shown then, so there's nothing to keep fresh.
    func windowBecameVisible() {
        playingPollTimer?.invalidate()
        updateIsPlaying()
        playingPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.updateIsPlaying() }
        }
        setMainWindowOpen(true)
    }

    func windowBecameHidden() {
        playingPollTimer?.invalidate(); playingPollTimer = nil
        // Don't record a close that's just the app quitting with the window open.
        if !isTerminating { setMainWindowOpen(false) }
    }

    /// Persist the window's open/closed state so it can be restored at next launch.
    func setMainWindowOpen(_ open: Bool) {
        guard isLoaded, open != mainWindowOpen else { return }
        mainWindowOpen = open
        saveNow()
    }

    func updateIsPlaying() {
        guard #available(macOS 14.2, *) else { return }
        let playing = !AudioProcesses.runningOutput().isEmpty
        if playing != isPlaying { isPlaying = playing }
    }
    func smooth(_ raw: [Float], into old: [Float]) -> [Float] {
        raw.enumerated().map { index, value in
            let prev = index < old.count ? old[index] : 0
            return max(min(value, 1), prev * 0.80)
        }
    }
    /// Per-segment lower thresholds in dBFS, bottom → top. A segment lights when the
    /// (smoothed) peak reaches its threshold. dB spacing matches perceived loudness
    /// far better than a linear split — the top two are the yellow/red headroom band.
    static let meterThresholdsDB: [Float] = [-42, -36, -30, -24, -18, -10, -3]
    static var meterSegmentCount: Int { meterThresholdsDB.count }
    static let meterThresholdsLinear: [Float] = meterThresholdsDB.map { powf(10, $0 / 20) }

    /// How many segments a linear-amplitude peak lights (0…segmentCount).
    static func litSegments(_ level: Float) -> Int {
        let value = min(max(level, 0), 1)
        var count = 0
        for threshold in meterThresholdsLinear where value >= threshold { count += 1 }
        return count
    }

    static func segments(_ levels: [Float]) -> [Int] { levels.map(litSegments) }

    /// Assign a meter only if its segment-quantized form changed; otherwise the
    /// stored value (and the views observing it) stay put — no redraw.
    func publishMeter(_ value: [Float], to keyPath: ReferenceWritableKeyPath<AppModel, [Float]>) {
        if Self.segments(value) != Self.segments(self[keyPath: keyPath]) {
            self[keyPath: keyPath] = value
        }
    }

    func pollLevels() {
        let meters = mixEngine.consumeMicMeters()
        let micRaw: [Float] = meters.count == 0
            ? []
            : (meters.count == 1 ? [meters.left] : [meters.left, meters.right])
        micSmoothed = smooth(micRaw, into: micSmoothed)
        publishMeter(micSmoothed, to: \.micMeter)

        let mac = mixEngine.consumeMacMeters()
        let macRaw: [Float] = mac.count == 0 ? [] : (mac.count == 1 ? [mac.left] : [mac.left, mac.right])
        macSmoothed = smooth(macRaw, into: macSmoothed)
        publishMeter(macSmoothed, to: \.macMeter)
    }
}
