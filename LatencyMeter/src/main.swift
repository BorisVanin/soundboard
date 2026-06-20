// LatencyMeter — measure the audio delay the Soundboard pipeline adds.
//
// Method (self-referenced on a single channel, so no playback-clock guesswork):
//   1. Build a macOS Multi-Output Device  {<second output> (master) + Scarlett 2i2}.
//   2. Play a square test signal to that multi-output.
//        • the Scarlett leg drops the square onto the Scarlett's hardware LOOPBACK
//          (input ch4) almost immediately            -> REFERENCE onset
//        • the second-output leg (e.g. DELL) is what Soundboard taps; Soundboard
//          re-outputs the mix to the Scarlett, so the same square reappears on the
//          loopback later                              -> DELAYED onset
//   3. Record Scarlett input ch4 (single channel).
//   4. latency = (delayed onset) − (reference onset), both on the same channel /
//      same clock. A square is used because its edge is unambiguous.
//
// REQUIRES a Focusrite Scarlett 2i2 (its loopback is the measurement tap) and
// Microphone (TCC) permission — that is why this ships as a signed .app bundle
// with NSMicrophoneUsageDescription, not a bare CLI binary (an unbundled binary
// inherits the terminal's TCC identity and is silently fed zeros without it).
//
// usage: LatencyMeter <second-output-device-name> [--out <file.wav>] [--duration <sec>]
//   <second-output-device-name>  REQUIRED, no default (e.g. "DELL S2721QS")
//   --out        output WAV of the recorded ch4 (default: latency-capture.wav)
//   --duration   square test length in seconds       (default: 2)

import Foundation
import CoreAudio
import AudioToolbox

// ───────────────────────── config ─────────────────────────
let SCARLETT_MATCH = "Scarlett 2i2"
let LOOPBACK_CH    = 3            // 0-based: input ch4 = loopback L
let AGG_NAME = "Soundboard-LatencyMeter-MultiOut"
let AGG_UID  = "ca.borisvanin.soundboard.latencymeter.multiout"
let WARMUP   = 0.5               // s of silence before the square (let IO settle)
let TAIL     = 1.0               // s of recording after the square ends
let SQ_FREQ  = 0.5               // Hz square
let SQ_AMP: Float = 0.4          // headroom so reference+delayed don't clip when summed

// ───────────────────────── args ───────────────────────────
func die(_ m: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(code)
}
var positional: [String] = []
var outPath = "latency-capture.wav"
var duration = 2.0
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--out":
            guard let v = it.next() else { die("--out needs a path") }
            outPath = v
        case "--duration":
            guard let v = it.next(), let d = Double(v) else { die("--duration needs a number") }
            duration = d
        case "-h", "--help":
            die("usage: LatencyMeter <second-output-device-name> [--out <file.wav>] [--duration <sec>]", 0)
        default: positional.append(a)
        }
    }
}
guard let secondName = positional.first else {
    die("ERROR: the second output device is REQUIRED (no default).\n" +
        "usage: LatencyMeter <second-output-device-name> [--out <file.wav>] [--duration <sec>]\n" +
        "example: LatencyMeter \"DELL S2721QS\"")
}

// ───────────────────── CoreAudio helpers ──────────────────
var TB = mach_timebase_info_data_t(); mach_timebase_info(&TB)
@inline(__always) func hostToNs(_ h: UInt64) -> UInt64 { h &* UInt64(TB.numer) / UInt64(TB.denom) }

func allDevices() -> [AudioDeviceID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ids = [AudioDeviceID](repeating: 0, count: Int(sz)/MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
    return ids
}
func strProp(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: sel,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz = UInt32(MemoryLayout<CFString?>.size); var cf: CFString? = nil
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &cf) == noErr else { return nil }
    return cf as String?
}
func devName(_ id: AudioDeviceID) -> String { strProp(id, kAudioObjectPropertyName) ?? "?" }
func devUID(_ id: AudioDeviceID) -> String? { strProp(id, kAudioDevicePropertyDeviceUID) }
func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0; AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz)
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16); defer { raw.deallocate() }
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, raw)
    var ch = 0
    for b in UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)) { ch += Int(b.mNumberChannels) }
    return ch
}
func hasOutput(_ id: AudioDeviceID) -> Bool { channelCount(id, scope: kAudioDevicePropertyScopeOutput) > 0 }
func sampleRate(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Double {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
        mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var f = AudioStreamBasicDescription(); var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &f)
    return f.mSampleRate
}
func advertisedLatency(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> (UInt32, UInt32) {
    func u32(_ sel: AudioObjectPropertySelector) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v); return v
    }
    return (u32(kAudioDevicePropertyLatency), u32(kAudioDevicePropertySafetyOffset))
}

