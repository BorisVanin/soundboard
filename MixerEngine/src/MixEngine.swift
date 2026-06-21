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
    // The system-output capture device: the system plays into it, the driver produces
    // its audio into the capture ring, and this engine drains it as the Mac lane
    // (replacing the old process tap). Must match kDevice2_UID in the driver.
    private static let captureDeviceUID = "ca.borisvanin.soundboard.system"
    private static let propRingInfo: AudioObjectPropertySelector = 0x73626E69  // 'sbni'
    private static let propRingSession: AudioObjectPropertySelector = 0x73626E73  // 'sbns'
    private static let ringInfoBytes = 88

    private static let laneFrames = 8192   // per-lane buffer (~170 ms @ 48k)
    private static let mixChunk   = 1024   // max frames mixed per tick
    private static let statsLogIntervalNs: UInt64 = 1_000_000_000   // log occupancy 1×/s

    private let logger = Logger(subsystem: "ca.borisvanin.soundboard", category: "MixEngine")

    // Attached ring (owned by the driver; we only map + write client fields).
    private var ringBase: UnsafeMutableRawPointer?
    private var ringBytes = 0
    private var ringData: UnsafeMutablePointer<Float>?
    private var writeIdx, readIdx, heartbeatPtr, appSessionPtr: UnsafeMutablePointer<UInt64>?
    private var frameCapacity: UInt64 = 0
    private var session: UInt64 = 0
    private var deviceID = AudioObjectID(kAudioObjectUnknown)

    // Lanes + their buffers. Mic is captured locally (MicSoundLane); the Mac lane is
    // now the system-output capture device drained from the capture ring (no tap).
    private let micLane: SoundLane = MicSoundLane()
    private let micBuffer = LaneBuffer(frames: MixEngine.laneFrames)
    private let macBuffer = LaneBuffer(frames: MixEngine.laneFrames)

    // Capture ring client (driver→app): the system-output device's audio. Mapped as a
    // consumer; `pumpCapture` drains it into `macBuffer` on the mix queue.
    private var captureBase: UnsafeMutableRawPointer?
    private var captureBytes = 0
    private var captureData: UnsafeMutablePointer<Float>?
    private var captureWriteIdx, captureReadIdx, captureHeartbeat, captureAppSession: UnsafeMutablePointer<UInt64>?
    private var captureCapacity: UInt64 = 0
    private var captureSession: UInt64 = 0
    private var captureDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var captureActive = false
    // The output device the Mac fader/mute control (the selected system output). Usually
    // "Soundboard System" but may be any output device the user picks.
    private var macOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
    // Occupancy logging is OFF by default (saves CPU); toggled cross-process via the
    // driver's StatsLog property, which the CLI sets and this listener observes.
    private var loggingEnabled = false
    private var statsListener: AudioObjectPropertyListenerBlock?
    private let controlQueue = DispatchQueue(label: "ca.borisvanin.soundboard.control")
    private static let propStatsLog: AudioObjectPropertySelector = 0x73626C67  // 'sblg'
    // Mac-lane peak meters, written by `pumpCapture`, read+reset by `consumeMacMeters`.
    private let macMeterL = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let macMeterR = UnsafeMutablePointer<Float>.allocate(capacity: 1)

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

    // Ring-occupancy instrumentation, aggregated on the mix queue and logged 1×/s so
    // we can size the latency caps from real numbers without flooding the log.
    private struct Occ {
        var minV = Int.max, maxV = 0, sum = 0, count = 0
        mutating func sample(_ frames: Int) {
            if frames < minV { minV = frames }
            if frames > maxV { maxV = frames }
            sum += frames; count += 1
        }
        var avg: Int { count > 0 ? sum / count : 0 }
        var active: Bool { count > 0 }
    }
    private var micOcc = Occ(), macOcc = Occ(), monOcc = Occ()
    private var statsLastNs: UInt64 = 0

    public init() { macMeterL.pointee = 0; macMeterR.pointee = 0 }
    deinit {
        micLane.stop(); detachCaptureRing()
        stopMixer(); detach()
        scratch.deallocate(); macMeterL.deallocate(); macMeterR.deallocate()
    }

    // MARK: - Public surface

    public var isRunning: Bool { micLane.isRunning || captureActive }

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

    /// Mac (system-audio) lane: enable/disable draining the capture ring. The capture
    /// source is whatever the system plays into the "Soundboard System" output device;
    /// `sourceUID` no longer selects a device (the picker is unchanged for now and just
    /// acts as an on/off). `nil` detaches the capture ring.
    public func setMacSource(_ sourceUID: String?) {
        guard let sourceUID else { detachCaptureRing(); macOutputDeviceID = kAudioObjectUnknown; return }
        macOutputDeviceID = AudioDevices.deviceID(forUID: sourceUID) ?? kAudioObjectUnknown
        do {
            try ensureAttached()        // mix (output) ring + mixer timer
            try attachCaptureRing()     // capture (input) ring — the system-audio source
        } catch {
            logger.error("MixEngine capture attach failed: \(String(describing: error))")
            detachCaptureRing()
        }
    }
    /// Mac volume is applied on the selected output device via its
    /// `kAudioDevicePropertyVolumeScalar` so the gain leaves the app's RT path entirely
    /// (for "Soundboard System" the driver applies it). `muted` forces zero.
    public func setMacGain(_ gain: Float, muted: Bool) {
        setDeviceVolume(macOutputDeviceID, muted ? 0 : max(0, min(gain, 1)))
    }
    public func consumeMacMeters() -> LaneMeters {
        let left = macMeterL.pointee, right = macMeterR.pointee
        macMeterL.pointee = 0; macMeterR.pointee = 0
        return LaneMeters(count: captureActive ? 2 : 0, left: left, right: right)
    }

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
        micLane.stop(); detachCaptureRing(); monitor.stop()
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
        pumpCapture()         // drain the capture ring → macBuffer (system-audio source)
        if loggingEnabled {   // off by default (no per-tick stats work); toggled via StatsLog
            maybeLogOccupancy()   // 1×/s
            recordOccupancy()     // sample ring depths for the log
        }

        // Active lanes and how many frames are mixable this tick.
        var lanes: [LaneBuffer] = []
        if micLane.isRunning { lanes.append(micBuffer) }
        if captureActive { lanes.append(macBuffer) }
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

    /// Sample each active ring's occupancy for the once-a-second log.
    private func recordOccupancy() {
        if micLane.isRunning { micOcc.sample(micBuffer.available) }
        if captureActive { macOcc.sample(macBuffer.available) }
        if monitor.isRunning { monOcc.sample(monitor.ringOccupancy) }
    }

    /// Emit a single occupancy summary (min/avg/max frames + ms) per ring once a
    /// second, then reset the accumulators — enough to spot trouble, not enough to
    /// flood the log.
    private func maybeLogOccupancy() {
        let now = DispatchTime.now().uptimeNanoseconds
        if statsLastNs == 0 { statsLastNs = now; return }
        guard now &- statsLastNs >= Self.statsLogIntervalNs else { return }
        statsLastNs = now

        func fmt(_ name: String, _ occ: Occ) -> String {
            guard occ.active else { return "\(name)[idle]" }
            let millis: (Int) -> Double = { Double($0) / 48.0 }   // 48 frames per ms @ 48 kHz
            return String(format: "%@[%d/%d/%d f, %.1f/%.1f/%.1f ms]",
                          name, occ.minV, occ.avg, occ.maxV,
                          millis(occ.minV), millis(occ.avg), millis(occ.maxV))
        }
        let line = "\(fmt("mic", micOcc)) \(fmt("mac", macOcc)) \(fmt("monitor", monOcc))"
        logger.info("buffer occupancy (min/avg/max) 1s — \(line, privacy: .public)")
        micOcc = Occ(); macOcc = Occ(); monOcc = Occ()
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
}

