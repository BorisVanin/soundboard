import Foundation
import CoreAudio
import AudioToolbox
import OSLog

/// `SoundLane` for the Mac's **system audio**: a non-muting global Core Audio
/// process tap wrapped in a private aggregate, whose IOProc applies gain, meters
/// the input, and writes interleaved stereo into the lane buffer. The mixer
/// (`MixEngine`) sums it with the mic lane. Adapted from `tools/tap_feed.swift`.
/// Requires macOS 14.4+ (process taps) and the audio-recording TCC grant.
///
/// NOTE: a global tap captures whatever reaches the system output (incl. a call's
/// far-end audio) and is subject to macOS call-ducking — the de-scoped concern.
public final class MacSoundLane: SoundLane {

    private let logger = Logger(subsystem: "ca.borisvanin.soundboard", category: "MacSoundLane")

    private var tapID  = AudioObjectID(kAudioObjectUnknown)
    private var aggID  = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// The output device whose audio we're tapping ("" = all system output). Lets
    /// `start` rebuild only when the chosen source actually changes.
    private var currentSource: String?

    private let gainPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    /// Smoothed gain the IOProc actually applies (the target is `gainPtr`); ramped
    /// per sample to de-zipper fader/mute moves. Written only by the RT IOProc.
    private let smoothPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let meterL = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let meterR = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    public private(set) var meterChannelCount = 0

    public init() { gainPtr.pointee = 1; smoothPtr.pointee = 1; meterL.pointee = 0; meterR.pointee = 0 }
    deinit { stop(); gainPtr.deallocate(); smoothPtr.deallocate(); meterL.deallocate(); meterR.deallocate() }

    public var isRunning: Bool { procID != nil }

    public func setGain(_ gain: Float, muted: Bool) {
        gainPtr.pointee = muted ? 0 : max(0, min(gain, 1))
    }

    public func consumeMeters() -> (count: Int, left: Float, right: Float) {
        let l = meterL.pointee, r = meterR.pointee
        meterL.pointee = 0; meterR.pointee = 0
        return (meterChannelCount, l, r)
    }

    /// `source` is an output-device UID whose audio is tapped, or "" for all system
    /// output. `channels` is ignored (a tap is always stereo). Idempotent for an
    /// unchanged source; rebuilds the tap when the source changes. Scoping the tap to
    /// a device only *reads* that device's audio — it never changes the system output.
    public func start(source: String, channels: [Int], sink: SoundLaneSink) throws {
        guard source != currentSource || procID == nil else { return }
        stop()
        do {
            try build(source: source, sink: sink)
            currentSource = source
            meterChannelCount = 2
            logger.info("MacSoundLane capturing \(source.isEmpty ? "all system output" : source, privacy: .public)")
        } catch {
            stop(); throw error
        }
    }

    public func stop() {
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        currentSource = nil
        meterChannelCount = 0; meterL.pointee = 0; meterR.pointee = 0
    }

    private enum LaneError: Error { case tap(OSStatus), aggregate(OSStatus), ioproc(OSStatus) }

    private func build(source: String, sink: SoundLaneSink) throws {
        // Empty source → global tap (all output). Otherwise tap only the audio
        // destined for the chosen output device's first stream (read-only; the
        // system's default output is left untouched).
        let desc = source.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(__excludingProcesses: [], andDeviceUID: source, withStream: 0)
        desc.name = "Soundboard Mac Lane"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted                        // keep system audio audible
        var tap = AudioObjectID(kAudioObjectUnknown)
        let ts = AudioHardwareCreateProcessTap(desc, &tap)
        guard ts == noErr, tap != kAudioObjectUnknown else { throw LaneError.tap(ts) }
        tapID = tap

        // Unique per-instance UID: the aggregate is a private, ephemeral wrapper for
        // this tap. A fixed UID would collide with a private aggregate left behind by
        // an earlier crashed/killed run (invisible to UID lookup, yet still blocking
        // re-creation → 'nope'), so make every one distinct.
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Soundboard Mac Lane",
            kAudioAggregateDeviceUIDKey as String: "ca.borisvanin.soundboard.maclane." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [
                [ kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                  kAudioSubTapDriftCompensationKey as String: true ]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let asx = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard asx == noErr, agg != kAudioObjectUnknown else { throw LaneError.aggregate(asx) }
        aggID = agg

        // Capture locals for the RT block — pointers only, never `self`.
        let data = sink.data, cap = sink.frameCapacity
        let wIdx = sink.writeIndex, rIdx = sink.readIndex
        smoothPtr.pointee = gainPtr.pointee          // start matched: no ramp on (re)start
        let gp = gainPtr, sp = smoothPtr, mL = meterL, mR = meterR

        var proc: AudioDeviceIOProcID?
        let ps = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { (_, inInputData, _, _, _) in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard abl.count > 0 else { return }
            let buf = abl[0]
            let chans = Int(buf.mNumberChannels)
            guard chans > 0, let mData = buf.mData else { return }
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chans)   // interleaved float
            let src = mData.assumingMemoryBound(to: Float.self)
            let target = gp.pointee
            var g = sp.pointee                       // smoothed gain, ramped per sample

            // Free space in the lane buffer; drop on full (reader priority). Meter every
            // captured frame *post-gain* (so the fader and mute move the VU) regardless of
            // backpressure — only the *write* is gated by `give`, so a full ring can't
            // freeze the VU at zero.
            let w = wIdx.pointee, r = rIdx.pointee
            let give = min(UInt64(frames), cap - (w &- r))
            var lpk = mL.pointee, rpk = mR.pointee
            var i = 0
            while i < frames {
                g += gainSmoothingAlpha * (target - g)             // de-zipper: no gain step
                if abs(target - g) < 1e-6 { g = target }           // settle exactly (no denormals)
                let l  = src[i * chans + 0] * g
                let rr = (chans > 1 ? src[i * chans + 1] : src[i * chans + 0]) * g
                let al = l < 0 ? -l : l; if al > lpk { lpk = al }   // meter post-gain
                let ar = rr < 0 ? -rr : rr; if ar > rpk { rpk = ar }
                if UInt64(i) < give {
                    let pos = Int((w &+ UInt64(i)) & (cap - 1)) * 2
                    data[pos] = l; data[pos + 1] = rr
                }
                i &+= 1
            }
            sp.pointee = g
            mL.pointee = lpk; mR.pointee = rpk
            OSMemoryBarrier()
            wIdx.pointee = w &+ give
        }
        guard ps == noErr, let proc else { throw LaneError.ioproc(ps) }
        procID = proc
        let st = AudioDeviceStart(agg, proc)
        guard st == noErr else { throw LaneError.ioproc(st) }
    }
}