// ───────────────────── locate devices ─────────────────────
let devs = allDevices()
guard let scarlett = devs.first(where: { devName($0).contains(SCARLETT_MATCH) }),
      let scarUID = devUID(scarlett) else {
    die("""
    ERROR: no Scarlett 2i2 found.
    This tool REQUIRES a Focusrite Scarlett 2i2 (4th gen): its hardware loopback
    (input ch4) is the measurement tap. Connect the interface and retry.
    """, 10)
}
guard channelCount(scarlett, scope: kAudioDevicePropertyScopeInput) > LOOPBACK_CH else {
    die("ERROR: Scarlett exposes < \(LOOPBACK_CH+1) input channels — loopback (ch4) unavailable. " +
        "Enable Loopback in Focusrite Control.", 11)
}
guard let second = devs.first(where: { devName($0) == secondName && hasOutput($0) }),
      let secondUID = devUID(second) else {
    let outs = devs.filter { hasOutput($0) }.map { devName($0) }.joined(separator: ", ")
    die("ERROR: output device \"\(secondName)\" not found.\nAvailable outputs: \(outs)", 12)
}
let scarRate = sampleRate(scarlett, scope: kAudioDevicePropertyScopeInput)
let (oLat, oSafe) = advertisedLatency(second, scope: kAudioDevicePropertyScopeOutput)
FileHandle.standardError.write("""
LatencyMeter
  reference tap : \(devName(scarlett)) loopback ch\(LOOPBACK_CH+1) @ \(Int(scarRate)) Hz
  under test    : \(secondName)  (advertised output latency \(oLat) + safety \(oSafe) frames)
  multi-output  : {\(secondName) [master] + \(devName(scarlett))}
  square        : \(SQ_FREQ) Hz, \(duration)s, amp \(SQ_AMP)

""".data(using: .utf8)!)

// ───────────────── create multi-output device ─────────────
if let stale = devs.first(where: { devUID($0) == AGG_UID }) { AudioHardwareDestroyAggregateDevice(stale) }
let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: AGG_NAME,
    kAudioAggregateDeviceUIDKey  as String: AGG_UID,
    kAudioAggregateDeviceIsStackedKey as String: 1,            // Multi-Output Device
    kAudioAggregateDeviceIsPrivateKey as String: 0,
    kAudioAggregateDeviceMasterSubDeviceKey as String: secondUID,
    kAudioAggregateDeviceSubDeviceListKey as String: [
        [kAudioSubDeviceUIDKey as String: secondUID],          // master / primary first
        [kAudioSubDeviceUIDKey as String: scarUID],
    ],
]
var multiID = AudioDeviceID(0)
guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &multiID) == noErr, multiID != 0 else {
    die("ERROR: failed to create the multi-output device", 13)
}
func cleanup() { AudioHardwareDestroyAggregateDevice(multiID) }

// ───────────────── square test buffer ─────────────────────
// [WARMUP silence][square for `duration`][TAIL silence], at the Scarlett rate.
let sr = scarRate
let warmN = Int(WARMUP * sr), sqN = Int(duration * sr), tailN = Int(TAIL * sr)
let totalN = warmN + sqN + tailN
var square = [Float](repeating: 0, count: totalN)
for i in 0..<sqN {
    let t = Double(i) / sr
    square[warmN + i] = sin(2 * .pi * SQ_FREQ * t) >= 0 ? SQ_AMP : -SQ_AMP
}

// ───────────────── playback (output IOProc on the multi-output) ────────────
final class Player { var pos = 0; var done = false }
let player = Player()
let playRef = Unmanaged.passRetained(player).toOpaque()
let playProc: AudioDeviceIOProc = { _, _, _, _, outData, _, client in
    let p = Unmanaged<Player>.fromOpaque(client!).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(outData)        // outOutputData (non-optional)
    guard abl.count > 0 else { return noErr }
    // The multi-output presents one interleaved output buffer; fill all channels
    // with the mono square, advancing the play cursor once per frame.
    let b = abl[0]; let ch = max(1, Int(b.mNumberChannels))
    guard let base = b.mData else { return noErr }
    let fp = base.assumingMemoryBound(to: Float.self)
    let frames = Int(b.mDataByteSize) / (ch * MemoryLayout<Float>.size)
    for f in 0..<frames {
        let s: Float = p.pos < square.count ? square[p.pos] : 0
        for c in 0..<ch { fp[f*ch + c] = s }
        p.pos += 1
    }
    if p.pos >= square.count { p.done = true }
    return noErr
}