// Capture-ring client + HAL property helpers, split into an extension to keep the
// main class body within the lint cap.
extension MixEngine {

    // MARK: - Capture ring (driver→app): the system-output device as the Mac lane

    /// Map the capture ring exported by the "Soundboard System" device and claim it as
    /// the consumer. Idempotent. Mirrors `ensureAttached` but this side *reads* the ring
    /// (the driver produces) — we advance `readIndex` and beat `heartbeat` in `pumpCapture`.
    private func attachCaptureRing() throws {
        guard captureBase == nil else { return }
        guard let dev = findDevice(uid: Self.captureDeviceUID) else { throw RingError.noDevice }
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

        let data    = (base + Int(dataOff)).assumingMemoryBound(to: Float.self)
        let appSess = (base + Self.offAppSession).assumingMemoryBound(to: UInt64.self)
        let beat    = (base + Self.offHeartbeat).assumingMemoryBound(to: UInt64.self)
        let wIdx    = (base + Self.offWriteIndex).assumingMemoryBound(to: UInt64.self)
        let rIdx    = (base + Self.offReadIndex).assumingMemoryBound(to: UInt64.self)

        // Start draining from the freshest sample, then claim: publish appSession and
        // grant via RingSession so the driver's `produce` gate opens.
        rIdx.pointee = wIdx.pointee
        let claim = (UInt64(UInt32(bitPattern: getpid())) << 32) | UInt64(UInt32.random(in: 1...UInt32.max))
        appSess.pointee = claim
        OSMemoryBarrier()
        setRingSession(dev, claim)
        registerStatsListener(on: dev)   // observe the StatsLog toggle on the capture device

        // Publish to the mix queue atomically: the mixer may already be running (mic
        // active), so flip `captureActive` last, under the queue, after the pointers.
        mixQueue.sync {
            captureBase = base; captureBytes = total
            captureCapacity = UInt64(info.frameCapacity); captureDeviceID = dev; captureSession = claim
            captureData = data; captureAppSession = appSess; captureHeartbeat = beat
            captureWriteIdx = wIdx; captureReadIdx = rIdx
            captureActive = true
        }
        logger.info("MixEngine attached capture '\(info.name)' (\(self.captureCapacity) frames) + claimed \(self.captureSession)")
    }

