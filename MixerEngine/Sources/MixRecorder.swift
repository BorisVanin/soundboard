import Foundation
import CoreAudio
import AudioToolbox
import OSLog

/// Records the **finished mix** to a `.wav` file. Like `MixMonitor`, it is fed a tee
/// of the very buffer `MixEngine` writes to the shmem ring — so the file is exactly
/// the stream that reaches the Soundboard loopback driver and the monitor, captured
/// at the canonical 48 kHz stereo before the device round-trip.
///
/// `write` runs on the mixer's queue (RT-ish) and only calls the RT-safe
/// `ExtAudioFileWriteAsync` (which copies into its own buffers and finalizes on a
/// private I/O thread). The file lifecycle (`open`/`close`) is **not** self-serialized:
/// the owner (`MixEngine`) gates `write` with `enabled` and flushes the mix queue
/// between disabling and closing, so a write can never run against a disposed file.
final class MixRecorder {

    private let logger = Logger(subsystem: "ca.borisvanin.soundboard", category: "MixRecorder")
    private static let rate = 48_000.0
    private static let channels: UInt32 = 2

    private var file: ExtAudioFileRef?
    /// 1 while `write` may touch `file`; 0 otherwise. Set 1 only after the file is
    /// fully created, 0 (then mix-queue flushed) before it is disposed.
    private let enabledPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    init() { enabledPtr.pointee = 0 }
    deinit { close(); enabledPtr.deallocate() }

    var isOpen: Bool { file != nil }

    enum RecorderError: Error { case file(OSStatus) }
    private func checkFile(_ s: OSStatus) throws { if s != noErr { throw RecorderError.file(s) } }

    /// Create `url` (overwriting) and prime the async writer. Caller enables after.
    func open(to url: URL) throws {
        guard file == nil else { return }
        var clientFmt = Self.floatFormat()
        var fileFmt = Self.wavFormat()
        var ref: ExtAudioFileRef?
        try checkFile(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &fileFmt, nil,
                                                AudioFileFlags.eraseFile.rawValue, &ref))
        guard let ref else { throw RecorderError.file(-1) }
        try checkFile(ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                              UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFmt))
        // Prime ExtAudioFile's async I/O thread before any RT write (on this thread,
        // not the mix queue), matching the device-recorder's proven sequence.
        try checkFile(ExtAudioFileWriteAsync(ref, 0, nil))
        file = ref
        logger.info("Recording the mix → \(url.lastPathComponent, privacy: .public)")
    }

    /// Open the producer gate (after `open`). A barrier publishes `file` first.
    func enable() { OSMemoryBarrier(); enabledPtr.pointee = 1 }
    /// Close the gate. The owner must flush the mix queue before `close`.
    func disable() { enabledPtr.pointee = 0; OSMemoryBarrier() }

    func close() {
        enabledPtr.pointee = 0
        if let f = file { ExtAudioFileDispose(f) }   // flushes + finalizes the WAV header
        file = nil
    }

    /// Mixer producer (mix queue): append `frames` of interleaved-stereo float `src`.
    /// No-op unless enabled. The transient buffer list is consumed synchronously.
    func write(_ src: UnsafePointer<Float>, frames: Int) {
        guard enabledPtr.pointee != 0, frames > 0, let f = file else { return }
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: Self.channels,
                                  mDataByteSize: UInt32(frames) * Self.channels * UInt32(MemoryLayout<Float>.size),
                                  mData: UnsafeMutableRawPointer(mutating: src)))
        _ = ExtAudioFileWriteAsync(f, UInt32(frames), &abl)
    }

    private static func floatFormat() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }
    private static func wavFormat() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
    }
}
