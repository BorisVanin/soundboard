import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import OSLog

/// Client of the **driver-owned** mix ring (`docs/shmem.md`) and the
/// **mixer** of the app's `SoundLane`s. It owns the ring relationship (discover,
/// `RingInfo`, `shm_open`+map, claim `RingSession`) and one `LaneBuffer` per lane;
/// a high-QoS timer reads each active lane's buffer, **vDSP-sums** them, and writes
/// the result into the shmem ring (+ heartbeat). The capture lives in the lanes
/// (`MicSoundLane`, `MacSoundLane`) — fully decoupled from the ring and from each
/// other (different clocks, each absorbed by its lane buffer).
public final class MixEngine {

    // Ring layout — must match LoopbackDriver/src/SoundboardRingProtocol.h.
    private static let magic: UInt32   = 0x53424D58   // 'SBMX'
    private static let version: UInt16 = 1
    private static let ringAlive: UInt32 = 1
    private static let headerBytes = 64
    private static let offMagic = 0, offVersion = 4, offChannels = 6, offDataOffset = 24
    private static let offAppSession = 32, offHeartbeat = 40, offWriteIndex = 48, offReadIndex = 56

    // Driver device + custom HAL properties (SHMEM.md §2).
    private static let deviceUID = "ca.borisvanin.soundboard.device"
    private static let propRingInfo: AudioObjectPropertySelector = 0x73626E69  // 'sbni'
    private static let propRingSession: AudioObjectPropertySelector = 0x73626E73  // 'sbns'
    private static let ringInfoBytes = 88

    private static let laneFrames = 8192   // per-lane buffer (~170 ms @ 48k)
    private static let mixChunk   = 1024   // max frames mixed per tick

    private let logger = Logger(subsystem: "ca.borisvanin.soundboard", category: "MixEngine")

    // Attached ring (owned by the driver; we only map + write client fields).
    private var ringBase: UnsafeMutableRawPointer?
    private var ringBytes = 0
    private var ringData: UnsafeMutablePointer<Float>?
    private var writeIdx, readIdx, heartbeatPtr, appSessionPtr: UnsafeMutablePointer<UInt64>?
    private var frameCapacity: UInt64 = 0
    private var session: UInt64 = 0
    private var deviceID = AudioObjectID(kAudioObjectUnknown)

    // Lanes + their buffers (mic; system tap).
    private let micLane: SoundLane = MicSoundLane()
    private let macLane: SoundLane = MacSoundLane()
    private let micBuffer = LaneBuffer(frames: MixEngine.laneFrames)
    private let macBuffer = LaneBuffer(frames: MixEngine.laneFrames)

    // Monitor: plays the finished mix to a user-chosen output device. Fed by the
    // mix tick (a tee of the same buffer written to the shmem ring).
    private let monitor = MixMonitor()
    // Recorder: writes the finished mix to a .wav. Also fed by the mix tick, so the
    // file is byte-identical to the loopback feed and the monitor.
    private let recorder = MixRecorder()