// ───────────────── capture (input IOProc on the Scarlett) ──────────────────
final class Cap { var s = [Float](); var firstNs: UInt64 = 0; var started = false; var peak: Float = 0 }
let cap = Cap(); cap.s.reserveCapacity(totalN + 8192)
let capRef = Unmanaged.passRetained(cap).toOpaque()
let capProc: AudioDeviceIOProc = { _, inNow, inData, inTime, _, _, client in
    let c = Unmanaged<Cap>.fromOpaque(client!).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    guard abl.count > 0 else { return noErr }
    if !c.started {
        let ts = inTime.pointee
        c.firstNs = hostToNs(ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : inNow.pointee.mHostTime)
        c.started = true
    }
    var base = 0
    for bi in 0..<abl.count {
        let b = abl[bi]; let bch = Int(b.mNumberChannels)
        if bch == 0 { continue }
        if LOOPBACK_CH < base + bch {
            let local = LOOPBACK_CH - base
            let frames = Int(b.mDataByteSize) / (bch * MemoryLayout<Float>.size)
            if let p = b.mData?.assumingMemoryBound(to: Float.self) {
                for f in 0..<frames { let v = p[f*bch + local]; c.s.append(v); if abs(v) > c.peak { c.peak = abs(v) } }
            }
            break
        }
        base += bch
    }
    return noErr
}

// ───────────────── run ─────────────────────────────────────
var playID: AudioDeviceIOProcID?, capID: AudioDeviceIOProcID?
guard AudioDeviceCreateIOProcID(multiID, playProc, playRef, &playID) == noErr, let playID,
      AudioDeviceCreateIOProcID(scarlett, capProc, capRef, &capID) == noErr, let capID else {
    cleanup(); die("ERROR: could not create IO procs", 14)
}
AudioDeviceStart(scarlett, capID)      // start capture first so the reference onset is caught
AudioDeviceStart(multiID, playID)
Thread.sleep(forTimeInterval: (WARMUP + duration + TAIL) + 0.3)
AudioDeviceStop(multiID, playID); AudioDeviceDestroyIOProcID(multiID, playID)
AudioDeviceStop(scarlett, capID);  AudioDeviceDestroyIOProcID(scarlett, capID)
cleanup()

// ───────────────── write WAV (mono int16) ─────────────────
func writeWav(_ path: String, _ s: [Float], _ rate: Double) {
    var pcm = [Int16](repeating: 0, count: s.count)
    for i in 0..<s.count { pcm[i] = Int16(max(-1, min(1, s[i])) * 32767) }
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let bytes = UInt32(pcm.count * 2)
    d.append("RIFF".data(using: .ascii)!); u32(36+bytes); d.append("WAVE".data(using: .ascii)!)
    d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate)*2); u16(2); u16(16)
    d.append("data".data(using: .ascii)!); u32(bytes)
    pcm.withUnsafeBytes { d.append(contentsOf: $0) }
    try? d.write(to: URL(fileURLWithPath: path))
}
writeWav(outPath, cap.s, sr)

// ───────────────── analyse: first two RISING edges on ch4 ──────────────────
// Reference onset = silence→square step. Delayed onset = the Soundboard copy
// stepping up on top. Detect rising steps via a positive first-difference that
// exceeds a robust threshold, then cluster hits within 15 ms.
let x = cap.s
func risingEdges(_ x: [Float], _ sr: Double) -> [Int] {
    guard x.count > 2 else { return [] }
    var diff = [Float](repeating: 0, count: x.count)
    for i in 1..<x.count { diff[i] = x[i] - x[i-1] }
    let mags = diff.map { abs($0) }.sorted()
    let med = mags[mags.count/2]
    let thr = max(med * 8, Float(SQ_AMP) * 0.25)      // rising step ~ a quarter of the amplitude
    var edges: [Int] = []; var last = -Int(sr)
    for i in 1..<diff.count where diff[i] > thr {
        if i - last > Int(0.015 * sr) { edges.append(i); last = i }
        else { last = i }
    }
    return edges
}
let edges = risingEdges(x, sr)

print(String(format: "captured %d frames, peak %.1f dBFS -> %@",
             x.count, x.isEmpty ? -240 : 20*log10(Double(cap.peak)+1e-12), outPath))
if cap.peak < 1e-4 {
    print("!! ch4 is silent. Check: Microphone permission for this app, Scarlett Loopback enabled,")
    print("   and that Soundboard is running and re-outputting the mix to the Scarlett.")
    exit(2)
}
if edges.count < 2 {
    print("!! found \(edges.count) rising edge(s); need 2 (reference + delayed).")
    print("   reference present but no delayed copy -> is Soundboard tapping \(secondName) and")
    print("   outputting back to the Scarlett? Inspect \(outPath).")
    exit(3)
}
let tRefMs = Double(edges[0]) / sr * 1000
let tDelMs = Double(edges[1]) / sr * 1000
let latency = tDelMs - tRefMs
print(String(format: "reference onset  %8.2f ms", tRefMs))
print(String(format: "delayed onset    %8.2f ms", tDelMs))
print(String(format: "──────────────────────────────"))
print(String(format: "APP LATENCY      %8.2f ms   (%@ → Soundboard → Scarlett)", latency, secondName))
