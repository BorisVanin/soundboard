import Foundation
import CoreAudio
import AudioToolbox
import OSLog

/// `SoundLane` for a microphone: an input-only AUHAL unit on the selected mic,
/// rendering at a fixed 48 kHz client format, summing the chosen channels to mono,
/// applying gain, metering the (pre-gain) input, and writing interleaved stereo
/// into the sink (the driver mix ring). Extracted from `MixEngine` so the capture
/// and the ring are fully decoupled (see `SoundLane`).
public final class MicSoundLane: SoundLane {

    private let logger = Logger(subsystem: "ca.borisvanin.soundboard", category: "MicSoundLane")
    private static let maxFrames = 4096

    private var captureUnit: AudioUnit?
    private var captureABL: UnsafeMutableAudioBufferListPointer?
    private var captureCtx: UnsafeMutablePointer<MicCaptureContext>?
    private var currentSource: String?
    private var currentChannels: [Int] = []

    private let gainPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let meterL = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let meterR = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    public private(set) var meterChannelCount = 0

    public init() { gainPtr.pointee = 1; meterL.pointee = 0; meterR.pointee = 0 }
    deinit { stop(); gainPtr.deallocate(); meterL.deallocate(); meterR.deallocate() }

    public var isRunning: Bool { captureUnit != nil }

    public func setGain(_ gain: Float, muted: Bool) {
        gainPtr.pointee = muted ? 0 : max(0, min(gain, 1))
    }

    public func consumeMeters() -> (count: Int, left: Float, right: Float) {
        let l = meterL.pointee, r = meterR.pointee
        meterL.pointee = 0; meterR.pointee = 0
        return (meterChannelCount, l, r)
    }

    public func start(source: String, channels: [Int], sink: SoundLaneSink) throws {
        let chans = channels.sorted()
        guard source != currentSource || chans != currentChannels || captureUnit == nil else { return }
        stop()
        do {
            try build(source: source, channels: chans, sink: sink)
            currentSource = source; currentChannels = chans
            logger.info("MicSoundLane capturing \(chans.count) ch of \(source)")
        } catch {
            stop(); throw error
        }
    }

    public func stop() {
        if let au = captureUnit { AudioOutputUnitStop(au); AudioUnitUninitialize(au); AudioComponentInstanceDispose(au) }
        captureUnit = nil
        if let abl = captureABL { for b in abl { b.mData?.deallocate() }; free(abl.unsafeMutablePointer) }
        captureABL = nil
        if let c = captureCtx { c.pointee.channels?.deallocate(); c.deallocate() }
        captureCtx = nil
        currentSource = nil; currentChannels = []
        meterChannelCount = 0; meterL.pointee = 0; meterR.pointee = 0
    }

    // MARK: - Build

    private enum LaneError: Error { case noDevice, noChannels, audioUnit(OSStatus) }
    private func check(_ status: OSStatus) throws { if status != noErr { throw LaneError.audioUnit(status) } }

    private func build(source micUID: String, channels: [Int], sink: SoundLaneSink) throws {
        guard let micID = AudioDevices.deviceID(forUID: micUID) else { throw LaneError.noDevice }
        let micChannels = AudioDevices.inputChannelCount(of: micID)
        guard micChannels > 0 else { throw LaneError.noChannels }
        let wanted = channels.filter { $0 >= 0 && $0 < micChannels }
        guard !wanted.isEmpty else { throw LaneError.noChannels }

        let au = try makeHALUnit()
        captureUnit = au
        var enable: UInt32 = 1, disable: UInt32 = 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)))
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)))
        var micDev = micID
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &micDev, UInt32(MemoryLayout<AudioDeviceID>.size)))
        var maxF = UInt32(Self.maxFrames)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxF, UInt32(MemoryLayout<UInt32>.size)))
        // Fixed 48k client format: the AUHAL resamples the mic into it, so we always
        // feed the ring's canonical rate and a device-side reconfig can't resize us.
        var inFmt = Self.format(rate: 48_000, channels: micChannels)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inFmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        let abl = AudioBufferList.allocate(maximumBuffers: micChannels)
        for i in 0..<micChannels {
            let data = UnsafeMutableRawPointer.allocate(byteCount: Self.maxFrames * MemoryLayout<Float>.size, alignment: 16)
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Self.maxFrames * MemoryLayout<Float>.size), mData: data)
        }
        captureABL = abl

        let chanPtr = UnsafeMutablePointer<Int32>.allocate(capacity: wanted.count)
        for (i, c) in wanted.enumerated() { chanPtr[i] = Int32(c) }
        let ctx = UnsafeMutablePointer<MicCaptureContext>.allocate(capacity: 1)
        ctx.pointee = MicCaptureContext(
            unit: au, inputABL: abl.unsafeMutablePointer, maxFrames: Int32(Self.maxFrames),
            micChannels: Int32(micChannels), channels: chanPtr, channelCount: Int32(wanted.count),
            gain: gainPtr, meterL: meterL, meterR: meterR,
            ringData: sink.data, frameMask: sink.frameCapacity - 1, frameCapacity: sink.frameCapacity,
            writeIdx: sink.writeIndex, readIdx: sink.readIndex)
        captureCtx = ctx
        meterChannelCount = wanted.count >= 2 ? 2 : 1

        var inCb = AURenderCallbackStruct(inputProc: micCaptureCallback, inputProcRefCon: UnsafeMutableRawPointer(ctx))
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inCb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check(AudioUnitInitialize(au))
        try check(AudioOutputUnitStart(au))
    }

    private func makeHALUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw LaneError.noDevice }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au))
        guard let au else { throw LaneError.noDevice }
        return au
    }

    private static func format(rate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }
}

