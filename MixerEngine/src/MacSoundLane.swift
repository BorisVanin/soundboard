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

    public func consumeMeters() -> LaneMeters {
        let left = meterL.pointee, right = meterR.pointee
        meterL.pointee = 0; meterR.pointee = 0
        return LaneMeters(count: meterChannelCount, left: left, right: right)
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
        if let proc = procID {
            AudioDeviceStop(aggID, proc); AudioDeviceDestroyIOProcID(aggID, proc); procID = nil
        }
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown)
        }
        currentSource = nil
        meterChannelCount = 0; meterL.pointee = 0; meterR.pointee = 0
    }

    private enum LaneError: Error { case tap(OSStatus), aggregate(OSStatus), ioproc(OSStatus) }

    /// Pointers captured by the RT IOProc — bundled so the render path stays `self`-free.
    private struct RenderContext {
        let data: UnsafeMutablePointer<Float>
        let cap: UInt64
        let writeIdx: UnsafeMutablePointer<UInt64>
        let readIdx: UnsafeMutablePointer<UInt64>
        let gainTarget: UnsafeMutablePointer<Float>
        let smoothed: UnsafeMutablePointer<Float>
        let peakL: UnsafeMutablePointer<Float>
        let peakR: UnsafeMutablePointer<Float>
    }

    private func build(source: String, sink: SoundLaneSink) throws {
        let desc = try createTap(source: source)
        let agg = try createAggregate(tapUID: desc.uuid.uuidString)

        // Capture locals for the RT block — pointers only, never `self`.
        smoothPtr.pointee = gainPtr.pointee          // start matched: no ramp on (re)start
        let ctx = RenderContext(
            data: sink.data, cap: sink.frameCapacity,
            writeIdx: sink.writeIndex, readIdx: sink.readIndex,
            gainTarget: gainPtr, smoothed: smoothPtr, peakL: meterL, peakR: meterR
        )

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { (_, inInputData, _, _, _) in
            MacSoundLane.renderBlock(inInputData: inInputData, ctx: ctx)
        }
        guard procStatus == noErr, let proc else { throw LaneError.ioproc(procStatus) }
        procID = proc
        let startStatus = AudioDeviceStart(agg, proc)
        guard startStatus == noErr else { throw LaneError.ioproc(startStatus) }
    }

    /// Creates the process tap. Empty source → global tap (all output). Otherwise tap
    /// only the audio destined for the chosen output device's first stream (read-only;
    /// the system's default output is left untouched). Stores the new ID in `tapID`.
    private func createTap(source: String) throws -> CATapDescription {
        let desc = source.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(__excludingProcesses: [], andDeviceUID: source, withStream: 0)
        desc.name = "Soundboard Mac Lane"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted                        // keep system audio audible
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw LaneError.tap(status) }
        tapID = tap
        return desc
    }

    /// Creates the private aggregate that wraps the tap and stores its ID in `aggID`.
    ///
    /// Unique per-instance UID: the aggregate is a private, ephemeral wrapper for this
    /// tap. A fixed UID would collide with a private aggregate left behind by an earlier
    /// crashed/killed run (invisible to UID lookup, yet still blocking re-creation →
    /// 'nope'), so make every one distinct.
    private func createAggregate(tapUID: String) throws -> AudioObjectID {
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Soundboard Mac Lane",
            kAudioAggregateDeviceUIDKey as String: "ca.borisvanin.soundboard.maclane." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [
                [ kAudioSubTapUIDKey as String: tapUID,
                  kAudioSubTapDriftCompensationKey as String: true ]
            ]
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard status == noErr, agg != kAudioObjectUnknown else { throw LaneError.aggregate(status) }
        aggID = agg
        return agg
    }

    /// RT IOProc body: applies smoothed gain, meters post-gain, and writes interleaved
    /// stereo into the lane ring. Pure function over pointers — no `self`, no allocation.
    private static func renderBlock(inInputData: UnsafePointer<AudioBufferList>, ctx: RenderContext) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard abl.count > 0 else { return }
        let buf = abl[0]
        let chans = Int(buf.mNumberChannels)
        guard chans > 0, let mData = buf.mData else { return }
        let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chans)   // interleaved float
        let src = mData.assumingMemoryBound(to: Float.self)
        let target = ctx.gainTarget.pointee
        var gain = ctx.smoothed.pointee              // smoothed gain, ramped per sample

        // Free space in the lane buffer; drop on full (reader priority). Meter every
        // captured frame *post-gain* (so the fader and mute move the VU) regardless of
        // backpressure — only the *write* is gated by `give`, so a full ring can't
        // freeze the VU at zero.
        let writePos = ctx.writeIdx.pointee, readPos = ctx.readIdx.pointee
        let give = min(UInt64(frames), ctx.cap - (writePos &- readPos))
        var leftPeak = ctx.peakL.pointee, rightPeak = ctx.peakR.pointee
        var index = 0
        while index < frames {
            gain += gainSmoothingAlpha * (target - gain)        // de-zipper: no gain step
            if abs(target - gain) < 1e-6 { gain = target }      // settle exactly (no denormals)
            let left  = src[index * chans + 0] * gain
            let right = (chans > 1 ? src[index * chans + 1] : src[index * chans + 0]) * gain
            let absLeft = left < 0 ? -left : left; if absLeft > leftPeak { leftPeak = absLeft }
            let absRight = right < 0 ? -right : right; if absRight > rightPeak { rightPeak = absRight }
            if UInt64(index) < give {
                let pos = Int((writePos &+ UInt64(index)) & (ctx.cap - 1)) * 2
                ctx.data[pos] = left; ctx.data[pos + 1] = right
            }
            index &+= 1
        }
        ctx.smoothed.pointee = gain
        ctx.peakL.pointee = leftPeak; ctx.peakR.pointee = rightPeak
        OSMemoryBarrier()
        ctx.writeIdx.pointee = writePos &+ give
    }
}
