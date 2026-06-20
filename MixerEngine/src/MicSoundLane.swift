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
    /// Smoothed gain the callback actually applies (the target is `gainPtr`); ramped
    /// per sample to de-zipper fader/mute moves. Written only by the RT callback.
    private let smoothPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let meterL = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let meterR = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    public private(set) var meterChannelCount = 0

    public init() { gainPtr.pointee = 1; smoothPtr.pointee = 1; meterL.pointee = 0; meterR.pointee = 0 }
    deinit { stop(); gainPtr.deallocate(); smoothPtr.deallocate(); meterL.deallocate(); meterR.deallocate() }

    public var isRunning: Bool { captureUnit != nil }

    public func setGain(_ gain: Float, muted: Bool) {
        gainPtr.pointee = muted ? 0 : max(0, min(gain, 1))
    }

    public func consumeMeters() -> LaneMeters {
        let left = meterL.pointee, right = meterR.pointee
        meterL.pointee = 0; meterR.pointee = 0
        return LaneMeters(count: meterChannelCount, left: left, right: right)
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
        if let audioUnit = captureUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        captureUnit = nil
        if let abl = captureABL {
            for buffer in abl { buffer.mData?.deallocate() }
            free(abl.unsafeMutablePointer)
        }
        captureABL = nil
        if let ctx = captureCtx { ctx.pointee.channels?.deallocate(); ctx.deallocate() }
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

        let audioUnit = try makeHALUnit()
        captureUnit = audioUnit
        var enable: UInt32 = 1, disable: UInt32 = 0
        try setProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable)
        try setProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable)
        var micDev = micID
        try setProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &micDev)
        var maxF = UInt32(Self.maxFrames)
        try setProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxF)
        // Fixed 48k client format: the AUHAL resamples the mic into it, so we always
        // feed the ring's canonical rate and a device-side reconfig can't resize us.
        var inFmt = Self.format(rate: 48_000, channels: micChannels)
        try setProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inFmt)

        let abl = AudioBufferList.allocate(maximumBuffers: micChannels)
        let bufferBytes = Self.maxFrames * MemoryLayout<Float>.size
        for index in 0..<micChannels {
            let data = UnsafeMutableRawPointer.allocate(byteCount: bufferBytes, alignment: 16)
            abl[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bufferBytes), mData: data)
        }
        captureABL = abl

        let chanPtr = UnsafeMutablePointer<Int32>.allocate(capacity: wanted.count)
        for (index, channel) in wanted.enumerated() { chanPtr[index] = Int32(channel) }
        smoothPtr.pointee = gainPtr.pointee          // start matched: no ramp on (re)start
        let ctx = UnsafeMutablePointer<MicCaptureContext>.allocate(capacity: 1)
        ctx.pointee = MicCaptureContext(
            unit: audioUnit, inputABL: abl.unsafeMutablePointer, maxFrames: Int32(Self.maxFrames),
            micChannels: Int32(micChannels), channels: chanPtr, channelCount: Int32(wanted.count),
            gain: gainPtr, smooth: smoothPtr, meterL: meterL, meterR: meterR,
            ringData: sink.data, frameMask: sink.frameCapacity - 1, frameCapacity: sink.frameCapacity,
            writeIdx: sink.writeIndex, readIdx: sink.readIndex)
        captureCtx = ctx
        meterChannelCount = wanted.count >= 2 ? 2 : 1

        var inCb = AURenderCallbackStruct(
            inputProc: micCaptureCallback, inputProcRefCon: UnsafeMutableRawPointer(ctx))
        try setProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inCb)
        try check(AudioUnitInitialize(audioUnit))
        try check(AudioOutputUnitStart(audioUnit))
    }

    private func setProperty<T>(
        _ audioUnit: AudioUnit, _ propertyID: AudioUnitPropertyID, _ scope: AudioUnitScope,
        _ element: AudioUnitElement, _ value: inout T) throws {
        try withUnsafePointer(to: &value) { ptr in
            try check(AudioUnitSetProperty(
                audioUnit, propertyID, scope, element, ptr, UInt32(MemoryLayout<T>.size)))
        }
    }

    private func makeHALUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw LaneError.noDevice }
        var audioUnit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &audioUnit))
        guard let audioUnit else { throw LaneError.noDevice }
        return audioUnit
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
    var smooth: UnsafeMutablePointer<Float>
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
private let micCaptureCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let ctx = inRefCon.assumingMemoryBound(to: MicCaptureContext.self).pointee
    let frames = Int(inNumberFrames)
    if frames > Int(ctx.maxFrames) { return noErr }
    let bytes = frames * MemoryLayout<Float>.size

    let inABL = UnsafeMutableAudioBufferListPointer(ctx.inputABL)
    let chCount = Int(ctx.micChannels)
    for index in 0..<chCount { inABL[index].mDataByteSize = UInt32(bytes) }
    var flags = ioActionFlags.pointee
    if AudioUnitRender(ctx.unit, &flags, inTimeStamp, 1, inNumberFrames, ctx.inputABL) != noErr { return noErr }

    let target = ctx.gain.pointee
    let count = Int(ctx.channelCount)
    guard count > 0 else { return noErr }
    let invCount = 1 / Float(count)
    let mask = ctx.frameMask
    let data = ctx.ringData

    // Free space against the consumer's (driver's) read index. Drop on full
    // (reader priority — never overwrite frames the driver hasn't consumed).
    let writeIdx = ctx.writeIdx.pointee
    let readIdx = ctx.readIdx.pointee
    let freeFrames = ctx.frameCapacity - (writeIdx &- readIdx)
    let give = min(UInt64(frames), freeFrames)

    withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>?.self, capacity: count) { base in
        for channelIndex in 0..<count {
            let channel = Int(ctx.channels![channelIndex])
            base[channelIndex] = channel < chCount
                ? inABL[channel].mData?.assumingMemoryBound(to: Float.self) : nil
        }
        var lpk = ctx.meterL.pointee, rpk = ctx.meterR.pointee
        var gain = ctx.smooth.pointee                   // smoothed gain, ramped per sample
        for frameIndex in 0..<frames {
            gain += gainSmoothingAlpha * (target - gain) // de-zipper: no gain step
            if abs(target - gain) < 1e-6 { gain = target } // settle exactly (no denormals)
            var sum: Float = 0
            for channelIndex in 0..<count {
                guard let ptr = base[channelIndex] else { continue }
                let sample = ptr[frameIndex]
                sum += sample
                let scaled = sample * gain              // meter post-gain (0 when muted)
                let amplitude = scaled < 0 ? -scaled : scaled
                if channelIndex & 1 == 0 {
                    if amplitude > lpk { lpk = amplitude }
                } else if amplitude > rpk { rpk = amplitude }
            }
            if UInt64(frameIndex) < give {
                let pos = Int((writeIdx &+ UInt64(frameIndex)) & mask) * 2
                let mono = sum * gain * invCount
                data[pos] = mono; data[pos + 1] = mono
            }
        }
        ctx.smooth.pointee = gain
        ctx.meterL.pointee = lpk; ctx.meterR.pointee = rpk
    }
    OSMemoryBarrier()                       // release: data writes visible before the index bump
    ctx.writeIdx.pointee = writeIdx &+ give
    return noErr
}
