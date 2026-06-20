//
//  tap_feed.swift — stepping-stone producer #2: SYSTEM AUDIO -> mix ring.
//
//  Creates a Core Audio process tap over all system output (stereo, non-muting),
//  wraps it in a private aggregate, and writes the captured audio into the same
//  production ring the driver drains. Purpose: de-risk the process-tap capture +
//  ring producer before integrating into the app, where the tap has to coexist
//  with the existing Multi-Output / MicMonitor architecture.
//
//  Build (driver with the mix ring must be installed):
//    swiftc -O tools/tap_feed.swift -import-objc-header tools/RingAtomics.h \
//      -framework CoreAudio -framework AudioToolbox -framework Foundation -o /tmp/tap_feed
//  Run, play some audio, then FaceTime with "Soundboard" as the mic:
//    /tmp/tap_feed
//
//  Throwaway. Requires macOS 14.4+ (Core Audio taps).
//
import Foundation
import CoreAudio
import AudioToolbox

// ---- Ring contract (mirrors LoopbackDriver/src/SoundboardRing.h) ----
let kRingShmName      = "/soundboard_mix_ring"
let kRingMagic: UInt32 = 0x53424752          // 'SBGR'
let kRingChannels      = 2
let kRingSampleRate: UInt32 = 48000
let kRingFrameCapacity  = 16384              // power of two
// Byte offsets into the header (4×u32 then 3×u64).
let offMagic = 0, offFrameCap = 4, offChannels = 8, offRate = 12
let offDataOffset = 16, offWriteIndex = 24, offReadIndex = 32
let ringHeaderBytes = 40
let ringTotalBytes = ringHeaderBytes + kRingFrameCapacity * kRingChannels * MemoryLayout<Float>.size

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

// ---- 1. Create + init the shared ring (mode 0666 so coreaudiod can open it). ----
shm_unlink(kRingShmName)
let fd = ring_shm_open(kRingShmName, O_CREAT | O_RDWR, 0o666)   // 0666 so coreaudiod can open it
if fd < 0 { fail("shm_open failed errno=\(errno)") }
if ftruncate(fd, off_t(ringTotalBytes)) != 0 { fail("ftruncate failed errno=\(errno)") }
guard let base = mmap(nil, ringTotalBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
      base != MAP_FAILED else { fail("mmap failed errno=\(errno)") }
close(fd)
let raw = base.bindMemory(to: UInt8.self, capacity: ringTotalBytes)
func u32(_ off: Int, _ v: UInt32) { (base + off).assumingMemoryBound(to: UInt32.self).pointee = v }
func u64ptr(_ off: Int) -> UnsafeMutablePointer<UInt64> { (base + off).assumingMemoryBound(to: UInt64.self) }
memset(base, 0, ringTotalBytes)
u32(offFrameCap, UInt32(kRingFrameCapacity)); u32(offChannels, UInt32(kRingChannels))
u32(offRate, kRingSampleRate); u64ptr(offDataOffset).pointee = UInt64(ringHeaderBytes)
ring_store_release(u64ptr(offWriteIndex), 0); ring_store_release(u64ptr(offReadIndex), 0)
u32(offMagic, kRingMagic)                                   // publish last
let ringData = (base + ringHeaderBytes).assumingMemoryBound(to: Float.self)
let writeIdxPtr = u64ptr(offWriteIndex), readIdxPtr = u64ptr(offReadIndex)
let cap = UInt64(kRingFrameCapacity)

// ---- VU metering of the CAPTURED input (reported 1×/sec) ----
// Monotonic totals written by the IOProc; the timer reads deltas (no reset race).
// Peak is a windowed max the timer reads + clears (benign race, fine for a meter).
let meterSumSq = UnsafeMutablePointer<Double>.allocate(capacity: 1); meterSumSq.pointee = 0
let meterCount = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); meterCount.pointee = 0
let meterPeak  = UnsafeMutablePointer<Float>.allocate(capacity: 1);  meterPeak.pointee  = 0

// ---- 2. Shared ring writer (called from the capture IOProc). ----
func pushToRing(_ inInputData: UnsafePointer<AudioBufferList>) {
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    guard abl.count > 0 else { return }
    let buf = abl[0]
    let chans = Int(buf.mNumberChannels)
    guard chans > 0, let mData = buf.mData else { return }
    let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chans)   // interleaved float
    let src = mData.assumingMemoryBound(to: Float.self)

    // Meter the captured input itself (all frames, independent of ring backpressure).
    var ss = 0.0; var pk: Float = 0
    for f in 0..<frames {
        let l = src[f * chans + 0]
        let rr = chans > 1 ? src[f * chans + 1] : l
        ss += Double(l) * Double(l) + Double(rr) * Double(rr)
        let m = max(abs(l), abs(rr)); if m > pk { pk = m }
    }
    meterSumSq.pointee += ss
    meterCount.pointee += UInt64(frames) * 2
    if pk > meterPeak.pointee { meterPeak.pointee = pk }

    let w = ring_load_relaxed(writeIdxPtr)
    let r = ring_load_acquire(readIdxPtr)
    let freeFrames = cap - (w - r)
    let give = min(UInt64(frames), freeFrames)                 // drop on overflow (no consumer yet)
    var i: UInt64 = 0
    while i < give {
        let f = Int(i)
        let l  = src[f * chans + 0]
        let rr = chans > 1 ? src[f * chans + 1] : l            // mono source -> duplicate
        let pos = Int((w &+ i) & (cap - 1)) * kRingChannels
        ringData[pos + 0] = l
        ringData[pos + 1] = rr
        i &+= 1
    }
    ring_store_release(writeIdxPtr, w &+ give)
}

