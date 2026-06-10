import Foundation
import Accelerate

/// Producer-side handle on a lane's **per-lane buffer** (a small SPSC stereo ring
/// owned by `MixEngine`): where the lane writes its post-gain, interleaved-stereo
/// float audio. The mixer (in `MixEngine`) is the consumer that vDSP-sums the
/// lanes into the driver shmem ring. Handed to a lane at `start`.
public struct SoundLaneSink {
    public let data: UnsafeMutablePointer<Float>          // interleaved stereo
    public let frameCapacity: UInt64                      // power of two
    public let writeIndex: UnsafeMutablePointer<UInt64>   // lane writes (producer)
    public let readIndex: UnsafeMutablePointer<UInt64>    // mixer reads (consumer)

    public init(data: UnsafeMutablePointer<Float>, frameCapacity: UInt64,
                writeIndex: UnsafeMutablePointer<UInt64>, readIndex: UnsafeMutablePointer<UInt64>) {
        self.data = data; self.frameCapacity = frameCapacity
        self.writeIndex = writeIndex; self.readIndex = readIndex
    }
}

/// A per-lane SPSC stereo-float ring: the lane is the single producer (`sink`),
/// the mixer the single consumer (`readAdd`). Owned by `MixEngine`, one per lane.
final class LaneBuffer {
    let capacityFrames: Int
    private let data: UnsafeMutablePointer<Float>
    private let wIdx = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private let rIdx = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    init(frames: Int) {
        capacityFrames = frames
        data = .allocate(capacity: frames * 2)
        data.initialize(repeating: 0, count: frames * 2)
        wIdx.pointee = 0; rIdx.pointee = 0
    }
    deinit { data.deallocate(); wIdx.deallocate(); rIdx.deallocate() }

    var sink: SoundLaneSink {
        SoundLaneSink(data: data, frameCapacity: UInt64(capacityFrames), writeIndex: wIdx, readIndex: rIdx)
    }

    /// Frames the mixer can read right now.
    var available: Int { Int(wIdx.pointee &- rIdx.pointee) }

    /// Mixer consumer: **add** up to `n` frames into `accum` (interleaved stereo)
    /// via vDSP, handling ring wrap, then advance the read index.
    func readAdd(into accum: UnsafeMutablePointer<Float>, frames n: Int) {
        var r = rIdx.pointee
        let cap = capacityFrames
        var done = 0
        while done < n {
            let pos = Int(r & UInt64(cap - 1))
            let seg = min(n - done, cap - pos)              // frames until wrap
            vDSP_vadd(accum + done * 2, 1, data + pos * 2, 1, accum + done * 2, 1, vDSP_Length(seg * 2))
            r &+= UInt64(seg); done += seg
        }
        OSMemoryBarrier()
        rIdx.pointee = r
    }
}

/// An audio **source** lane — a microphone, the system tap, etc. It captures from
/// a source, applies its own gain/mute and peak metering, and writes interleaved
/// stereo float into a `SoundLaneSink`. It knows nothing about the shmem ring or
/// the driver beyond the sink it's handed, so the ring client (`MixEngine`) and
/// the capture details (`MicSoundLane`, later `MacSoundLane`) stay decoupled.
///
/// NOTE: today a single lane writes the SPSC ring directly. When a second lane
/// (the system tap, a different clock) is added, `MixEngine` grows a mixer stage
/// (per-lane buffers summed on one clock) — two RT producers can't share one ring.
public protocol SoundLane: AnyObject {
    var isRunning: Bool { get }
    /// Meter bars to show: 0 (off), 1 (mono), 2 (stereo).
    var meterChannelCount: Int { get }
    /// Linear 0…1 gain; `muted` forces zero. RT-safe (a single store).
    func setGain(_ gain: Float, muted: Bool)
    /// Read and reset the input peak meters (count, left, right).
    func consumeMeters() -> (count: Int, left: Float, right: Float)
    /// Start (or re-configure) capture of `channels` of `source` into `sink`.
    /// A nil/empty request is the caller's cue to `stop()`. Idempotent for an
    /// unchanged request.
    func start(source: String, channels: [Int], sink: SoundLaneSink) throws
    func stop()
}
