import Foundation
import CoreAudio
import AudioToolbox
import OSLog

/// Plays the finished mix to a user-chosen output device so the operator can
/// **monitor** what Soundboard is sending. *All* monitor audio lives here:
///   • an output AUHAL unit on the selected device (it resamples our canonical
///     48 kHz client format to whatever the device runs at),
///   • a lock-free SPSC stereo-float ring the mixer pushes the mix into
///     (`enqueue`, RT-safe, drop-on-full),
///   • a render callback that drains the ring (silence on underrun) and applies a
///     volume scalar.
/// It knows nothing about the shmem ring, the lanes, or the driver — `MixEngine`
/// just tees the same buffer it writes to the ring into `enqueue`.
public final class MixMonitor {

    private let logger = Logger(subsystem: "ca.borisvanin.soundboard", category: "MixMonitor")

    private static let ringFrames = 8192          // ~170 ms @ 48k, power of two
    private static let canonicalRate = 48_000.0

    // SPSC stereo-float ring. Producer = the mixer tick (`enqueue`); consumer = the
    // output unit's RT render thread. Memory is allocated for the monitor's whole
    // life and never freed on start/stop, so `enqueue` can run concurrently with a
    // teardown without ever touching freed storage (it is gated only by `enabled`).
    private let ringData: UnsafeMutablePointer<Float>
    private let wIdx = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private let rIdx = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private let volumePtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    /// 1 while the output unit is running and draining the ring; 0 otherwise. The
    /// producer checks it before writing — when nobody drains we don't accumulate.
    private let enabledPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    private var unit: AudioUnit?
    private var ctx: UnsafeMutablePointer<MonitorContext>?
    private var currentDeviceUID: String?

    public init() {
        ringData = .allocate(capacity: Self.ringFrames * 2)
        ringData.initialize(repeating: 0, count: Self.ringFrames * 2)
        wIdx.pointee = 0; rIdx.pointee = 0
        volumePtr.pointee = 0.5
        enabledPtr.pointee = 0
    }

    deinit {
        stop()
        ringData.deallocate(); wIdx.deallocate(); rIdx.deallocate()
        volumePtr.deallocate(); enabledPtr.deallocate()
    }

    // MARK: - Public surface

    public var isRunning: Bool { unit != nil }

    /// Linear 0…1 monitor volume. RT-safe (a single store, read in the callback).
    public func setVolume(_ value: Float) { volumePtr.pointee = max(0, min(value, 1)) }

    /// Start (or re-point) monitoring to `deviceUID`. Idempotent for an unchanged
    /// device. Throws if the device can't be opened.
    public func start(deviceUID: String) throws {
        guard deviceUID != currentDeviceUID || unit == nil else { return }
        stop()
        do {
            try build(deviceUID: deviceUID)
            currentDeviceUID = deviceUID
            logger.info("MixMonitor playing the mix to \(deviceUID, privacy: .public)")
        } catch {
            stop(); throw error
        }
    }

    public func stop() {
        // Gate the producer *first* (with a barrier), then stop the consumer.
        enabledPtr.pointee = 0
        OSMemoryBarrier()
        if let audioUnit = unit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        unit = nil
        if let context = ctx { context.deallocate(); ctx = nil }
        currentDeviceUID = nil
    }

    /// Mixer producer (called from the mix tick): copy `frames` interleaved-stereo
    /// frames into the ring; drop on full (the output has reader priority). Touches
    /// only lifetime-stable ring storage, so it is safe against a concurrent `stop`.
    public func enqueue(_ src: UnsafePointer<Float>, frames: Int) {
        guard enabledPtr.pointee != 0, frames > 0 else { return }
        let cap = UInt64(Self.ringFrames)
        let writePos = wIdx.pointee, readPos = rIdx.pointee
        let give = Int(min(UInt64(frames), cap &- (writePos &- readPos)))
        guard give > 0 else { return }
        let mask = cap - 1
        var done = 0
        var cursor = writePos
        while done < give {
            let pos = Int(cursor & mask)
            let seg = min(give - done, Self.ringFrames - pos)
            (ringData + pos * 2).update(from: src + done * 2, count: seg * 2)
            cursor &+= UInt64(seg); done += seg
        }
        OSMemoryBarrier()
        wIdx.pointee = cursor
    }