// ---- 3. Audio-process enumeration (object id + pid + bundle id). ----
struct ProcInfo { let obj: AudioObjectID; let pid: pid_t; let bundleID: String? }
let kSystemObj = AudioObjectID(kAudioObjectSystemObject)

func allAudioProcesses() -> [ProcInfo] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(kSystemObj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(kSystemObj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map { obj in
        var pa = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1; var ps = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(obj, &pa, 0, nil, &ps, &pid)
        var ba = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: CFString = "" as CFString; var bs = UInt32(MemoryLayout<CFString>.size)
        let ok = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(obj, &ba, 0, nil, &bs, $0) }
        let s = cf as String
        return ProcInfo(obj: obj, pid: pid, bundleID: (ok == noErr && !s.isEmpty) ? s : nil)
    }
}

// ---- 4. Rebuildable capture: tap + private aggregate + IOProc -> ring. ----
let kExcludeBundle = "com.apple.FaceTime"   // never tap the call itself (peer voice -> echo)
let selfPID = getpid()

final class Capture {
    let mode: String
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    init(mode: String) { self.mode = mode }

    func build() {
        let procs = allAudioProcesses()
        let tapDesc: CATapDescription
        if mode == "proc" {
            let included = procs.filter { $0.pid != selfPID && $0.bundleID != kExcludeBundle }
            print("tap_feed[proc]: mixdown of \(included.count) process(es): "
                + "\(included.compactMap { $0.bundleID ?? "pid \($0.pid)" })")
            if included.isEmpty { print("tap_feed[proc]: none yet — waiting for the process list to change."); return }
            tapDesc = CATapDescription(stereoMixdownOfProcesses: included.map { $0.obj })
        } else {
            let excluded = procs.filter { $0.bundleID == kExcludeBundle || $0.pid == selfPID }
            print("tap_feed[global]: global tap, excluding \(excluded.compactMap { $0.bundleID ?? "pid \($0.pid)" })")
            tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded.map { $0.obj })
        }
        tapDesc.name = "Soundboard Tap"; tapDesc.isPrivate = true; tapDesc.muteBehavior = .unmuted

        var st = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        if st != noErr || tapID == kAudioObjectUnknown { fail("CreateProcessTap failed: \(st)") }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Soundboard Tap Capture",
            kAudioAggregateDeviceUIDKey as String: "ca.borisvanin.soundboard.tapcapture",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [
                [ kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                  kAudioSubTapDriftCompensationKey as String: true ]
            ],
        ]
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        if st != noErr || aggID == kAudioObjectUnknown { fail("CreateAggregate failed: \(st)") }

        var fmt = AudioStreamBasicDescription(); var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                            mScope: kAudioObjectPropertyScopeInput, mElement: 0)
        _ = AudioObjectGetPropertyData(aggID, &fa, 0, nil, &fsz, &fmt)
        print("tap_feed: tap input = \(fmt.mSampleRate) Hz, \(fmt.mChannelsPerFrame) ch, flags=0x\(String(fmt.mFormatFlags, radix: 16))")

        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { (_, inInputData, _, _, _) in
            pushToRing(inInputData)
        }
        if st != noErr { fail("CreateIOProc failed: \(st)") }
        st = AudioDeviceStart(aggID, procID)
        if st != noErr { fail("AudioDeviceStart failed: \(st)") }
    }

    func teardown() {
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }
    func rebuild() { teardown(); build() }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "global"
guard mode == "global" || mode == "proc" else { fail("usage: tap_feed [global|proc]") }
let capture = Capture(mode: mode)
capture.build()

// In proc mode, rebuild the (static) mixdown tap whenever the process list
// changes, so newly launched apps get included automatically.
if mode == "proc" {
    var plAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(kSystemObj, &plAddr, DispatchQueue.main) { _, _ in
        print("tap_feed[proc]: process list changed → rebuilding tap")
        capture.rebuild()
    }
}

print("""
tap_feed: mode=\(mode). Capturing system audio into the mix ring.
          Play something, then start a FaceTime call with Soundboard as the mic.
          Ctrl-C to stop.
""")

// ---- 5. Run until Ctrl-C, then tear down. ----
signal(SIGINT, SIG_IGN)
let sigsrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigsrc.setEventHandler {
    print("\ntap_feed: stopping.")
    capture.teardown()
    munmap(base, ringTotalBytes); shm_unlink(kRingShmName)
    exit(0)
}
sigsrc.resume()

// ---- 1 Hz VU report: watch rms/peak when the call starts to see if the tap
//      sees the duck (level drops) or not (level holds). ----
func dbfs(_ v: Double) -> String { v <= 1e-9 ? " -inf" : String(format: "%6.1f", 20 * log10(v)) }
var lastSumSq = 0.0, lastCount: UInt64 = 0
let meterTimer = DispatchSource.makeTimerSource(queue: .main)
meterTimer.schedule(deadline: .now() + 1, repeating: 1)
meterTimer.setEventHandler {
    let ss = meterSumSq.pointee, c = meterCount.pointee
    let dss = ss - lastSumSq, dc = c - lastCount
    lastSumSq = ss; lastCount = c
    let rms = dc > 0 ? (dss / Double(dc)).squareRoot() : 0
    let pk = Double(meterPeak.pointee); meterPeak.pointee = 0
    print("tap_feed: VU  rms=\(dbfs(rms)) dBFS  peak=\(dbfs(pk)) dBFS  (\(dc) samples/s)")
}
meterTimer.resume()

dispatchMain()