    // Mixer.
    private let mixQueue = DispatchQueue(label: "ca.borisvanin.soundboard.mixer", qos: .userInteractive)
    private var mixTimer: DispatchSourceTimer?
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: MixEngine.mixChunk * 2)

    public init() {}
    deinit {
        micLane.stop(); macLane.stop()
        stopMixer(); detach()
        scratch.deallocate()
    }

    // MARK: - Public surface

    public var isRunning: Bool { micLane.isRunning || macLane.isRunning }

    /// Mic lane: capture `channels` of `micUID`. Nil/empty stops it.
    public func configure(micUID: String?, channels: [Int]) {
        guard let micUID, !channels.isEmpty else { micLane.stop(); return }
        do {
            try ensureAttached()
            try micLane.start(source: micUID, channels: channels, sink: micBuffer.sink)
        } catch {
            logger.error("MixEngine mic start failed: \(String(describing: error))")
            micLane.stop()
        }
    }
    public func setMicGain(_ gain: Float, muted: Bool) { micLane.setGain(gain, muted: muted) }
    public func consumeMicMeters() -> LaneMeters { micLane.consumeMeters() }

    /// Mac (system-audio) lane: tap the audio of output device `sourceUID` (or all
    /// system output when `sourceUID == ""`). `nil` stops the lane. Scoping to a
    /// device only reads its stream — it never changes the system's default output.
    public func setMacSource(_ sourceUID: String?) {
        guard let sourceUID else { macLane.stop(); return }
        do {
            try ensureAttached()
            try macLane.start(source: sourceUID, channels: [], sink: macBuffer.sink)
        } catch {
            logger.error("MixEngine mac start failed: \(String(describing: error))")
            macLane.stop()
        }
    }
    public func setMacGain(_ gain: Float, muted: Bool) { macLane.setGain(gain, muted: muted) }
    public func consumeMacMeters() -> LaneMeters { macLane.consumeMeters() }

    /// Monitor the mix on `deviceUID` when `enabled`; stop otherwise. Playing the
    /// mix never touches the lanes or the shmem ring — it's a tee of the mixer's
    /// output, so it works whether or not anything is draining the loopback.
    public func setMonitorEnabled(_ enabled: Bool, deviceUID: String?, volume: Float) {
        monitor.setVolume(volume)
        guard enabled, let deviceUID else { monitor.stop(); return }
        do {
            try monitor.start(deviceUID: deviceUID)
        } catch {
            logger.error("MixMonitor start failed: \(String(describing: error))")
            monitor.stop()
        }
    }
    public func setMonitorVolume(_ volume: Float) { monitor.setVolume(volume) }
    public var isMonitoring: Bool { monitor.isRunning }

    /// Record the finished mix to `url` (a tee of the same buffer fed to the ring +
    /// monitor). Throws if the file can't be created.
    public func startRecording(to url: URL) throws {
        try recorder.open(to: url)
        recorder.enable()                 // gate opened only after the file exists
    }
    /// Stop recording. Disable the producer, flush any in-flight mix tick on the mix
    /// queue, then close — so no `write` can run against the disposed file.
    public func stopRecording() {
        recorder.disable()
        mixQueue.sync {}
        recorder.close()
    }
    public var isRecording: Bool { recorder.isOpen }

    /// Stop both lanes and release the ring. (Lanes first — once detached the
    /// mixer must not touch the ring.)
    public func stop() {
        micLane.stop(); macLane.stop(); monitor.stop()
        recorder.disable(); stopMixer(); recorder.close()   // flush ticks before closing the file
        detach()
    }

    // MARK: - Mixer (vDSP sum of the per-lane buffers → shmem ring)

    private func startMixer() {
        guard mixTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: mixQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(3), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.mixTick() }
        mixTimer = timer
        timer.resume()
    }
    private func stopMixer() {
        guard let timer = mixTimer else { return }
        timer.cancel(); mixTimer = nil
        mixQueue.sync {}   // flush any in-flight tick so detach can't free the ring under it
    }

    private func mixTick() {
        guard let ringData, let writeIdx, let readIdx, let heartbeatPtr else { return }

        // Active lanes and how many frames are mixable this tick.
        var lanes: [LaneBuffer] = []
        if micLane.isRunning { lanes.append(micBuffer) }
        if macLane.isRunning { lanes.append(macBuffer) }
        guard !lanes.isEmpty else { return }

        // Frames available from the lanes this tick — bounded by the chunk size, not
        // by the shmem ring's free space: the mix must keep flowing to the monitor
        // even when nothing is draining the loopback.
        var frameCount = Self.mixChunk
        for lane in lanes { frameCount = min(frameCount, lane.available) }
        guard frameCount > 0 else { return }

        // Sum the lanes (gain already applied per-lane) via vDSP.
        vDSP_vclr(scratch, 1, vDSP_Length(frameCount * 2))
        for lane in lanes { lane.readAdd(into: scratch, frames: frameCount) }

        // Tee the finished mix to the monitor (its own ring; drop-on-full) and the
        // recorder (async file write). Both no-op when off, independent of the shmem
        // write below — so they capture the mix even when nothing drains the ring.
        monitor.enqueue(scratch, frames: frameCount)
        recorder.write(scratch, frames: frameCount)

        // Write into the shmem ring up to its free space; drop the overflow. The driver
        // consumer has priority — when nothing drains the ring we simply stop feeding it
        // (and stop the heartbeat), rather than stalling the lanes/monitor.
        let shmemFree = Int(frameCapacity - (writeIdx.pointee &- readIdx.pointee))
        let toShm = min(frameCount, shmemFree)
        guard toShm > 0 else { return }
        let cap = Int(frameCapacity)
        var writePos = writeIdx.pointee
        var done = 0
        while done < toShm {
            let pos = Int(writePos & UInt64(cap - 1))
            let seg = min(toShm - done, cap - pos)
            (ringData + pos * 2).update(from: scratch + done * 2, count: seg * 2)
            writePos &+= UInt64(seg); done += seg
        }
        OSMemoryBarrier()
        writeIdx.pointee = writePos
        heartbeatPtr.pointee = heartbeatPtr.pointee &+ 1
    }

    // MARK: - Ring attach / detach (client)

    private enum RingError: Error { case noDevice, notReady, shm(Int32), map(Int32), badHeader }

    private typealias ShmOpenFn = @convention(c) (UnsafePointer<CChar>, Int32, mode_t) -> Int32
    private static let shmOpenC: ShmOpenFn = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else {
            fatalError("shm_open not found")
        }
        return unsafeBitCast(sym, to: ShmOpenFn.self)
    }()

    private func ensureAttached() throws {
        guard ringBase == nil else { return }
        guard let dev = findDevice() else { throw RingError.noDevice }
        guard let info = getRingInfo(dev) else { throw RingError.noDevice }
        guard info.driverState == Self.ringAlive else { throw RingError.notReady }

        let fileDescriptor = info.name.withCString { Self.shmOpenC($0, O_RDWR, 0) }
        if fileDescriptor < 0 { throw RingError.shm(errno) }
        let total = Self.headerBytes + Int(info.frameCapacity) * Int(info.channels) * MemoryLayout<Float>.size
        guard let base = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fileDescriptor, 0),
              base != MAP_FAILED else {
            let mapError = errno; close(fileDescriptor); throw RingError.map(mapError)
        }
        close(fileDescriptor)

        let magic = base.loadUnaligned(fromByteOffset: Self.offMagic, as: UInt32.self)
        let ver   = base.loadUnaligned(fromByteOffset: Self.offVersion, as: UInt16.self)
        let channels = base.loadUnaligned(fromByteOffset: Self.offChannels, as: UInt16.self)
        let dataOff = base.loadUnaligned(fromByteOffset: Self.offDataOffset, as: UInt64.self)
        guard magic == Self.magic, ver == Self.version, channels == 2 else {
            munmap(base, total); throw RingError.badHeader
        }

        ringBase = base; ringBytes = total; frameCapacity = UInt64(info.frameCapacity); deviceID = dev
        ringData      = (base + Int(dataOff)).assumingMemoryBound(to: Float.self)
        appSessionPtr = (base + Self.offAppSession).assumingMemoryBound(to: UInt64.self)
        heartbeatPtr  = (base + Self.offHeartbeat).assumingMemoryBound(to: UInt64.self)
        writeIdx      = (base + Self.offWriteIndex).assumingMemoryBound(to: UInt64.self)
        readIdx       = (base + Self.offReadIndex).assumingMemoryBound(to: UInt64.self)

        // Claim: write appSession, then publish the grant via the RingSession property.
        session = (UInt64(UInt32(bitPattern: getpid())) << 32) | UInt64(UInt32.random(in: 1...UInt32.max))
        appSessionPtr!.pointee = session
        OSMemoryBarrier()
        setRingSession(dev, session)
        startMixer()
        logger.info(
            "MixEngine attached '\(info.name)' (\(self.frameCapacity) frames) + claimed session \(self.session)"
        )
    }

    private func detach() {
        guard let base = ringBase else { return }
        if deviceID != kAudioObjectUnknown { setRingSession(deviceID, 0) }
        appSessionPtr?.pointee = 0
        munmap(base, ringBytes)
        ringBase = nil; ringData = nil; writeIdx = nil; readIdx = nil; appSessionPtr = nil; heartbeatPtr = nil
        ringBytes = 0; frameCapacity = 0; session = 0; deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - HAL property helpers (the SHMEM.md §2 handshake)

    private func findDevice() -> AudioDeviceID? {
        var uid = Self.deviceUID as CFString
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), ptr, &size, &dev)
        }
        return (status == noErr && dev != kAudioObjectUnknown) ? dev : nil
    }

    private struct RingInfo {
        let name: String
        let driverState: UInt32
        let frameCapacity: UInt32
        let channels: UInt32
    }

    private func getRingInfo(_ dev: AudioObjectID) -> RingInfo? {
        var addr = AudioObjectPropertyAddress(mSelector: Self.propRingInfo,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var unmanaged: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let data = unmanaged?.takeRetainedValue(),
              CFDataGetLength(data) >= Self.ringInfoBytes else { return nil }
        var buf = [UInt8](repeating: 0, count: Self.ringInfoBytes)
        CFDataGetBytes(data, CFRange(location: 0, length: Self.ringInfoBytes), &buf)
        func u32(_ off: Int) -> UInt32 {
            buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
        }
        let name = String(bytes: buf[24..<88].prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        return RingInfo(name: name, driverState: u32(4), frameCapacity: u32(8), channels: u32(12))
    }

    private func setRingSession(_ dev: AudioObjectID, _ session: UInt64) {
        var sessionValue = session
        guard let createdData = withUnsafeBytes(of: &sessionValue, {
            CFDataCreate(nil, $0.bindMemory(to: UInt8.self).baseAddress, MemoryLayout<UInt64>.size)
        }) else { return }
        var cfData: CFData = createdData
        var addr = AudioObjectPropertyAddress(mSelector: Self.propRingSession,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        _ = withUnsafePointer(to: &cfData) {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<CFData>.size), $0)
        }
    }
}