    private func detachCaptureRing() {
        // Retract under the mix queue so no in-flight `pumpCapture` touches the mapping
        // we are about to unmap, then do the slow teardown off-queue.
        var base: UnsafeMutableRawPointer?
        var bytes = 0
        var dev = AudioObjectID(kAudioObjectUnknown)
        var appSess: UnsafeMutablePointer<UInt64>?
        mixQueue.sync {
            guard captureActive || captureBase != nil else { return }
            captureActive = false
            base = captureBase; bytes = captureBytes; dev = captureDeviceID; appSess = captureAppSession
            captureBase = nil; captureData = nil; captureWriteIdx = nil; captureReadIdx = nil
            captureAppSession = nil; captureHeartbeat = nil
            captureBytes = 0; captureCapacity = 0; captureSession = 0
            captureDeviceID = AudioObjectID(kAudioObjectUnknown)
            macMeterL.pointee = 0; macMeterR.pointee = 0
        }
        guard let base else { return }
        if dev != kAudioObjectUnknown { removeStatsListener(from: dev); setRingSession(dev, 0) }
        appSess?.pointee = 0
        munmap(base, bytes)
    }

    /// Observe the driver's StatsLog property on the capture device: when the CLI flips
    /// it, enable/disable the per-second occupancy logging (off by default to save CPU).
    private func registerStatsListener(on dev: AudioObjectID) {
        loggingEnabled = readStatsLog(dev)
        var addr = AudioObjectPropertyAddress(mSelector: Self.propStatsLog,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.loggingEnabled = self.readStatsLog(dev)
        }
        statsListener = block
        AudioObjectAddPropertyListenerBlock(dev, &addr, controlQueue, block)
    }

    private func removeStatsListener(from dev: AudioObjectID) {
        guard let block = statsListener else { return }
        var addr = AudioObjectPropertyAddress(mSelector: Self.propStatsLog,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(dev, &addr, controlQueue, block)
        statsListener = nil
        loggingEnabled = false
    }

    /// Read the StatsLog custom property (CFData of one UInt32) → on/off.
    private func readStatsLog(_ dev: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: Self.propStatsLog,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var unmanaged: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let data = unmanaged?.takeRetainedValue(),
              CFDataGetLength(data) >= 4 else { return false }
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { CFDataGetBytes(data, CFRange(location: 0, length: 4),
                                                            $0.bindMemory(to: UInt8.self).baseAddress) }
        return value != 0
    }

    /// Mix-queue producer into `macBuffer`: drain the freshest capture-ring frames the
    /// driver produced (already volume-scaled), meter them, and beat the heartbeat so
    /// the driver keeps producing. Drop-on-full at the lane buffer (the trim caps latency).
    private func pumpCapture() {
        guard captureActive, let cData = captureData, let cWrite = captureWriteIdx,
              let cRead = captureReadIdx, let cBeat = captureHeartbeat else { return }
        cBeat.pointee = cBeat.pointee &+ 1            // liveness for the driver's produce gate

        let ccap = Int(captureCapacity)
        var readPos = cRead.pointee
        let writePos = cWrite.pointee
        var avail = Int(writePos &- readPos)
        if avail <= 0 { return }
        if avail > ccap { readPos = writePos &- UInt64(ccap); avail = ccap }   // lapped → skip stale

        let sink = macBuffer.sink
        let mcap = Int(sink.frameCapacity)
        let free = mcap - Int(sink.writeIndex.pointee &- sink.readIndex.pointee)
        let take = min(avail, free)
        guard take > 0 else { cRead.pointee = readPos; return }

        let writeBase = sink.writeIndex.pointee
        var leftPeak = macMeterL.pointee, rightPeak = macMeterR.pointee
        var index = 0
        while index < take {
            let src = Int((readPos &+ UInt64(index)) & UInt64(ccap - 1)) * 2
            let dst = Int((writeBase &+ UInt64(index)) & UInt64(mcap - 1)) * 2
            let left = cData[src], right = cData[src + 1]
            sink.data[dst] = left; sink.data[dst + 1] = right
            let absL = left < 0 ? -left : left; if absL > leftPeak { leftPeak = absL }
            let absR = right < 0 ? -right : right; if absR > rightPeak { rightPeak = absR }
            index &+= 1
        }
        macMeterL.pointee = leftPeak; macMeterR.pointee = rightPeak
        OSMemoryBarrier()
        sink.writeIndex.pointee = writeBase &+ UInt64(take)
        cRead.pointee = readPos &+ UInt64(take)
    }

    /// Set an output device's volume scalar (main element). For "Soundboard System" the
    /// driver applies it to system audio before the capture ring; for a real device it
    /// drives the hardware/software volume.
    private func setDeviceVolume(_ dev: AudioObjectID, _ scalar: Float) {
        guard dev != kAudioObjectUnknown else { return }
        var value = scalar
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    // MARK: - HAL property helpers (the SHMEM.md §2 handshake)

    private func findDevice(uid uidString: String = MixEngine.deviceUID) -> AudioDeviceID? {
        var uid = uidString as CFString
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