// MARK: - Realtime capture context + callback

struct MicCaptureContext {
    var unit: AudioUnit
    var inputABL: UnsafeMutablePointer<AudioBufferList>
    var maxFrames: Int32
    var micChannels: Int32
    var channels: UnsafeMutablePointer<Int32>?
    var channelCount: Int32
    var gain: UnsafeMutablePointer<Float>
    var meterL: UnsafeMutablePointer<Float>
    var meterR: UnsafeMutablePointer<Float>
    var ringData: UnsafeMutablePointer<Float>
    var frameMask: UInt64
    var frameCapacity: UInt64
    var writeIdx: UnsafeMutablePointer<UInt64>
    var readIdx: UnsafeMutablePointer<UInt64>
}

/// Mic input callback: render the mic, sum the selected channels to mono, apply
/// gain, meter the *post-gain* input (so the fader and mute move the VU), write the
/// result as interleaved stereo into the lane buffer (lock-free SPSC, drop-on-full),
/// then advance writeIndex. The mixer (MixEngine) reads this buffer; the heartbeat
/// lives there.
private let micCaptureCallback: AURenderCallback = {
    inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let ctx = inRefCon.assumingMemoryBound(to: MicCaptureContext.self).pointee
    let frames = Int(inNumberFrames)
    if frames > Int(ctx.maxFrames) { return noErr }
    let bytes = frames * MemoryLayout<Float>.size

    let inABL = UnsafeMutableAudioBufferListPointer(ctx.inputABL)
    let chCount = Int(ctx.micChannels)
    for i in 0..<chCount { inABL[i].mDataByteSize = UInt32(bytes) }
    var flags = ioActionFlags.pointee
    if AudioUnitRender(ctx.unit, &flags, inTimeStamp, 1, inNumberFrames, ctx.inputABL) != noErr { return noErr }

    let gain = ctx.gain.pointee
    let n = Int(ctx.channelCount)
    guard n > 0 else { return noErr }
    let norm = (gain > 0 ? gain : 0) / Float(n)
    let mask = ctx.frameMask
    let data = ctx.ringData

    // Free space against the consumer's (driver's) read index. Drop on full
    // (reader priority — never overwrite frames the driver hasn't consumed).
    let w = ctx.writeIdx.pointee
    let r = ctx.readIdx.pointee
    let freeFrames = ctx.frameCapacity - (w &- r)
    let give = min(UInt64(frames), freeFrames)

    withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>?.self, capacity: n) { base in
        for k in 0..<n {
            let ch = Int(ctx.channels![k])
            base[k] = ch < chCount ? inABL[ch].mData?.assumingMemoryBound(to: Float.self) : nil
        }
        var lpk = ctx.meterL.pointee, rpk = ctx.meterR.pointee
        for f in 0..<frames {
            var sum: Float = 0
            for k in 0..<n {
                guard let p = base[k] else { continue }
                let s = p[f]
                sum += s
                let sg = s * gain                       // meter post-gain (0 when muted)
                let a = sg < 0 ? -sg : sg
                if k & 1 == 0 { if a > lpk { lpk = a } } else if a > rpk { rpk = a }
            }
            if UInt64(f) < give {
                let pos = Int((w &+ UInt64(f)) & mask) * 2
                let mono = sum * norm
                data[pos] = mono; data[pos + 1] = mono
            }
        }
        ctx.meterL.pointee = lpk; ctx.meterR.pointee = rpk
    }
    OSMemoryBarrier()                       // release: data writes visible before the index bump
    ctx.writeIdx.pointee = w &+ give
    return noErr
}