    // MARK: - Build

    private enum MonitorError: Error { case noDevice, audioUnit(OSStatus) }
    private func check(_ status: OSStatus) throws { if status != noErr { throw MonitorError.audioUnit(status) } }

    private func build(deviceUID: String) throws {
        guard let devID = AudioDevices.deviceID(forUID: deviceUID) else { throw MonitorError.noDevice }

        let audioUnit = try makeHALUnit()
        unit = audioUnit
        var enableOut: UInt32 = 1, disableIn: UInt32 = 0
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                       &enableOut, UInt32(MemoryLayout<UInt32>.size)))
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                       &disableIn, UInt32(MemoryLayout<UInt32>.size)))
        var dev = devID
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)))
        // Canonical 48k stereo client format on the input scope (the data we feed);
        // the AUHAL resamples it to the device's rate, so a device reconfig is absorbed.
        var fmt = Self.format()
        try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        // Flush any stale frames while the producer is still gated (enabled == 0).
        rIdx.pointee = 0; wIdx.pointee = 0

        let context = UnsafeMutablePointer<MonitorContext>.allocate(capacity: 1)
        context.pointee = MonitorContext(ringData: ringData, frameMask: UInt64(Self.ringFrames) - 1,
                                         writeIdx: wIdx, readIdx: rIdx, volume: volumePtr)
        ctx = context

        var callback = AURenderCallbackStruct(inputProc: monitorRenderCallback,
                                              inputProcRefCon: UnsafeMutableRawPointer(context))
        try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check(AudioUnitInitialize(audioUnit))
        try check(AudioOutputUnitStart(audioUnit))

        OSMemoryBarrier()
        enabledPtr.pointee = 1     // open the producer gate last, ring already flushed
    }

    private func makeHALUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw MonitorError.noDevice }
        var audioUnit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &audioUnit))
        guard let audioUnit else { throw MonitorError.noDevice }
        return audioUnit
    }

    private static func format() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: canonicalRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,   // interleaved stereo
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }
}

// MARK: - Realtime render context + callback

struct MonitorContext {
    var ringData: UnsafeMutablePointer<Float>
    var frameMask: UInt64
    var writeIdx: UnsafeMutablePointer<UInt64>
    var readIdx: UnsafeMutablePointer<UInt64>
    var volume: UnsafeMutablePointer<Float>
}

/// Output render callback: drain up to `inNumberFrames` interleaved-stereo frames
/// from the ring (acquire the producer's `writeIdx`), apply volume, zero-fill any
/// underrun, then publish the advanced `readIdx`. No locks, no allocation.
private let monitorRenderCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    let ctx = inRefCon.assumingMemoryBound(to: MonitorContext.self).pointee
    guard let ioData else { return noErr }
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    guard abl.count > 0, let out = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

    let frames = Int(inNumberFrames)
    let vol = ctx.volume.pointee
    let mask = ctx.frameMask
    let readPos = ctx.readIdx.pointee
    let writePos = ctx.writeIdx.pointee
    let give = min(frames, Int(writePos &- readPos))

    var index = 0
    var cursor = readPos
    while index < give {
        let pos = Int(cursor & mask) * 2
        out[index * 2]     = ctx.ringData[pos] * vol
        out[index * 2 + 1] = ctx.ringData[pos + 1] * vol
        cursor &+= 1; index += 1
    }
    while index < frames {                       // underrun → silence
        out[index * 2] = 0; out[index * 2 + 1] = 0; index += 1
    }
    OSMemoryBarrier()
    ctx.readIdx.pointee = readPos &+ UInt64(give)
    return noErr
}
